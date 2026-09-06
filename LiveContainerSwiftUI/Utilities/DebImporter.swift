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
    // Rootless tweaks put their dylib under this path (with or without a leading /var/jb
    // prefix, depending on how the .deb was built); we match on the trailing path components
    // only so both conventions resolve the same way. Resource bundles/frameworks aren't
    // pinned to one directory convention -- see installPayload below.
    private static let dynamicLibrariesSuffix = ["Library", "MobileSubstrate", "DynamicLibraries"]

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

        // Step 4: find the payload under the well-known rootless tweak dirs and
        // hand it to the same folder the manual dylib/framework importer uses.
        let installedNames = installPayload(from: dataDir, into: destinationFolder)

        return DebImportResult(installedNames: installedNames, unsupportedScriptLines: unsupportedLines)
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

    private static func pathEndsWith(_ url: URL, _ suffix: [String]) -> Bool {
        let comps = url.pathComponents
        guard comps.count >= suffix.count else { return false }
        return zip(comps.suffix(suffix.count), suffix).allSatisfy { $0.caseInsensitiveCompare($1) == .orderedSame }
    }

    private static func installPayload(from dataRoot: URL, into destination: URL) -> [String] {
        let fm = FileManager.default
        var installed: [String] = []
        // absolute path (as the tweak's own compiled-in strings would reference it) -> where
        // we actually put it, so the native path-redirect hook in TweakLoader can resolve it
        var redirects: [String: String] = [:]

        var dynamicLibDirs: [URL] = []
        var resourceDirs: [URL] = []

        if let enumerator = fm.enumerator(at: dataRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
                if pathEndsWith(url, dynamicLibrariesSuffix) {
                    dynamicLibDirs.append(url)
                    continue
                }
                // Tweaks stash their resource bundles/frameworks all over the place --
                // Library/PreferenceBundles, Library/Frameworks, Library/Application Support,
                // vendor-specific folders, etc. Rather than enumerate every convention, grab
                // any *.framework/*.bundle directory wherever it lives, and don't descend into
                // it any further (its contents are copied as one unit).
                let ext = url.pathExtension.lowercased()
                if ext == "framework" || ext == "bundle" {
                    resourceDirs.append(url)
                    enumerator.skipDescendants()
                }
            }
        }

        // maps the absolute path form the tweak's own binary might reference (with or without
        // the rootless /var/jb prefix) to where we're about to install this item.
        func recordRedirect(for itemUrl: URL, installedAt dest: URL) {
            var relativeComponents = Array(itemUrl.pathComponents.dropFirst(dataRoot.pathComponents.count))
            if relativeComponents.count >= 2, relativeComponents[0] == "var", relativeComponents[1] == "jb" {
                relativeComponents.removeFirst(2)
            }
            guard !relativeComponents.isEmpty else { return }
            let barePath = "/" + relativeComponents.joined(separator: "/")
            let rootlessPath = "/var/jb" + barePath
            redirects[barePath] = dest.path
            redirects[rootlessPath] = dest.path
        }

        func install(_ itemUrl: URL, patchMachO: Bool, recordAsRedirect: Bool) {
            let dest = destination.appendingPathComponent(itemUrl.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                try? fm.removeItem(at: dest)
            }
            do {
                try fm.copyItem(at: itemUrl, to: dest)
            } catch {
                NSLog("[LC] deb import: failed to install \(itemUrl.lastPathComponent): \(error)")
                return
            }
            if patchMachO {
                patchRPath(at: dest)
            }
            if recordAsRedirect {
                recordRedirect(for: itemUrl, installedAt: dest)
            }
            installed.append(itemUrl.lastPathComponent)
        }

        for dir in dynamicLibDirs {
            let children = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for child in children {
                let ext = child.pathExtension.lowercased()
                guard ext == "dylib" || ext == "plist" else { continue }
                install(child, patchMachO: ext == "dylib", recordAsRedirect: false)
            }
        }
        for resourceDir in resourceDirs {
            let ext = resourceDir.pathExtension.lowercased()
            install(resourceDir, patchMachO: ext == "framework", recordAsRedirect: true)
        }

        recordRedirects(redirects, in: destination)
        return installed
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
