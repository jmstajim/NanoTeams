import Foundation

/// No `emptyPath` case, on purpose (wave 32): an empty/whitespace path deliberately
/// RESOLVES to the work-folder root (`resolveFileURL`'s first line — pinned behavior,
/// see `BashHandlersTests.testWorkingDirectory_whitespaceOnly_runsInWorkFolderRoot`),
/// so a "path is empty" error route could never fire.
nonisolated enum SandboxPathError: LocalizedError {
    case absolutePathNotAllowed(String)
    case parentTraversalNotAllowed(String)
    case outsideSandbox(String)
    case restrictedPath

    var errorDescription: String? {
        switch self {
        case .absolutePathNotAllowed(let path):
            "Absolute paths are not allowed: \(path). Paths are relative to the work-folder root; use \".\" for the root."
        case .parentTraversalNotAllowed(let path):
            "Parent traversal (..) is not allowed: \(path)"
        case .outsideSandbox(let path):
            "Path resolves outside the selected work folder: \(path)"
        case .restrictedPath:
            "File not found."
        }
    }
}

nonisolated struct SandboxPathResolver {
    let workFolderRoot: URL
    let internalDir: URL?

    // No stored FileManager: this is a Sendable value type embedded in SearchExecutor.Input
    // and passed across concurrency domains. FileManager is non-Sendable, so the read-only
    // existence probe in `resolveFileURL` uses the thread-safe `FileManager.default` singleton.
    init(workFolderRoot: URL, internalDir: URL? = nil) {
        self.workFolderRoot = workFolderRoot.standardizedFileURL
        self.internalDir = internalDir?.standardizedFileURL
    }

    func resolveFileURL(relativePath: String?) throws -> URL {
        let raw = (relativePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return workFolderRoot }

        // Normalize into a component list. Two entry forms:
        //  - Absolute / tilde: accepted only if it standardizes to a location INSIDE the
        //    work folder, in which case it's relativized (LLMs often paste the full path).
        //    Anything outside the sandbox stays rejected — the security boundary is intact.
        //  - Relative: split, reject `..`, drop `.`/empty (as before).
        var components: [String]

        if raw.hasPrefix("/") || raw.hasPrefix("~") {
            let expanded = (raw as NSString).expandingTildeInPath
            // `expandingTildeInPath` returns the string UNCHANGED for an unknown user
            // (`~nosuchuser/x`), and `URL(fileURLWithPath:)` would then resolve it against the
            // PROCESS working directory — a global this resolver does not own, so the same input
            // would be accepted or rejected depending on where the process happens to be running
            // (and accepted outright if the CWD sat inside the work folder). Fail closed instead.
            guard expanded.hasPrefix("/") else {
                throw SandboxPathError.absolutePathNotAllowed(raw)
            }
            let absURL = URL(fileURLWithPath: expanded).standardizedFileURL
            // Chroot-style root: models often address the work folder as "/" (also
            // "//", "/.", "/.."). Anything addressing the filesystem root means
            // the work-folder root — the literal volume root is outside the sandbox
            // and useless to the model anyway. Mirrors the empty-path early return.
            if Self.addressesFilesystemRoot(absURL) { return workFolderRoot }
            guard Self.isWithin(candidate: absURL, container: workFolderRoot) else {
                // Preserve the ORIGINAL raw string in the error payload.
                throw SandboxPathError.absolutePathNotAllowed(raw)
            }
            components = Array(absURL.pathComponents.dropFirst(workFolderRoot.pathComponents.count))
        } else {
            let parts = raw.split(separator: "/").map(String.init)
            if parts.contains("..") {
                throw SandboxPathError.parentTraversalNotAllowed(raw)
            }
            components = parts.filter { !$0.isEmpty && $0 != "." }
        }

        // Strip leading redundant work-folder-name components, one at a time. Keep the path
        // when the first component is a genuine filesystem entity the model likely meant: an
        // existing same-named DIRECTORY, or ANY same-named SYMLINK (including a dangling one —
        // `fileExists` follows the link and reports false, so stripping there would silently
        // redirect to `<root>/<tail>`; keeping fails loudly as not-found instead, the safer
        // mode). Strip only when the component is truly absent or a same-named regular
        // (non-symlink) file. Keying on the first component — not the full file path — lets a
        // NEW-file write into a real same-named subdir survive (`root/app/new/x.tsx` doesn't
        // exist yet, but `root/app` does). Looping absorbs a doubled prefix (`Foo/Foo/src` ->
        // `<root>/src` when no `Foo` subdir exists). Fixes `Survivors/src/...` ->
        // `<root>/src/...`; replaces the old bare-name shortcut (now case-insensitive; a bare
        // name matching a real subdir resolves to that subdir, not root).
        while let first = components.first,
              first.caseInsensitiveCompare(workFolderRoot.lastPathComponent) == .orderedSame {
            let firstURL = workFolderRoot.appendingPathComponent(first)
            var isDir: ObjCBool = false
            let dirExists = FileManager.default.fileExists(atPath: firstURL.path, isDirectory: &isDir)
            let isSymlink = (try? firstURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
            if (dirExists && isDir.boolValue) || isSymlink { break }  // real dir or any same-named symlink → keep
            components.removeFirst()
        }

        var candidate = workFolderRoot
        for component in components {
            candidate.appendPathComponent(component, isDirectory: false)
        }

        let standardized = candidate.standardizedFileURL
        guard standardized == workFolderRoot || Self.isWithin(candidate: standardized, container: workFolderRoot) else {
            throw SandboxPathError.outsideSandbox(raw)
        }

        if let internalDir, Self.isWithin(candidate: standardized, container: internalDir) {
            throw SandboxPathError.restrictedPath
        }

        return standardized
    }

    /// Best-effort normalization of one git pathspec argument. Never throws: git pathspecs
    /// include globs and `:`-magic that aren't real filesystem paths, so anything that does
    /// not cleanly resolve to a sandbox path is returned unchanged for git to interpret.
    /// Reuses `resolveFileURL` so absolute + redundant-work-folder-name forms are handled
    /// identically to the file tools, then converts the result back to a repo-relative path.
    func relativizePathspec(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }
        if trimmed.hasPrefix(":") { return raw }                                          // pathspec magic
        if trimmed.contains(where: { $0 == "*" || $0 == "?" || $0 == "[" }) { return raw } // glob
        guard let resolved = try? resolveFileURL(relativePath: trimmed) else { return raw }
        let rootCount = workFolderRoot.pathComponents.count
        let comps = resolved.standardizedFileURL.pathComponents
        guard comps.count >= rootCount else { return raw }
        let rel = comps.dropFirst(rootCount).joined(separator: "/")
        return rel.isEmpty ? raw : rel   // bare-root pathspec: leave as-is, don't over-broaden
    }

    /// True when `url` addresses the filesystem root under EITHER Foundation implementation.
    ///
    /// macOS 26's swift-foundation standardizes via RFC-3986 `remove_dot_segments` and strips a
    /// terminal `.`; macOS 15's CFURL-backed `URL` does NOT (swift-corelibs-foundation #3725 /
    /// SR-7289), so `/.`, `/./`, `/./.`, `//.` and `/.//` arrive there as `["/", "."]`, while every
    /// other root-ish spelling (`/`, `//`, `/..`, `/a/..`) collapses to `["/"]` on both. The
    /// deployment target is macOS 15, so both must classify as root — a plain `path == "/"` test
    /// rejects the work-folder root for every user on the older OS (and broke CI, which runs
    /// `macos-15`). Pinned against BOTH standardizers by
    /// `SandboxPathResolverTests.testAddressesFilesystemRoot_*`.
    ///
    /// Exact `== "."` equality is deliberate: `/...` and `..foo` are ordinary components. `..` is
    /// deliberately NOT tolerated — both Foundations resolve it before we see it, and `/../x` must
    /// stay an escape rather than becoming the root.
    static func addressesFilesystemRoot(_ url: URL) -> Bool {
        let components = url.pathComponents
        return !components.isEmpty && components.allSatisfy { $0 == "/" || $0 == "." }
    }

    /// Checks whether `candidate` is equal to or contained within `container` using path components.
    /// Robust against partial directory name matches (e.g., `/foo/internal-backup` does NOT match `/foo/internal`).
    static func isWithin(candidate: URL, container: URL) -> Bool {
        let containerComponents = container.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        guard candidateComponents.count >= containerComponents.count else { return false }
        return Array(candidateComponents.prefix(containerComponents.count)) == containerComponents
    }
}
