import Foundation

/// The directory walk, separated from the scan it used to interleave with.
///
/// `SearchExecutor.run` used to walk and grep in ONE recursive function: `searchDirectory`
/// called `searchFile` inline, so the order of everything the run accumulates — matches,
/// `skipped`, the `visitedPaths` roster, `dirsEnumerated` — was the DFS order and nothing had
/// to say so. Scanning several files at once breaks that: the walk now runs AHEAD of the scan,
/// and something has to remember where each side effect belonged.
///
/// That something is this type. It emits an ordered stream of `Step`s and performs only the
/// walk's own side effects (roster admission, directory counting); the driver replays the
/// stream in emission order and merges each candidate's scan result at its own position. Two
/// consequences the design exists for:
///
/// - **`skipped` keeps its exact interleaving.** A walk-side skip ("symlink points outside the
///   work folder") lands BETWEEN the scan-side skips of its neighbouring files, because its
///   position is a `Step` index rather than an append to a shared array. Collecting walk skips
///   and scan skips into two lists and concatenating would move every walk skip to one end —
///   observable, and pinned by three existing characterization tests.
/// - **A speculative tail can be rolled back exactly.** Each `Step` carries the walk counters
///   as of just after it, so when the merge stops at the candidate that fills the page budget,
///   `dirsEnumerated` and the roster revert to what the sequential walk would have had at that
///   moment — not to what the walk actually raced ahead to.
///
/// Cancellation is inherited, not flagged: the driver's task group makes the scans children of
/// the search task, and `next()` checks `Task.isCancelled` where the recursive walk did.
nonisolated struct SearchDirectoryWalker {

    // MARK: - Emission

    /// One thing the walk did, in the order it did it.
    enum WalkEvent {
        /// A file the walk would have grepped. The driver owns the scan.
        case candidate(url: URL, relativePath: String)
        /// A walk-side omission — an alias/cycle, or a symlink leaving the work folder.
        /// Scan-side omissions (unreadable, oversize, binary) ride the candidate's own result.
        case skip(SkippedFile)
    }

    /// An event plus the walk counters as of just after it — the rollback anchor.
    struct Step {
        let event: WalkEvent
        /// `stats.dirsEnumerated` after this event. NOT the walker's final value: on an early
        /// exit the sequential walk would never have enumerated the directories the speculative
        /// read-ahead already opened.
        let dirsEnumerated: Int
        /// `visitedPaths.count` after this event, so the roster can be truncated to the same
        /// point. The roster feeds `filename_matches`, so an over-long one is user-visible.
        let rosterCount: Int
    }

    /// Where the walk starts. Mirrors the three drive modes `SearchExecutor.run` supports.
    enum Root {
        /// `constrainToFiles` — an explicit relative-path list, no recursion.
        case constrainedFile(relativePath: String)
        /// A `paths` entry or the work-folder root: a directory to descend, or a named file.
        case entry(url: URL)
    }

    // MARK: - Walk scope

    private let fileManager: FileManager
    private let workFolderRoot: URL
    /// Canonical root for the symlink-containment check. Resolved on BOTH sides of the
    /// comparison because `resolvingSymlinksInPath()` normalises `/private/var` back to `/var`.
    private let canonicalRoot: URL
    private let internalCanonical: URL?
    private let internalRelPrefix: String?
    private let compiledGlob: CompiledGlob?
    /// List mode enumerates instead of grepping, so the walker owns its own stop condition
    /// (`rosterTruncated`) rather than waiting on a budget the driver computes from matches.
    private let listMode: Bool
    /// In list mode the roster IS the result, so the walk halts one candidate past the cap.
    private let collectTarget: Int

    // MARK: - Walk state

    private var roots: [Root]
    private var rootCursor = 0
    private var stack: [Frame] = []
    private var pending: [Step] = []
    private var pendingCursor = 0
    private var finished = false

    /// Canonical paths of directories already entered — the cycle guard.
    private var visitedDirs: Set<String> = []
    private var visitedSet: Set<String> = []

    /// Files the walk enumerated and would have grepped, in walk order.
    private(set) var visitedPaths: [String] = []
    /// Set once list mode discovers a distinct candidate BEYOND the cap.
    private(set) var rosterTruncated = false
    private(set) var dirsEnumerated = 0
    /// The walk stopped because the enclosing task was cancelled, not because it ran out.
    private(set) var wasCancelled = false

    private struct Frame {
        let relativePath: String
        let entries: [(name: String, url: URL, isDir: Bool)]
        var index = 0
    }

    // MARK: - Init

    init(
        fileManager: FileManager,
        workFolderRoot: URL,
        canonicalRoot: URL,
        internalCanonical: URL?,
        internalRelPrefix: String?,
        compiledGlob: CompiledGlob?,
        listMode: Bool,
        collectTarget: Int,
        roots: [Root]
    ) {
        self.fileManager = fileManager
        self.workFolderRoot = workFolderRoot
        self.canonicalRoot = canonicalRoot
        self.internalCanonical = internalCanonical
        self.internalRelPrefix = internalRelPrefix
        self.compiledGlob = compiledGlob
        self.listMode = listMode
        self.collectTarget = collectTarget
        self.roots = roots
    }

    // MARK: - Iteration

    /// The next thing the walk did, or `nil` once it is done.
    ///
    /// One `advance()` performs one unit of walk work — an entry, a root, a frame pop — and
    /// queues whatever events that produced. Splitting emission from advancement is what lets a
    /// single directory contribute several skips (its symlink-outside entries) ahead of any of
    /// its files, exactly as the recursive version appended them before its entry loop ran.
    mutating func next() -> Step? {
        while true {
            if pendingCursor < pending.count {
                let step = pending[pendingCursor]
                pendingCursor += 1
                if pendingCursor == pending.count {
                    pending.removeAll(keepingCapacity: true)
                    pendingCursor = 0
                }
                return step
            }
            if finished { return nil }
            advance()
        }
    }

    // MARK: - Private

    private mutating func enqueue(_ event: WalkEvent) {
        pending.append(Step(
            event: event, dirsEnumerated: dirsEnumerated, rosterCount: visitedPaths.count))
    }

    /// Central roster gate: dedups on insert and, in list mode, enforces the result cap.
    /// Returns true when `path` was newly admitted. At capacity the first distinct over-cap
    /// candidate flips `rosterTruncated`, which halts the walk — nothing past the cap is added.
    private mutating func admitToRoster(_ path: String) -> Bool {
        guard visitedSet.insert(path).inserted else { return false }
        if listMode && visitedPaths.count >= collectTarget {
            rosterTruncated = true
            return false
        }
        visitedPaths.append(path)
        return true
    }

    /// List mode is the only mode whose stop condition the walker can evaluate on its own.
    /// In content mode the driver owns the stop, because it depends on matches the walk cannot
    /// see; the walker simply keeps producing and the driver rolls the tail back.
    private var shouldStop: Bool { listMode && rosterTruncated }

    private mutating func advance() {
        if shouldStop { finished = true; return }
        if Task.isCancelled { wasCancelled = true; finished = true; return }

        if var frame = stack.popLast() {
            advance(frame: &frame)
            return
        }
        guard rootCursor < roots.count else { finished = true; return }
        let root = roots[rootCursor]
        rootCursor += 1
        switch root {
        case .constrainedFile(let relativePath): admitConstrainedFile(relativePath)
        case .entry(let url): admitRootEntry(url)
        }
    }

    /// One entry of the frame on top of the stack. The frame is popped by the caller and pushed
    /// back unless it is exhausted, so a directory descended into lands ABOVE its parent.
    private mutating func advance(frame: inout Frame) {
        guard frame.index < frame.entries.count else { return }
        let entry = frame.entries[frame.index]
        frame.index += 1
        let parentRelativePath = frame.relativePath
        stack.append(frame)

        guard !WalkSkipRules.shouldSkip(name: entry.name) else { return }

        let itemPath = parentRelativePath.isEmpty
            ? entry.name
            : "\(parentRelativePath)/\(entry.name)"
        // Relative-path prefix compare instead of `SandboxPathResolver.isWithin`, which ran
        // `standardizedFileURL` + two `pathComponents` allocations PER ENTRY — 10 ms of the
        // walk's 25.6 ms. Equivalent because `itemPath` is built purely from names enumerated
        // under the root.
        if let prefix = internalRelPrefix,
           itemPath == prefix || itemPath.hasPrefix(prefix + "/") {
            return
        }

        // RTFD is a file-bundle directory — treat as a single document.
        if entry.isDir && entry.name.hasSuffix(".rtfd") {
            if admitToRoster(itemPath), !listMode {
                enqueue(.candidate(url: entry.url, relativePath: itemPath))
            }
            return
        }

        if entry.isDir {
            enterDirectory(at: entry.url, relativePath: itemPath)
            return
        }
        guard compiledGlob?.matches(entry.name) ?? true else { return }
        guard admitToRoster(itemPath) else { return }
        if !listMode { enqueue(.candidate(url: entry.url, relativePath: itemPath)) }
    }

    private mutating func enterDirectory(at url: URL, relativePath: String) {
        // Cycle detection. `.isDirectoryKey` FOLLOWS symlinks, so `a/loop -> a` recurses until
        // the stack overflows — and on a zero-match query nothing else bounds it. One
        // `resolvingSymlinksInPath()` per DIRECTORY (not per entry) is a few hundred calls on a
        // real tree, far below the read costs this walk already pays.
        //
        // It is reported, not swallowed: silence here is indistinguishable from an empty
        // subtree, which is exactly the confusion `skipped` exists to prevent. The same guard
        // also collapses a plain ALIAS (`alias -> real`, no cycle) to one visit, so the reason
        // names both shapes.
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard visitedDirs.insert(canonical).inserted else {
            enqueue(.skip(SkippedFile(
                path: relativePath.isEmpty ? "." : relativePath,
                reason: "symlink already visited under another path (alias or cycle)"
            )))
            return
        }

        // Prefetch `.isDirectoryKey` so the type comes back with the single readdir the kernel
        // already performed. The old shape called `contentsOfDirectory(atPath:)` (names only,
        // discarding `d_type`) and then paid a SEPARATE `fileExists` stat per entry.
        guard let urls = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            // Deliberately NOT `.skipsHiddenFiles`: `.gitignore` and `.nanoteams` are hidden
            // entries the walk must still see.
            options: []
        ) else { return }
        dirsEnumerated += 1

        var entries: [(name: String, url: URL, isDir: Bool)] = []
        entries.reserveCapacity(urls.count)
        for itemURL in urls {
            // A nil `isDirectory` means the entry vanished or is unreadable.
            guard let rv = try? itemURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                let isDir = rv.isDirectory
            else { continue }

            var isDirValue = isDir
            // What the walk descends into / reads. For a symlink this is the RESOLVED target:
            // `contentsOfDirectory(at:)` returns ZERO entries for a symlink URL (it is not a
            // directory-path URL), so descending into the link itself silently yields an empty
            // subtree — measured, and pinned below.
            var traverseURL = itemURL
            if rv.isSymbolicLink == true {
                // `.isDirectoryKey` describes the LINK, not its target: it reports `false` for a
                // symlink to a directory. The pre-rewrite walk asked `fileExists(atPath:
                // isDirectory:)`, which DOES follow, so a symlinked source tree was searched.
                var targetIsDir: ObjCBool = false
                // A dangling link fails here, which is what `fileExists` did before.
                guard fileManager.fileExists(atPath: itemURL.path, isDirectory: &targetIsDir)
                else { continue }
                // Following a link OUT of the work folder would read files this tool is
                // sandboxed away from — the walk is the one path that never consults
                // `SandboxPathResolver` per entry, so restoring "follow symlinks" without this
                // check would re-open an escape (`outside -> /etc` resolves and reads).
                let target = itemURL.resolvingSymlinksInPath().standardizedFileURL
                let name = itemURL.lastPathComponent
                // `.nanoteams/internal` is excluded by RELATIVE path prefix, and that exclusion
                // rests on an assumption following symlinks breaks: `itemPath` is built from
                // enumerated NAMES, so `peek -> .nanoteams/internal` has relative path `peek`,
                // matches no prefix, and its target is legitimately inside the work folder.
                //
                // Silent, matching `SandboxPathResolver.restrictedPath` (which reports internal
                // paths as "not found"): a notice here would tell the model the internal
                // directory exists and is worth probing.
                if let internalCanonical,
                   SandboxPathResolver.isWithin(candidate: target, container: internalCanonical) {
                    continue
                }
                guard SandboxPathResolver.isWithin(candidate: target, container: canonicalRoot)
                else {
                    enqueue(.skip(SkippedFile(
                        path: relativePath.isEmpty ? name : "\(relativePath)/\(name)",
                        reason: "symlink points outside the work folder"
                    )))
                    continue
                }
                isDirValue = targetIsDir.boolValue
                // Keep the LOGICAL name/path (the link's) for reporting — a match under
                // `alias/a.swift` is a path `read_file` can open — but traverse the target.
                traverseURL = target
            }
            entries.append((itemURL.lastPathComponent, traverseURL, isDirValue))
        }
        // Sort by NAME with Swift's `String <`, reproducing the old `contents.sorted()` over the
        // name array exactly. NOT `localizedStandardCompare` — that is `list_files`'s ordering
        // and would reorder non-ASCII filenames here.
        entries.sort { $0.name < $1.name }

        stack.append(Frame(relativePath: relativePath, entries: entries))
    }

    private mutating func admitConstrainedFile(_ relative: String) {
        let url = workFolderRoot.appendingPathComponent(relative)
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        // Treat .rtfd bundles as single files; otherwise skip directories.
        if isDir.boolValue && !url.pathExtension.lowercased().hasSuffix("rtfd") { return }
        guard compiledGlob?.matches(url.lastPathComponent) ?? true else { return }
        guard admitToRoster(relative) else { return }
        if !listMode { enqueue(.candidate(url: url, relativePath: relative)) }
    }

    private mutating func admitRootEntry(_ dir: URL) {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: dir.path, isDirectory: &isDir) else { return }
        let rel = dir.path.replacingOccurrences(of: workFolderRoot.path + "/", with: "")
        if isDir.boolValue {
            enterDirectory(at: dir, relativePath: rel == dir.path ? "" : rel)
            return
        }
        // Apply `file_glob` uniformly: a single-file `paths` entry is filtered by the glob just
        // like a file found in a directory walk, so a non-matching named file doesn't slip past.
        guard compiledGlob?.matches(dir.lastPathComponent) ?? true else { return }
        // Mirror the dir-walk: also feed single-file `paths` entries into the roster so filename
        // matching sees them. Without this, `paths: ["foo.swift"]` would silently omit the only
        // candidate from the filename-match scan. No stop gate here: list mode is already
        // bounded by `admitToRoster`, and an explicitly-named file stays visible for filename
        // matching even once the content budget is full.
        if admitToRoster(rel), !listMode {
            enqueue(.candidate(url: dir, relativePath: rel))
        }
    }
}
