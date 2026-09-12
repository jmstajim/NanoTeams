import Foundation

/// The index's single walk of the work folder: one pass, one result.
///
/// Split out of `SearchIndexService` (718 lines, three reasons to change) so the actor keeps
/// persistence and the build lifecycle while this owns "what files are there, and what are
/// their `(mTime, size)`". The walk runs once per `loadOrBuild` and feeds BOTH the freshness
/// diff and the content passes — the shape it replaces walked the tree twice, once for a
/// signature probe and once to build.
nonisolated struct SearchIndexWalker {

    /// One walk's outcome.
    struct Result {
        let candidates: [SearchIndexPlanner.IndexCandidate]
        let warnings: [String]
        /// `false` when the walk was cancelled part-way.
        ///
        /// Without this flag a truncated candidate list is indistinguishable from a tree whose
        /// files were deleted, and the diff reads it as a mass deletion (Д2) — so an incomplete
        /// walk earns no right to a diff and no right to persist.
        let isComplete: Bool
    }

    private let workFolderRoot: URL
    private let internalDir: URL
    private let fileManager: FileManager

    /// The root with symlinks resolved — what a symlink TARGET must be inside of to be indexed.
    private let canonicalRoot: URL
    /// The same for `.nanoteams/internal`, or `nil` when it lies outside the root.
    private let internalCanonical: URL?

    /// `.nanoteams/internal` as a work-folder-relative prefix, computed once.
    ///
    /// The fast path for non-symlinks. The walk used to call `SandboxPathResolver.isWithin` on
    /// EVERY entry — two `standardizedFileURL` normalisations plus two `pathComponents`
    /// allocations apiece; the same substitution in `SearchExecutor` was measured at 10 ms of a
    /// 25.6 ms walk. `nil` when the internal dir lies outside the root, in which case nothing
    /// the walk enumerates can be inside it and "no prefix" is the correct answer.
    private let internalRelPrefix: String?

    init(workFolderRoot: URL, internalDir: URL, fileManager: FileManager) {
        self.workFolderRoot = workFolderRoot
        self.internalDir = internalDir
        self.fileManager = fileManager
        self.canonicalRoot = workFolderRoot.resolvingSymlinksInPath().standardizedFileURL
        let resolvedInternal = internalDir.resolvingSymlinksInPath().standardizedFileURL
        self.internalCanonical = SandboxPathResolver.isWithin(
            candidate: resolvedInternal, container: canonicalRoot) ? resolvedInternal : nil

        let rootComponents = workFolderRoot.standardizedFileURL.pathComponents
        let dirComponents = internalDir.standardizedFileURL.pathComponents
        if dirComponents.count > rootComponents.count,
           Array(dirComponents.prefix(rootComponents.count)) == rootComponents {
            self.internalRelPrefix = dirComponents
                .dropFirst(rootComponents.count).joined(separator: "/")
        } else {
            self.internalRelPrefix = nil
        }
    }

    /// Truncates a `Date` down to millisecond precision — the resolution of our
    /// ISO-8601-with-fractional-seconds persistence format.
    ///
    /// Without this, nanosecond-precision mTimes survive in memory but are lost on JSON
    /// round-trip, so a file loaded from disk never compares equal to the same file freshly
    /// walked and would be re-tokenized on every single build, forever. Rounding mode does not
    /// matter as long as both sides apply the same function; `.down` matches how the serializer
    /// clamps the fractional part.
    ///
    /// Trade-off: two edits of one file within the same millisecond that ALSO preserve its size
    /// are indistinguishable. The churn budget is the backstop for that class.
    static func normalizedMTime(_ date: Date) -> Date {
        let ms = (date.timeIntervalSince1970 * 1000).rounded(.down) / 1000
        return Date(timeIntervalSince1970: ms)
    }

    /// Walks the folder once and returns every file-like entry it found, `.rtfd` bundles
    /// included (they are single documents, not directories).
    func walk() -> Result {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: workFolderRoot.path, isDirectory: &isDir),
              isDir.boolValue
        else { return Result(candidates: [], warnings: [], isComplete: true) }
        // Cycle detection: canonical (symlink-resolved) paths of directories already entered.
        // Without it, a symlink pointing at an ancestor (`a/loop -> a/`) recurses until the
        // stack overflows — a real failure mode in synced folders.
        var visited: Set<String> = []
        var candidates: [SearchIndexPlanner.IndexCandidate] = []
        var warnings: [String] = []
        let completed = walkRecursive(
            workFolderRoot, relativePath: "", warnings: &warnings, visited: &visited,
            into: &candidates)
        return Result(candidates: candidates, warnings: warnings, isComplete: completed)
    }

    /// Resource keys prefetched during enumeration. `contentsOfDirectory(at:)` fills these from
    /// the bulk directory read the kernel already performed, so asking for four costs what
    /// asking for one does — and saves a `stat` per entry plus an `attributesOfItem` per file.
    private static let walkResourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey,
    ]

    /// Returns `false` if the walk was cancelled anywhere in this subtree.
    ///
    /// `relativePath` is this directory's path from the work-folder root, built purely from the
    /// NAMES enumerated on the way down and never derived from `dir`'s absolute path. That is
    /// the whole invariant. `dir` is the url to READ — the resolved target once the walk crosses
    /// a symlink, because `contentsOfDirectory(at:)` returns zero entries for a link url — while
    /// `relativePath` is the path to REPORT, which keeps the LINK's own name. The two are
    /// allowed to describe different places, and deriving the second from the first is exactly
    /// the shape this replaces: under a crossed symlink the absolute path no longer starts at
    /// the root, so the prefix test fell through to the target's own route, and with a symlinked
    /// ROOT to the bare filename. `read_file` cannot open that, and two same-named files under
    /// one crossed link turn it into a DUPLICATE roster path that `SearchIndex.init(from:)`
    /// rejects on every later launch — permanently, because the rebuild that rejection triggers
    /// walks the same tree and mints it again.
    private func walkRecursive(
        _ dir: URL,
        relativePath: String,
        warnings: inout [String],
        visited: inout Set<String>,
        into candidates: inout [SearchIndexPlanner.IndexCandidate]
    ) -> Bool {
        // Cancellation check at each directory entry: if the enclosing Task was cancelled (e.g.
        // `coordinator.stop()` fired because the user toggled exploratory search OFF), abandon
        // the walk instead of finishing it synchronously on the actor.
        if Task.isCancelled { return false }

        // Work-folder-relative, like `SearchDirectoryWalker`'s skips: a warning that can be
        // joined against the roster it is about, and no machine directory layout in a string the
        // settings card surfaces.
        let here = relativePath.isEmpty ? "." : relativePath

        let canonical = dir.resolvingSymlinksInPath().standardizedFileURL.path
        guard !visited.contains(canonical) else {
            // "or alias", because the guard fires far more often for a plain second route to the
            // same directory than for a true cycle — the grep walk already says so. Which route
            // WINS is decided by sort order, so the roster can name a file under the path the
            // user thinks of as secondary; that is the price of reading it once.
            warnings.append("symlink cycle or alias skipped at \(here)")
            return true
        }
        visited.insert(canonical)

        let contents: [URL]
        do {
            // Enumerate the RESOLVED directory, not `dir`. `contentsOfDirectory(at:)` returns
            // ZERO entries for a symlink URL — it is not a directory-path URL — where the
            // path-based call this replaces followed the link implicitly. A `mirror -> real/`
            // link would otherwise yield an empty subtree AND poison the cycle guard with
            // `real`'s canonical path, so the real directory would be skipped too.
            contents = try fileManager.contentsOfDirectory(
                at: URL(fileURLWithPath: canonical, isDirectory: true),
                includingPropertiesForKeys: Self.walkResourceKeys, options: [])
        } catch {
            // Unreadable subdir (EACCES, EIO, broken symlink). Record and move on — one bad
            // subtree must not silently truncate the whole index.
            warnings.append("walk error at \(here): \(error.localizedDescription)")
            return true
        }
        // Sorted only so warnings reach the settings card in a stable order. Candidate ORDER
        // carries no meaning any more: the positional file IDs that postings indexed into are
        // gone, and the diff is keyed by path.
        let entries = contents.sorted { $0.lastPathComponent < $1.lastPathComponent }

        var completed = true
        for enumerated in entries {
            let name = enumerated.lastPathComponent
            guard !WalkSkipRules.shouldSkip(name: name) else { continue }
            // Bookkeeping files that live directly in `.nanoteams/` (e.g. `.gitignore`). The
            // test is on the PHYSICAL `dir`, not on the reported path: `.gitignore` there is the
            // marker `NTMSRepository.ensureLayout` writes into the real `.nanoteams/`, and it is
            // still that marker when reached through a link with another name.
            // User-facing content under `.nanoteams/` — attachments, artifacts — still
            // traverses.
            if dir.lastPathComponent == ".nanoteams",
               WalkSkipRules.skippedInsideNanoteamsDir.contains(name) { continue }
            // The path to REPORT: this directory's, plus one enumerated name. Two string
            // operations, no URL normalisation and no prefix scan — and, unlike a derived path,
            // nothing here can fall back to something shorter without anyone noticing.
            let relative = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
            // Sound precisely because `relative` is a name chain: `internalRelPrefix` is also
            // one (`internalDir`'s components minus the root's, both from the same unresolved
            // root), so two chains anchored at the same node compare correctly.
            if let prefix = internalRelPrefix,
               relative == prefix || relative.hasPrefix(prefix + "/") { continue }
            // The LOGICAL url, built on `dir`. Below a crossed symlink `dir` is the resolved
            // target, so this is the url that OPENS the file; the route that named it travels
            // beside it in `relative`.
            let itemURL = dir.appendingPathComponent(name)

            // Resource values come from the ENUMERATED url, where the directory read already
            // prefetched them; asking `itemURL` would re-stat through the link.
            //
            // ONE gate, and it warns. The shape this replaces had two — "cannot tell what it
            // is" (silent) and "know what it is, cannot read its attributes" (warned) — and the
            // second was unreachable once mTime and size came from the same prefetch that
            // reported the type.
            guard let entry = entryAttributes(
                of: enumerated, logicalURL: itemURL, name: name, relative: relative,
                warnings: &warnings) else { continue }
            guard case .fileLike(let mTime, let size) = entry.kind else {
                if !walkRecursive(entry.traverseURL, relativePath: relative, warnings: &warnings,
                                  visited: &visited, into: &candidates) {
                    completed = false
                    // A cancelled subtree means the candidate list is truncated; there is
                    // nothing useful left to enumerate, so stop rather than pay for siblings
                    // whose results cannot be trusted either.
                    return false
                }
                continue
            }
            candidates.append(SearchIndexPlanner.IndexCandidate(
                url: itemURL,
                relativePath: relative,
                isRTFDBundle: name.hasSuffix(".rtfd"),
                mTime: Self.normalizedMTime(mTime),
                size: size))
        }
        return completed
    }

    /// What one directory entry turned out to be.
    ///
    /// An `.rtfd` bundle is a DIRECTORY that is a file, which is why the two cases are named for
    /// what the walk does with them rather than for what the file system calls them.
    private enum WalkEntryKind {
        /// Descend into it.
        case directory
        /// Index it: a file, or an `.rtfd` bundle.
        case fileLike(mTime: Date, size: Int64)
    }

    /// An entry's classification plus the url to descend into — the LOGICAL url for an ordinary
    /// directory, the resolved target for a symlink (whose logical url enumerates as empty).
    ///
    /// `traverseURL` carries NO meaning about the path to report. That separation is the fix:
    /// the reported path is a chain of enumerated names threaded down `walkRecursive`, and this
    /// is only where to read next.
    private struct WalkEntry {
        let kind: WalkEntryKind
        let traverseURL: URL
    }

    /// Classifies one entry from its prefetched resource values, or `nil` when it must not be
    /// indexed — it vanished between the directory read and here, its target does not resolve,
    /// or it is a symlink leading somewhere the index is not allowed to follow (Д5).
    ///
    /// For a SYMLINK the resource values describe the LINK, so the target is resolved here; the
    /// shape this replaces resolved it too, but checked NOTHING about where it pointed. The
    /// relative-prefix exclusion above cannot cover that case by construction: `notes ->
    /// .nanoteams/internal` has relative path `notes`, matches no prefix, and its target is
    /// legitimately inside the work folder — so `teams.json` was tokenized, and under an
    /// incremental vocabulary it would have stayed in the index until a full rebuild. The grep
    /// walk has carried both of these checks since it learned to follow symlinks.
    private func entryAttributes(
        of url: URL, logicalURL: URL, name: String, relative: String, warnings: inout [String]
    ) -> WalkEntry? {
        guard let values = try? url.resourceValues(forKeys: Set(Self.walkResourceKeys)),
              let isDirectory = values.isDirectory
        else {
            // Never silent: skipping is right (a placeholder entry with a `.distantPast` mTime
            // and size 0 would churn the roster forever), but a walk that quietly drops entries
            // is indistinguishable from a small tree.
            warnings.append("unreadable directory entry at \(relative)")
            return nil
        }
        // What the entry ultimately IS, and where to traverse. For an ordinary entry that is
        // the logical url; for a symlink it is the resolved target, because
        // `contentsOfDirectory(at:)` returns zero entries for a link url.
        var subject = (url: logicalURL, isDirectory: isDirectory, values: values)
        if values.isSymbolicLink == true {
            let target = url.resolvingSymlinksInPath().standardizedFileURL
            // Silent, matching `SandboxPathResolver.restrictedPath` (which reports internal
            // paths as "not found"): a warning here would tell the model the internal directory
            // exists and is worth probing.
            if let internalCanonical,
               SandboxPathResolver.isWithin(candidate: target, container: internalCanonical) {
                return nil
            }
            guard SandboxPathResolver.isWithin(candidate: target, container: canonicalRoot) else {
                warnings.append("symlink points outside the work folder at \(relative)")
                return nil
            }
            guard let resolved = try? target.resourceValues(forKeys: Set(Self.walkResourceKeys)),
                  let targetIsDirectory = resolved.isDirectory
            else {
                // A dangling link: the target does not exist, or cannot be described.
                warnings.append("unreadable symlink target at \(relative)")
                return nil
            }
            subject = (target, targetIsDirectory, resolved)
        }
        // ONE classification, for both shapes. Two calls meant two identical "cannot be
        // characterised" arms, of which a test could only ever reach one.
        guard let kind = classify(
            url: subject.url, name: name, isDirectory: subject.isDirectory,
            values: subject.values) else {
            warnings.append("unreadable directory entry at \(relative)")
            return nil
        }
        return WalkEntry(kind: kind, traverseURL: subject.url)
    }

    private func classify(
        url: URL, name: String, isDirectory: Bool, values: URLResourceValues
    ) -> WalkEntryKind? {
        let isRTFD = isDirectory && name.hasSuffix(".rtfd")
        if isDirectory && !isRTFD { return .directory }
        guard let mTime = values.contentModificationDate else { return nil }
        // `.fileSizeKey` is nil for a DIRECTORY, and an `.rtfd` bundle is the one file-like
        // entry that is one — so the prefetch cannot answer for it. The fallback is a single
        // `attributesOfItem` per bundle, which is what the whole walk used to pay per FILE.
        let size = values.fileSize.map(Int64.init)
            ?? ((try? fileManager.attributesOfItem(atPath: url.path))?[.size]
                as? NSNumber)?.int64Value
        guard let size else { return nil }
        return .fileLike(mTime: mTime, size: size)
    }

}
