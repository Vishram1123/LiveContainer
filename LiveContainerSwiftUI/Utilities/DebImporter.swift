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
    // Marks a deb-imported tweak's own folder so it can be told apart from a folder the
    // user created themselves to group/select tweaks per-app: LCTweaksView.swift shows a
    // different icon for it, and TweakLoader.m's global-tweaks loop uses its presence to
    // decide a top-level folder should load for every app (like a loose .dylib does)
    // rather than only for an app that has explicitly selected it. TweakLoader.m can't
    // reference this constant directly (it's a separate dylib target), so its copy of the
    // literal name must be kept in sync with this one.
    static let debTweakMarkerName = ".lc_deb_tweak"

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
        fm.createFile(atPath: tweakDir.appendingPathComponent(debTweakMarkerName).path, contents: nil)

        // absolute path (as the tweak's own compiled-in strings would reference it) -> where
        // we actually put it, so the native path-redirect hook in TweakLoader can resolve it.
        //
        // The "where we put it" side is stored *relative to destination* (the tweak-folder
        // root), not as an absolute path: destination lives inside LiveContainer's own app
        // container (LCPath.tweakPath) or the shared app-group container
        // (LCPath.lcGroupTweakPath), and both of those roots can change out from under an
        // already-imported tweak -- LiveContainer being reinstalled/updated gets a brand new
        // sandbox container UUID, and "convert app to shared" physically moves the whole
        // tweak folder from one root to the other. An absolute path baked in at import time
        // goes stale the moment either happens, silently breaking every redirect until the
        // tweak is re-imported. Storing a root-relative path and letting DebPathRedirect.m
        // re-resolve it against whichever root is actually current at each launch keeps the
        // mapping valid across both.
        // Some tweaks reference dependencies -- their own co-bundled ones (e.g. a Swift
        // runtime framework shipped in the same .deb) as well as ones from a *different*
        // tweak entirely (e.g. one package's dylib linking a shared framework a separate
        // "support library" package installs) -- via "@loader_path/.jbroot/..." instead of
        // @rpath. ".jbroot" is a convention from real rootless jailbreaks: a symlink next to
        // every installed dylib pointing back at the (possibly randomized) real jailbreak
        // root, so tweaks find absolute-looking paths without hardcoding where the root
        // actually is. dyld resolves that symlink itself at dlopen time.
        //
        // Every deb-imported tweak's own payload lives nested under its own subfolder
        // (Tweaks/<tweakName>/...), so a ".jbroot" pointing at just *that* tweak's own
        // subfolder would resolve same-package dependencies but never find another
        // package's files. Instead, every tweak's ".jbroot" points at one shared location,
        // Tweaks/.lc_shared_jbroot -- a flat mirror (see rebuildSharedJbroot) of every
        // framework/bundle across *every* currently-imported tweak, keyed by original
        // absolute path -- so cross-package and same-package dependencies resolve the same
        // way. It's rebuilt on every import, so import order doesn't matter: a tweak
        // imported before its dependency still finds it once the dependency is imported,
        // without needing to be re-patched itself. This does NOT help a dependency on a
        // real system library that was never shipped in any .deb (e.g. libroothide.dylib
        // itself) -- there's nothing on disk for the mirror to point at.
        func createJbrootSymlink(in directory: URL) {
            let components = directory.pathComponents
            guard let tweakNameIndex = components.lastIndex(of: tweakName) else { return }
            // +1: one more hop than reaching tweakDir, to reach destination (where
            // .lc_shared_jbroot lives, alongside every tweak's own subfolder).
            let upsToDestination = (components.count - (tweakNameIndex + 1)) + 1
            let upPath = Array(repeating: "..", count: upsToDestination).joined(separator: "/")
            let jbrootUrl = directory.appendingPathComponent(".jbroot")
            try? fm.removeItem(at: jbrootUrl)
            try? fm.createSymbolicLink(atPath: jbrootUrl.path, withDestinationPath: upPath + "/.lc_shared_jbroot")
        }

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
            let relativeToDestination = tweakName + "/" + relativeComponents.joined(separator: "/")
            redirects[barePath] = relativeToDestination
            redirects["/var/jb" + barePath] = relativeToDestination
            // also index by the bundle/framework's own CFBundleIdentifier, for tweaks that
            // look their bundle up that way instead of by a hardcoded path
            if let info = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist")),
               let identifier = info["CFBundleIdentifier"] as? String {
                redirects["id:" + identifier] = relativeToDestination
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
                    createJbrootSymlink(in: url)
                    enumerator.skipDescendants()
                } else if isDir.boolValue, ext == "bundle" {
                    // resource bundles aren't Mach-O, but they're still referenced by
                    // absolute path just like frameworks are
                    recordRedirect(for: url)
                    enumerator.skipDescendants()
                } else if !isDir.boolValue, ext == "dylib" {
                    patchRPath(at: url)
                    createJbrootSymlink(in: url.deletingLastPathComponent())
                }
            }
        }

        recordRedirects(redirects, in: destination)
        rebuildSharedJbroot(in: destination)
        return [tweakName]
    }

    // Rebuilds Tweaks/.lc_shared_jbroot (or the app-group equivalent) from scratch as a flat
    // mirror of every framework/bundle any deb-imported tweak under `destination` has ever
    // registered a redirect for -- the merged .lc_deb_redirects.plist is already exactly
    // that data, keyed by the resource's original absolute path, so this just re-expresses
    // each bare-path entry (skipping the "/var/jb"-prefixed duplicate of the same entry, and
    // the "id:"-prefixed identifier entries, which aren't filesystem paths) as a symlink at
    // the matching location under .lc_shared_jbroot. Every tweak's own ".jbroot" symlink
    // (see createJbrootSymlink) and the extra rpath LCPatchAddRPath adds both point at this
    // fixed location, so refreshing its contents here is all that's needed to pick up a
    // newly-imported tweak's resources -- no other tweak needs to be re-patched.
    private static func rebuildSharedJbroot(in destination: URL) {
        let fm = FileManager.default
        let plistUrl = destination.appendingPathComponent(".lc_deb_redirects.plist")
        guard let merged = NSDictionary(contentsOf: plistUrl) as? [String: String] else { return }

        let sharedRoot = destination.appendingPathComponent(".lc_shared_jbroot")
        try? fm.removeItem(at: sharedRoot)
        try? fm.createDirectory(at: sharedRoot, withIntermediateDirectories: true)

        for (from, to) in merged {
            guard from.hasPrefix("/"), !from.hasPrefix("/var/jb/") else { continue }
            let relativeComponents = from.split(separator: "/").map(String.init)
            guard !relativeComponents.isEmpty else { continue }
            let symlinkUrl = sharedRoot.appendingPathComponent(relativeComponents.joined(separator: "/"))
            try? fm.createDirectory(at: symlinkUrl.deletingLastPathComponent(), withIntermediateDirectories: true)
            let upPath = Array(repeating: "..", count: relativeComponents.count).joined(separator: "/")
            try? fm.createSymbolicLink(atPath: symlinkUrl.path, withDestinationPath: upPath + "/" + to)
        }
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
