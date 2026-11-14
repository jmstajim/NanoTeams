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
    /// The work folder IS a credential store — a coding agent's configuration folder, or a key
    /// store like `~/.ssh` — so nothing in it is the tools' to touch. Distinct from
    /// `restrictedPath` because "File not found." about the folder the role was told to work in
    /// teaches it nothing and it loops (#376).
    case protectedWorkFolder
    /// A file in the work folder that CONFIGURES a coding agent — the one write a role could
    /// use to make an unsandboxed client fetch the agent token and hand it back.
    case agentConfiguration(String)
    /// The repository's own control directory. `.git/config` configures a client that is worse
    /// than an external one: `core.fsmonitor` (and `core.sshCommand`, `diff.external`,
    /// `core.hooksPath`) is a shell command git runs on the very next `git status`, in this
    /// process, outside Seatbelt — measured 2026-11-08.
    case repositoryControlDirectory
    /// A git pathspec that is not a path the tools may judge: `:`-magic can address the
    /// repository top, which lies above the work folder whenever the repo encloses it.
    case pathspecMagicNotAllowed(String)
    /// A wildcard pathspec that names nothing on disk. A path that EXISTS is sent to git as
    /// `:(literal)`, so `app/[id]/page.tsx` works; a pattern cannot be served beside the
    /// `:(exclude)` list every git call carries (measured on git 2.54: a wildcard positive next
    /// to ANY exclude matches nothing, silently, under exit 0).
    case pathspecWildcardNotAllowed(String)
    /// An empty path. It used to reach git, which refused it by name; since the tools supply
    /// `.` when nothing is named, a blank entry would silently mean the whole work folder.
    case pathspecEmpty

    var errorDescription: String? { message }

    /// Every case answers — this is the `error` a tool result carries to the model, so it
    /// is never optional; `errorDescription` is the `LocalizedError` view of the same text.
    var message: String {
        switch self {
        case .absolutePathNotAllowed(let path):
            "Absolute paths are not allowed: \(path). Paths are relative to the work-folder root; use \".\" for the root."
        case .parentTraversalNotAllowed(let path):
            "Parent traversal (..) is not allowed: \(path). Paths are relative to the work-folder root; name the target from the root and use \".\" for the root itself."
        case .outsideSandbox(let path):
            "Path resolves outside the selected work folder: \(path). Paths are relative to the work-folder root; use \".\" for the root."
        case .restrictedPath:
            "File not found."
        case .protectedWorkFolder:
            "This work folder is a credential store — a coding agent's configuration folder, or a key store like ~/.ssh — so no role may read or write it. Ask the Supervisor to open a project folder instead."
        case .agentConfiguration(let name):
            "\(name) configures a coding agent that runs outside the sandbox, so no role may write it. Name the change you wanted in your notes for the Supervisor to make by hand, and continue."
        case .repositoryControlDirectory:
            "Nothing inside .git may be written directly — its settings and hooks are commands git runs outside the sandbox. Use the git_* tools to change the repository."
        case .pathspecMagicNotAllowed(let path):
            "Pathspec magic is not accepted: \(path). Name paths relative to the work-folder root, or omit them for the whole folder."
        case .pathspecWildcardNotAllowed(let path):
            "No file matches \(path), and patterns are not accepted here. Name each file as list_files or search reports it."
        case .pathspecEmpty:
            "An empty path is not a path. Name a file or a folder, or pass \".\" for the whole work folder."
        }
    }
}

nonisolated struct SandboxPathResolver {
    let workFolderRoot: URL
    let internalDir: URL?
    /// The work folder's real location: where a path must land once every symlink on the way is
    /// followed. A role's `bash` may write a link anywhere in the work folder, and the file tools
    /// run in the app's own process, outside Seatbelt — so containment is decided on REAL paths,
    /// or `ln -s ~/.ssh keys` followed by `read_file keys/id_ed25519` reads what the sandbox
    /// denies (#375).
    let canonicalRoot: String
    /// The internal directory's real location, when there is one.
    let canonicalInternalDir: String?
    /// Real locations no file tool reaches, whatever path names them (#375): the credential
    /// stores and agent-client folders that lie inside the work folder — the case of a person
    /// who opens `~` as a project — and the agent token locations wherever they are.
    let hiddenLocations: [String]
    /// Real locations of the work folder's own agent-configuration files — readable, never
    /// writable by a role. See `projectAgentConfigurationPaths`.
    let agentConfigurationLocations: [String]
    /// `hiddenLocations` / `agentConfigurationLocations` case-folded for lookup. Stored rather
    /// than folded per call because `hides` runs once per walked entry.
    private let foldedHiddenLocations: Set<String>
    private let foldedAgentConfigurations: Set<String>
    /// `<work>/.git`, both spellings — a submodule's or a worktree's `.git` is a FILE naming
    /// another directory, and writing THAT redirects the repository just as well.
    private let foldedRepositoryControl: Set<String>

    // No stored FileManager: this is a Sendable value type embedded in SearchExecutor.Input
    // and passed across concurrency domains. FileManager is non-Sendable, so the read-only
    // existence probe in `resolveFileURL` uses the thread-safe `FileManager.default` singleton.
    /// `home` is the user's home folder, whose stores and token locations are hidden; `nil`
    /// means this process's own, which is the only one the app ever passes.
    init(workFolderRoot: URL, internalDir: URL? = nil, home: URL? = nil) {
        self.workFolderRoot = workFolderRoot.standardizedFileURL
        self.internalDir = internalDir?.standardizedFileURL
        let canonicalRoot = Self.canonicalPath(self.workFolderRoot.path)
        self.canonicalRoot = canonicalRoot
        self.canonicalInternalDir = self.internalDir.map { Self.canonicalPath($0.path) }
        let hiddenLocations = Self.hiddenLocations(
            home: home.map { Self.canonicalPath($0.path) } ?? Self.canonicalHome,
            canonicalRoot: canonicalRoot)
        self.hiddenLocations = hiddenLocations
        self.foldedHiddenLocations = Set(hiddenLocations.map { $0.lowercased() })
        // Both spellings again, and for the same reason as a store: `.claude` may be a link.
        let agentConfigurations = Self.projectAgentConfigurationPaths.flatMap {
            relative -> [String] in
            let spelled = (canonicalRoot as NSString).appendingPathComponent(relative)
            let real = Self.canonicalPath(spelled)
            return real == spelled ? [spelled] : [spelled, real]
        }
        self.agentConfigurationLocations = agentConfigurations
        self.foldedAgentConfigurations = Set(agentConfigurations.map { $0.lowercased() })
        let controlDirectory = (canonicalRoot as NSString).appendingPathComponent(".git")
        self.foldedRepositoryControl = Set(
            [controlDirectory, Self.canonicalPath(controlDirectory)].map { $0.lowercased() })
        self.hidesRoot = Self.isWithinAny(
            foldedPath: canonicalRoot.lowercased(),
            foldedLocations: Set(hiddenLocations.map { $0.lowercased() }))
    }

    private static let canonicalHome = canonicalPath(NSHomeDirectory())

    /// See `hiddenLocations`. A store OUTSIDE the work folder needs no entry: containment
    /// already refuses it. A store that CONTAINS the work folder — a skill written at
    /// `~/.claude/skills/x` — is not hidden either, or the whole project would be.
    ///
    /// Every location is taken BOTH as written and as it really is, because either spelling
    /// may be the one inside the work folder: a dotfiles manager links `~/.ssh` to
    /// `~/dotfiles/ssh`, so with the work folder at `~` the real path is what a role reaches,
    /// and with the work folder at `~/dotfiles` the real path is the only one inside it at all
    /// (the written one is then outside and containment refuses it anyway). Keeping the
    /// written spelling as well is what lets the walks skip the LINK rather than following it.
    static func hiddenLocations(home: String, canonicalRoot: String) -> [String] {
        let stores = SeatbeltSandbox.credentialStoreSubpaths(home: home)
            + SeatbeltSandbox.credentialStoreLiterals(home: home)
        let tokens = SeatbeltSandbox.externalAgentTokenLocations(home: home)
        // Both lists already carry every location as written AND as it really is
        // (`SeatbeltSandbox.bothSpellings`), so only the containment filter is left here. A
        // token location is hidden wherever it is — nothing has any reason to read one through
        // a tool — so it has no filter at all.
        return stores.filter { isWithin(realPath: $0, realContainer: canonicalRoot) }
            + tokens.subpaths + tokens.literals
    }

    /// The work-folder-relative paths of the files that configure a coding agent for a
    /// PROJECT — the scope that outranks the user-level one the connection facts send a person to.
    ///
    /// Roles may not write them (`write_file`, `edit_file`, `bash`), because the client that
    /// reads them runs outside the sandbox with the person's own rights: a `headersHelper` of
    /// a role's choosing would fetch the agent token file and leave the bearer inside
    /// the work folder, and a rewritten `url` would send it to a port a role is listening on.
    /// Reading them is fine; it is the write that hands a role an unsandboxed proxy (#376).
    static let projectAgentConfigurationPaths: [String] = [
        ".mcp.json",
        ".claude/settings.json",
        ".claude/settings.local.json",
        ".vscode/mcp.json",
        ".cursor/mcp.json",
        ".gemini/settings.json",
        ".codex/config.toml",
    ]

    /// `true` when a REAL path is one a file tool may touch: inside the work folder, outside
    /// the internal directory and every hidden location.
    func permits(canonicalPath path: String) -> Bool {
        guard Self.isWithin(realPath: path, realContainer: canonicalRoot) else { return false }
        if let canonicalInternalDir, Self.isWithin(realPath: path, realContainer: canonicalInternalDir) {
            return false
        }
        return !hides(canonicalPath: path)
    }

    /// `true` when a REAL path lies in a hidden location — compared without regard to case, as
    /// APFS compares names by default: `realpath` returns an existing path in its on-disk case,
    /// but a tail not written yet keeps the case it was asked in, and `.CONFIG/NANOTEAMS/x` names
    /// the same folder as `.config/nanoteams/x`. Fail-closed: a case-sensitive volume merely hides
    /// a little more. (Seatbelt needs no such care: it matches the path the kernel resolved.)
    ///
    /// Asked of EVERY entry of every walk since #376, so it climbs the candidate's own ancestors
    /// against a set — bounded by the path's depth — rather than testing containment against each
    /// hidden location in turn.
    func hides(canonicalPath path: String) -> Bool {
        Self.isWithinAny(foldedPath: path.lowercased(), foldedLocations: foldedHiddenLocations)
    }

    /// `foldedPath` itself or one of its ancestors is in `foldedLocations` — containment by
    /// climbing the candidate rather than by testing every location, since the candidate's
    /// depth is bounded and the set lookup is not a scan. Both sides are already case-folded.
    private static func isWithinAny(foldedPath: String, foldedLocations: Set<String>) -> Bool {
        var folded = foldedPath
        // `utf8.count` is the stored byte length; `count` would walk the graphemes of every
        // ancestor of every walked entry.
        while folded.utf8.count > 1 {
            if foldedLocations.contains(folded) { return true }
            guard let slash = folded.lastIndex(of: "/") else { return false }
            folded = String(folded[folded.startIndex..<slash])
        }
        return false
    }

    /// `true` when a REAL path is one of the work folder's own agent-configuration files.
    /// Case-folded like `hides`, and for the same reason.
    func isAgentConfiguration(canonicalPath path: String) -> Bool {
        foldedAgentConfigurations.contains(path.lowercased())
    }

    /// `true` when a REAL path is the repository's control directory or anything inside it.
    /// Readable — `read_file .git/config` is a fair question — never writable by a tool: git's
    /// own settings are commands it runs, and the file tools have no business there when the
    /// `git_*` tools are the interface (#382).
    func isRepositoryControl(canonicalPath path: String) -> Bool {
        Self.isWithinAny(
            foldedPath: path.lowercased(), foldedLocations: foldedRepositoryControl)
    }

    /// The hidden locations inside the work folder, as work-folder-relative paths — the cheap
    /// pre-filter of the walks (which decide on real paths) and the `:(exclude)` list every
    /// git invocation carries.
    var hiddenRelativePaths: [String] {
        hiddenLocations.compactMap { Self.relativePath(of: $0, under: canonicalRoot) }
    }

    /// The `:(exclude)` pathspecs every git invocation that can print or stage file CONTENT
    /// carries: the places the file tools hide, plus the internal directory. Without them a
    /// broad-but-legal pathspec (`.`, `*`) stages a hidden file and `git_diff --cached` prints
    /// it — refusing the pathspec that NAMES one is only half the seam (#376).
    var gitExcludePathspecs: [String] {
        gitExcludedRelativePaths.map(Self.gitExcludePathspec)
    }

    /// What `gitExcludePathspecs` excludes, as work-folder-relative paths — for a caller that
    /// must judge each one before passing it (the snapshot's `add -A`, which git refuses when an
    /// exclude names a path its rules ignore).
    var gitExcludedRelativePaths: [String] {
        var relatives = hiddenRelativePaths
        // Only the canonical pair: `canonicalInternalDir` is nil exactly when `internalDir` is,
        // and an internal directory that is not inside the root has nothing to exclude.
        if let canonicalInternalDir,
           let relative = Self.relativePath(of: canonicalInternalDir, under: canonicalRoot) {
            relatives.append(relative)
        }
        return relatives
    }

    /// The `:(exclude)` pathspec of one work-folder-relative path, read literally.
    static func gitExcludePathspec(_ relative: String) -> String {
        ":(exclude,literal)\(relative)"
    }

    /// The pathspec list a git tool passes after `--`: what the caller named — each judged, not
    /// guessed — or the work folder itself when it named nothing. Scoping to `.` is what keeps a
    /// repository that ENCLOSES the work folder from reporting the rest of itself: `git diff`
    /// with no pathspec is repository-wide, work folder or not.
    ///
    /// The `:(exclude)` list rides only the calls whose positives can EXPAND past what the
    /// caller named — `.`, or a directory. A named FILE was judged one by one already, so an
    /// exclude beside it adds nothing to the guarantee and costs the call: measured on git 2.54,
    /// `git add -- <untracked file> ':(exclude)x'` stages NOTHING and exits 0, while the same
    /// call with a directory positive, or with no exclude, stages it. A silent no-op under
    /// `ok:true` is the one outcome worse than a refusal, so the rule follows the measurement.
    func gitPathspecs(forPaths paths: [String]?) throws -> [String] {
        let named = try gitPositives(forPaths: paths)
        let expands = named.contains { $0 == "." || isDirectory($0) }
        return named.map(gitLiteral) + (expands ? gitExcludePathspecs : [])
    }

    /// The caller's paths as work-folder-relative positives — each judged, with no magic and no
    /// excludes — or `["."]` when nothing was named. What `git_add` expands itself.
    func gitPositives(forPaths paths: [String]?) throws -> [String] {
        // A work folder that IS a credential store is no more git's to touch than the file
        // tools'. Checked here as well as per tool, because the dangerous call is the one with
        // NO paths: `git_diff` would print the content of every change in `~/.ssh`.
        if hidesRoot { throw SandboxPathError.protectedWorkFolder }
        let named = try (paths ?? []).map { try strictPathspec($0) }
        return named.isEmpty ? ["."] : named
    }

    /// `true` when this work-folder-relative path is a directory on disk — the positives that
    /// EXPAND past what the caller named, and so the ones that need the excludes beside them.
    func isDirectory(_ relative: String) -> Bool {
        var isDirectory: ObjCBool = false
        let path = (workFolderRoot.path as NSString).appendingPathComponent(relative)
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// One git pathspec, judged. `relativizePathspec`'s fail-CLOSED twin, for the tools that
    /// run git with the person's own rights: a pathspec naming a hidden location throws
    /// "File not found." instead of reaching git, where staging it and diffing the index
    /// printed the bytes the resolver had just refused (#376).
    ///
    /// Whether a PATTERN is served is decided on the filesystem, not on the characters: a path
    /// that exists is sent to git as `:(literal)` (so `app/[id]/page.tsx` stages, as it did
    /// before), and only a pattern matching nothing is refused. A real pattern cannot be served
    /// beside the `:(exclude)` list anyway — measured on git 2.54, `git add -- 'src/*.txt'
    /// ':(exclude).ssh'` stages NOTHING and exits 0, the silent no-op under `ok:true` this
    /// codebase treats as worse than any refusal.
    ///
    /// Returns the path RELATIVE to the work folder, with no magic: `gitLiteral` adds that.
    func strictPathspec(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SandboxPathError.pathspecEmpty }
        if trimmed.hasPrefix(":") { throw SandboxPathError.pathspecMagicNotAllowed(raw) }
        let looksLikeAPattern = trimmed.contains(where: { $0 == "*" || $0 == "?" || $0 == "[" })
        let resolved: URL
        do {
            resolved = try resolveFileURL(relativePath: trimmed)
        } catch {
            // A pattern that does not resolve is a pattern; anything else keeps the resolver's
            // own refusal, which says which rule it broke.
            if looksLikeAPattern { throw SandboxPathError.pathspecWildcardNotAllowed(raw) }
            throw error
        }
        if looksLikeAPattern, !FileManager.default.fileExists(atPath: resolved.path) {
            throw SandboxPathError.pathspecWildcardNotAllowed(raw)
        }
        return Self.relativePath(of: resolved.standardizedFileURL.path, under: workFolderRoot.path)
            ?? "."
    }

    /// One work-folder-relative path as a pathspec git reads LITERALLY — no glob, no magic — so
    /// a file whose name holds `[` or `*` is the file and not a pattern. `.` is passed bare: it
    /// is git's own word for the current directory, and `:(literal).` is not.
    func gitLiteral(_ relative: String) -> String {
        relative == "." ? "." : ":(literal)\(relative)"
    }

    /// `path`'s spelling relative to `container`, or `nil` when it is not inside it. Both are
    /// taken as text — they are either both real paths or both logical ones.
    private static func relativePath(of path: String, under container: String) -> String? {
        guard isWithin(realPath: path, realContainer: container) else { return nil }
        guard path != container else { return nil }
        let prefixLength = container == "/" ? 1 : container.utf8.count + 1
        return String(decoding: path.utf8.dropFirst(prefixLength), as: UTF8.self)
    }

    /// The work folder itself is a hidden location — a person who opens `~/.codex` as a project.
    /// Then no file is the tools' to touch, and the walks start nowhere.
    let hidesRoot: Bool

    /// Containment between two REAL paths, by their text. Not `isWithin(candidate:container:)`:
    /// `standardizedFileURL` drops a leading `/private` only from a path that EXISTS, so the
    /// real path of a file not yet written (`/private/var/…/new.txt`) and of its existing folder
    /// (read back as `/var/…`) stopped matching — every new file in a temporary work folder was
    /// "outside" it.
    static func isWithin(realPath: String, realContainer: String) -> Bool {
        realPath == realContainer
            || realPath.hasPrefix(realContainer.hasSuffix("/") ? realContainer : realContainer + "/")
    }

    /// `path`'s real location: every symlink followed — one that dangles too, its target taken
    /// as written — and a tail that does not exist yet (a file about to be written) kept as is
    /// under its real parent. Bounded, so a link cycle ends.
    static func canonicalPath(_ path: String) -> String {
        canonicalPath(path, depth: 0)
    }

    private static func canonicalPath(_ path: String, depth: Int) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let parent = url.deletingLastPathComponent().path
        guard depth < 32, parent != url.path else { return url.path }
        let realParent = canonicalPath(parent, depth: depth + 1)
        let candidate = (realParent as NSString).appendingPathComponent(url.lastPathComponent)
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate) {
            let absolute = target.hasPrefix("/") ? target : (realParent as NSString).appendingPathComponent(target)
            return canonicalPath(URL(fileURLWithPath: absolute).standardizedFileURL.path, depth: depth + 1)
        }
        return candidate
    }

    func resolveFileURL(relativePath: String?) throws -> URL {
        try resolve(relativePath: relativePath, enforcingRealContainment: true)
    }

    /// Where a `bash` command's `working_directory` lands — resolved as the path is WRITTEN.
    ///
    /// Real-path containment is the file tools' rule because they run in the app's process,
    /// outside Seatbelt. `bash` is inside it, and Seatbelt matches the path the kernel resolved,
    /// so a link out of the work folder is already governed there — while a `cd` to the same
    /// place inside the command would succeed regardless. Enforcing it here only broke the
    /// monorepo and `npm link` layouts that address a sibling checkout through a link (#376).
    /// The hidden locations still apply: a cwd whose real location is a credential store or a
    /// token folder is refused here as well as by the profile.
    func resolveWorkingDirectoryURL(relativePath: String?) throws -> URL {
        try resolve(relativePath: relativePath, enforcingRealContainment: false)
    }

    private func resolve(relativePath: String?, enforcingRealContainment: Bool) throws -> URL {
        let raw = (relativePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if hidesRoot { throw SandboxPathError.protectedWorkFolder }
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

        // Where the path really lands. Outside the work folder through a link is the same escape
        // as `..`; the internal directory and the hidden locations answer "File not found", as
        // the internal directory always has, so a probe learns nothing about what is there.
        let real = Self.canonicalPath(standardized.path)
        if enforcingRealContainment {
            guard Self.isWithin(realPath: real, realContainer: canonicalRoot) else {
                throw SandboxPathError.outsideSandbox(raw)
            }
            guard permits(canonicalPath: real) else {
                throw SandboxPathError.restrictedPath
            }
        } else if hides(canonicalPath: real) {
            throw SandboxPathError.restrictedPath
        }

        return standardized
    }

    /// Best-effort normalization of one path for DISPLAY. Never throws: anything that does not
    /// cleanly resolve to a sandbox path is returned unchanged.
    ///
    /// The git tools took this and handed the result to `git`, which is what made the
    /// never-throws part a hole — a refused path reached git unchanged (#378). They now use
    /// `strictPathspec` / `gitPathspecs(forPaths:)`, and the one caller left is
    /// `MemoryTagStore+JSONHelpers`, which shortens a path for a human to read.
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
