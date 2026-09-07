//
//  DebImporter.swift
//  LiveContainerSwiftUI
//
//  Imports rootless-jailbreak .deb tweak packages into a LiveContainer tweak folder,
//  reusing the existing ar/tar extraction (unarchive.m -> libarchive) and MachO
//  rpath-patching code already used for manually-imported dylib/framework tweaks.
//

import Foundation

enum DebImportError: LocalizedError {
    case notAnArchive
    case missingDataArchive

    var errorDescription: String? {
        switch self {
        case .notAnArchive:
            return "Not a valid .deb (ar) archive"
        case .missingDataArchive:
            return "The .deb package has no data.tar payload"
        }
    }
}

struct DebImportResult {
    let installedNames: [String]
    // raw postinst/preinst lines outside the mv/cp/mkdir/ln-s subset that were skipped
    let unsupportedScriptLines: [String]
}

enum DebImporter {
    private static let supportedScriptCommands: Set<String> = ["mv", "cp", "mkdir", "ln"]

    static func importDeb(at debUrl: URL, into destinationFolder: URL) throws -> DebImportResult {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("deb-\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        // Step 1: extract the outer `ar` container. This yields flat files:
        // debian-binary, control.tar.*, data.tar.* -- reusing the same extract()
        // used for IPA unzipping, since libarchive's "all formats" reader already
        // understands `ar`.
        let outerDir = workDir.appendingPathComponent("outer")
        try fm.createDirectory(at: outerDir, withIntermediateDirectories: true)
        guard extract(debUrl.path, outerDir.path, Progress()) == 0 else {
            throw DebImportError.notAnArchive
        }

        let outerEntries = (try? fm.contentsOfDirectory(atPath: outerDir.path)) ?? []
        guard let dataMember = outerEntries.first(where: { $0.hasPrefix("data.tar") }) else {
            throw DebImportError.missingDataArchive
        }
        let controlMember = outerEntries.first(where: { $0.hasPrefix("control.tar") })

        // Step 2: extract data.tar(.gz/.xz/.zst) -- again the same extract(), since
        // libarchive transparently picks the right decompression filter.
        let dataDir = workDir.appendingPathComponent("data")
        try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
        _ = extract(outerDir.appendingPathComponent(dataMember).path, dataDir.path, Progress())

        // Step 3: best-effort control.tar for pre/postinst. Missing or malformed
        // control metadata must not fail the import (required behavior #5).
        var unsupportedLines: [String] = []
        if let controlMember {
            let controlDir = workDir.appendingPathComponent("control")
            try? fm.createDirectory(at: controlDir, withIntermediateDirectories: true)
            if extract(outerDir.appendingPathComponent(controlMember).path, controlDir.path, Progress()) == 0 {
                for scriptName in ["preinst", "postinst"] {
                    let scriptUrl = controlDir.appendingPathComponent(scriptName)
                    if let contents = try? String(contentsOf: scriptUrl, encoding: .utf8) {
                        unsupportedLines.append(contentsOf: applyControlScript(contents, dataRoot: dataDir))
                    }
                }
            }
        }

        // Step 4: name the tweak (control's Name/Package field, else the .deb's own
        // filename) and mirror its whole payload tree into a subfolder of that name so
        // the original layout -- and thus every resource path inside it -- is preserved.
        let controlFileUrl = workDir.appendingPathComponent("control").appendingPathComponent("control")
        var tweakName: String?
        if let controlText = try? String(contentsOf: controlFileUrl, encoding: .utf8) {
            tweakName = parseControlField("Name", from: controlText) ?? parseControlField("Package", from: controlText)
        }
        let resolvedTweakName = sanitizeFolderName(tweakName ?? debUrl.deletingPathExtension().lastPathComponent)

        let installedNames = installPayload(from: dataDir, into: destinationFolder, tweakName: resolvedTweakName)

        return DebImportResult(installedNames: installedNames, unsupportedScriptLines: unsupportedLines)
    }

    private static func parseControlField(_ key: String, from control: String) -> String? {
        for line in control.split(separator: "\n") {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let fieldName = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces)
            guard fieldName == key else { continue }
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func sanitizeFolderName(_ raw: String) -> String {
        let cleaned = raw.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Tweak" : cleaned
    }

    // MARK: - Safe control-script subset
    //
    // We never execute postinst/preinst as shell scripts. We only recognize a
    // small set of file operations (mv, cp, mkdir, ln -s) and apply just their
    // effect against the extracted data.tar tree. Anything else is left
    // un-run and reported back so the caller can warn the user.

    private static func applyControlScript(_ script: String, dataRoot: URL) -> [String] {
        var warnings: [String] = []
        let fm = FileManager.default

        for rawLine in script.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let tokens = shellSplit(line)
            guard let cmdToken = tokens.first else { continue }
            let cmd = (cmdToken as NSString).lastPathComponent

            guard supportedScriptCommands.contains(cmd) else {
                warnings.append(line)
                continue
            }

            let flags = tokens.dropFirst().filter { $0.hasPrefix("-") }
            let pathArgs = tokens.dropFirst().filter { !$0.hasPrefix("-") }.map { resolvePath($0, dataRoot: dataRoot) }

            switch cmd {
            case "mkdir":
                guard !pathArgs.isEmpty else { warnings.append(line); continue }
                for path in pathArgs {
                    try? fm.createDirectory(at: path, withIntermediateDirectories: true)
                }
            case "mv":
                guard pathArgs.count == 2 else { warnings.append(line); continue }
                try? fm.removeItem(at: pathArgs[1])
                try? fm.moveItem(at: pathArgs[0], to: pathArgs[1])
            case "cp":
                guard pathArgs.count == 2 else { warnings.append(line); continue }
                try? fm.removeItem(at: pathArgs[1])
                try? fm.copyItem(at: pathArgs[0], to: pathArgs[1])
            case "ln":
                guard flags.contains(where: { $0.contains("s") }), pathArgs.count == 2 else {
                    warnings.append(line)
                    continue
                }
                try? fm.removeItem(at: pathArgs[1])
                try? fm.createSymbolicLink(at: pathArgs[1], withDestinationURL: pathArgs[0])
            default:
                break
            }
        }
        return warnings
    }

    private static func resolvePath(_ raw: String, dataRoot: URL) -> URL {
        var path = raw
        if path.hasPrefix("\"") && path.hasSuffix("\"") && path.count >= 2 {
            path = String(path.dropFirst().dropLast())
        }
        while path.hasPrefix("/") { path.removeFirst() }
        return dataRoot.appendingPathComponent(path)
    }

    /// A deliberately crude tokenizer: it only understands plain words and
    /// simple double-quoted arguments. Any line using shell features it
    /// doesn't understand (pipes, substitution, conditionals, variables) is
    /// turned into a single unrecognized token so the caller reports and
    /// skips it instead of misinterpreting it.
    private static func shellSplit(_ line: String) -> [String] {
        if line.contains("|") || line.contains(";") || line.contains("&&") || line.contains("$") || line.contains("`") || line.contains("(") {
            return ["__unsupported__"]
        }
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for ch in line {
            if ch == "\"" {
                inQuotes.toggle()
                continue
            }
            if ch == " " && !inQuotes {
                if !current.isEmpty { tokens.append(current); current = "" }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    // MARK: - Payload layout remap
    //
    // The whole data.tar payload is mirrored as-is under <destination>/<tweakName>/, so
    // the tweak's own directory structure (and thus every relative reference inside it)
    // stays intact -- TweakLoader.m already recurses arbitrarily deep looking for
    // .dylib/.framework, so nesting doesn't stop it from finding them. Anything the
    // tweak's binary references by *absolute* path (its own bundle, typically) needs a
    // redirect entry since that path no longer exists on disk -- see recordRedirects.

    private static func installPayload(from dataRoot: URL, into destination: URL, tweakName: String) -> [String] {
        let fm = FileManager.default

        // rootless packages nest everything under var/jb; unwrap that so the mirrored
        // tree starts at Library/... regardless of which convention the .deb used
        var effectiveRoot = dataRoot
        let varJbRoot = dataRoot.appendingPathComponent("var/jb")
        var isVarJbDir: ObjCBool = false
        if fm.fileExists(atPath: varJbRoot.path, isDirectory: &isVarJbDir), isVarJbDir.boolValue {
            effectiveRoot = varJbRoot
        }

        let tweakDir = destination.appendingPathComponent(tweakName)
        try? fm.removeItem(at: tweakDir)
        do {
            try fm.copyItem(at: effectiveRoot, to: tweakDir)
        } catch {
            NSLog("[LC] deb import: failed to install payload for \(tweakName): \(error)")
            return []
        }

        // absolute path (as the tweak's own compiled-in strings would reference it) -> where
        // we actually put it, so the native path-redirect hook in TweakLoader can resolve it
        var redirects: [String: String] = [:]
        func recordRedirect(for url: URL) {
            // Locate our own tweakDir folder name in the path and take everything after it,
            // rather than dropping tweakDir.pathComponents.count -- FileManager's enumerator
            // resolves URLs to their canonical form (e.g. adding a /private prefix), which
            // wouldn't match tweakDir's own component count if tweakDir was built from a
            // non-canonical URL (this bit us: it silently left a stray "/tweakName" prefix
            // baked into every redirect key, so nothing ever matched).
            let components = url.pathComponents
            guard let tweakNameIndex = components.lastIndex(of: tweakName) else { return }
            let relativeComponents = Array(components.dropFirst(tweakNameIndex + 1))
            guard !relativeComponents.isEmpty else { return }
            let barePath = "/" + relativeComponents.joined(separator: "/")
            redirects[barePath] = url.path
            redirects["/var/jb" + barePath] = url.path
            // also index by the bundle/framework's own CFBundleIdentifier, for tweaks that
            // look their bundle up that way instead of by a hardcoded path
            if let info = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist")),
               let identifier = info["CFBundleIdentifier"] as? String {
                redirects["id:" + identifier] = url.path
            }
        }

        if let enumerator = fm.enumerator(at: tweakDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                let ext = url.pathExtension.lowercased()
                if isDir.boolValue, ext == "framework" {
                    patchRPath(at: url)
                    recordRedirect(for: url)
                    enumerator.skipDescendants()
                } else if isDir.boolValue, ext == "bundle" {
                    // resource bundles aren't Mach-O, but they're still referenced by
                    // absolute path just like frameworks are
                    recordRedirect(for: url)
                    enumerator.skipDescendants()
                } else if !isDir.boolValue, ext == "dylib" {
                    patchRPath(at: url)
                }
            }
        }

        recordRedirects(redirects, in: destination)
        return [tweakName]
    }

    private static func recordRedirects(_ redirects: [String: String], in destination: URL) {
        guard !redirects.isEmpty else { return }
        let plistUrl = destination.appendingPathComponent(".lc_deb_redirects.plist")
        var merged = (NSDictionary(contentsOf: plistUrl) as? [String: String]) ?? [:]
        for (from, to) in redirects {
            merged[from] = to
        }
        (merged as NSDictionary).write(to: plistUrl, atomically: true)
    }

    // Same rpath fixup manual dylib/framework import already applies before signing.
    private static func patchRPath(at url: URL) {
        var machOUrl = url
        if url.pathExtension.lowercased() == "framework" {
            let info = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist"))
            let execName = (info?["CFBundleExecutable"] as? String) ?? url.deletingPathExtension().lastPathComponent
            machOUrl = url.appendingPathComponent(execName)
        }
        guard FileManager.default.fileExists(atPath: machOUrl.path) else { return }
        LCParseMachO((machOUrl.path as NSString).utf8String, false) { path, header, _, _ in
            LCPatchAddRPath(path, header)
        }
    }
}
