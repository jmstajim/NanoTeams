import XCTest
@testable import NanoTeams

/// The feature itself, over a real file system: a build reads only the files that changed.
///
/// `SearchIndexPlannerTests` proves the decisions; this proves the wiring — that the walk, the
/// diff, the content passes and persistence agree with each other on a tree that actually moves.
final class SearchIndexIncrementalTests: XCTestCase {

    var tempDir: URL!
    var internalDir: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        internalDir = tempDir.appendingPathComponent(".nanoteams/internal", isDirectory: true)
        try fm.createDirectory(at: internalDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            // Anything left at 0o000 by a test would defeat the recursive remove.
            if let all = fm.enumerator(at: tempDir, includingPropertiesForKeys: nil) {
                for case let url as URL in all { chmod(url.path, 0o700) }
            }
            try? fm.removeItem(at: tempDir)
        }
        tempDir = nil
        internalDir = nil
        try super.tearDownWithError()
    }

    private func write(_ relPath: String, _ content: String) throws {
        let url = tempDir.appendingPathComponent(relPath)
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeService() -> SearchIndexService { makeService(root: tempDir) }

    /// The same service against an arbitrary root, so a test can open the folder through a path
    /// that is itself a symlink — the shape production reaches by way of a security-scoped
    /// bookmark, which round-trips whatever spelling the user picked in the open panel.
    private func makeService(root: URL) -> SearchIndexService {
        SearchIndexService(
            workFolderRoot: root,
            internalDir: root.appendingPathComponent(".nanoteams/internal", isDirectory: true),
            fileManager: .default)
    }

    private var indexFileURL: URL { internalDir.appendingPathComponent("search_index.json") }

    private func mTime(of url: URL) throws -> Date {
        try XCTUnwrap(fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }

    // MARK: - The sandwich

    /// The safety net for the whole design: an incremental result must agree with a full
    /// rebuild of the same tree.
    ///
    /// - the ROSTER must be identical — that is exact, and it is what the next diff reads;
    /// - the VOCABULARY must be a superset — an increment only ever adds, so words of deleted
    ///   files linger. That asymmetry is deliberate and bounded by the churn budget;
    /// - forcing a rebuild over the incremental result must CONVERGE on the full one, or the
    ///   drift would be permanent rather than bounded.
    ///
    /// RED: stamp a file whose pass did not run (append a fresh roster row in `merge`'s
    /// `.cancelled` arm) → the two rosters stop matching and `newword` goes missing.
    func testSandwich_incrementalAgreesWithAFullRebuild() async throws {
        try write("keep.swift", "let keepword = 1")
        try write("edit.swift", "let oldword = 2")
        try write("gone.swift", "let goneword = 3")
        // Ballast: the churn budget is a SHARE of the roster, so on three files a
        // three-file mutation is a full rebuild and there would be no increment to compare.
        // Fifteen files put the budget at four.
        for i in 0..<12 { try write("ballast\(i).swift", "let ballastword = \(i)") }

        let service = makeService()
        let first = await service.loadOrBuild()
        XCTAssertTrue(first.vocabulary.contains("goneword"), "anti-vacuum: the first build read it")
        await service.flush()

        // Mutate: one added, one changed, one deleted.
        try write("added.swift", "let addedword = 4")
        try write("edit.swift", "let newword = 2")
        try fm.removeItem(at: tempDir.appendingPathComponent("gone.swift"))

        // B: incremental, continuing from the saved index.
        let incremental = makeService()
        let b = await incremental.loadOrBuild()

        // C: full rebuild of the same tree, from nothing.
        let fresh = makeService()
        let c = await fresh.loadOrBuild(force: true)

        XCTAssertEqual(b.files.map(\.path).sorted(), c.files.map(\.path).sorted(),
                       "the roster is the diff base — it must be exact")
        XCTAssertEqual(b.files.count, 15)
        XCTAssertTrue(b.vocabulary.contains("addedword"), "the new file was read")
        XCTAssertTrue(b.vocabulary.contains("newword"), "the changed file was re-read")
        XCTAssertTrue(b.vocabulary.contains("keepword"), "the untouched file kept its words")
        XCTAssertTrue(c.vocabulary.isSubset(of: b.vocabulary),
                      "an increment may hold MORE than the truth, never less: "
                          + "\(c.vocabulary.subtracting(b.vocabulary))")
        XCTAssertTrue(b.vocabulary.contains("goneword"),
                      "…and 'more' is specifically the deleted file's words, until a full "
                          + "rebuild collects them")

        let converged = await incremental.loadOrBuild(force: true)
        XCTAssertEqual(converged.vocabulary, c.vocabulary,
                       "a full rebuild must reach the same vocabulary from either side, or the "
                           + "drift is permanent rather than bounded")
    }

    // MARK: - Only the changed file is read

    /// The feature, stated as the thing it saves: after a baseline build, make every file but
    /// one unreadable and touch that one. An incremental build reads exactly one file, so it
    /// reports NOTHING — while a forced rebuild reports every locked file.
    ///
    /// `chmod 0o000` is the instrument because it fails the READ and not the stat, and because
    /// it does not move mTime — so the locked files stay clean by the diff. A stub
    /// `FileManager` cannot do this job: `Data(contentsOf:)` does not go through one.
    ///
    /// RED: read every candidate instead of `diff.dirty` → the incremental warning list fills
    /// up with the locked files, and in production every edit re-reads the whole tree.
    func testIncrementalBuild_readsOnlyTheDirtyFile() async throws {
        for i in 0..<6 { try write("f\(i).swift", "let word\(i) = \(i)") }
        let service = makeService()
        _ = await service.loadOrBuild()
        let baselineWarnings = await service.lastIndexWarnings
        XCTAssertTrue(baselineWarnings.isEmpty, "arrange: a clean baseline")

        // Lock everything except f0, which we then edit.
        for i in 1..<6 { chmod(tempDir.appendingPathComponent("f\(i).swift").path, 0o000) }
        defer { for i in 1..<6 { chmod(tempDir.appendingPathComponent("f\(i).swift").path, 0o600) } }
        try XCTSkipIf(
            (try? Data(contentsOf: tempDir.appendingPathComponent("f1.swift"))) != nil,
            "running as root — the locked files are still readable, so nothing here is exercised")
        try write("f0.swift", "let freshword = 0")

        let incremental = await service.loadOrBuild()
        XCTAssertTrue(incremental.vocabulary.contains("freshword"), "the edit was picked up")
        let incrementalWarnings = await service.lastIndexWarnings
        XCTAssertEqual(incrementalWarnings, [],
                       "the five locked files were never opened — that IS the feature")

        let forced = await service.loadOrBuild(force: true)
        let forcedWarnings = await service.lastIndexWarnings
        XCTAssertEqual(forcedWarnings.count, 5,
                       "…and a forced rebuild opens them all, which is how we know the lock "
                           + "was real")
        XCTAssertEqual(forced.files.count, 1, "only f0 could be read, so only f0 is stamped")
    }

    // MARK: - Persistence timing

    /// An increment stays in memory. The write happens at closing time — that is the whole
    /// point of reading only the dirty files, since a megabyte of I/O per edit would undo the
    /// saving.
    ///
    /// RED: call `persist` on the incremental arm → the file's mTime moves and every keystroke
    /// rewrites the index.
    func testIncrementalBuild_doesNotTouchTheFileOnDisk() async throws {
        try write("A.swift", "let alpha = 1")
        let service = makeService()
        _ = await service.loadOrBuild()
        let afterFullBuild = try mTime(of: indexFileURL)

        try await Task.sleep(for: .milliseconds(20))
        try write("B.swift", "let beta = 2")
        let incremental = await service.loadOrBuild()
        XCTAssertTrue(incremental.vocabulary.contains("beta"), "arrange: the increment ran")
        XCTAssertEqual(try mTime(of: indexFileURL), afterFullBuild,
                       "an increment must not rewrite the file")

        await service.flush()
        XCTAssertGreaterThan(try mTime(of: indexFileURL), afterFullBuild,
                             "…and flush() is what writes it")
    }

    /// A full rebuild checkpoints immediately: it costs seconds of tokenization, and re-paying
    /// that after a crash is the one loss worth a write.
    func testFullRebuild_checkpointsImmediately() async throws {
        try write("A.swift", "let alpha = 1")
        let service = makeService()
        _ = await service.loadOrBuild()
        XCTAssertTrue(fm.fileExists(atPath: indexFileURL.path))
    }

    /// `flush()` with nothing outstanding must not rewrite a megabyte — closing a folder
    /// nobody edited is free.
    func testFlush_withNothingUnsaved_doesNotWrite() async throws {
        try write("A.swift", "let alpha = 1")
        let service = makeService()
        _ = await service.loadOrBuild()
        let afterBuild = try mTime(of: indexFileURL)

        try await Task.sleep(for: .milliseconds(20))
        await service.flush()
        XCTAssertEqual(try mTime(of: indexFileURL), afterBuild)
    }

    // MARK: - Across a restart

    /// The point of persisting the roster at all: a NEW process must re-read only what changed
    /// while the folder was closed.
    func testAcrossRestart_onlyTheChangedFileIsRead() async throws {
        for i in 0..<4 { try write("f\(i).swift", "let word\(i) = \(i)") }
        let first = makeService()
        _ = await first.loadOrBuild()
        await first.flush()

        try write("f0.swift", "let restartword = 0")
        for i in 1..<4 { chmod(tempDir.appendingPathComponent("f\(i).swift").path, 0o000) }
        defer { for i in 1..<4 { chmod(tempDir.appendingPathComponent("f\(i).swift").path, 0o600) } }
        try XCTSkipIf(
            (try? Data(contentsOf: tempDir.appendingPathComponent("f1.swift"))) != nil,
            "running as root")

        let reopened = makeService()
        let index = await reopened.loadOrBuild()
        XCTAssertTrue(index.vocabulary.contains("restartword"))
        XCTAssertTrue(index.vocabulary.contains("word3"),
                      "a file that was never re-read keeps the words the previous process found")
        let warnings = await reopened.lastIndexWarnings
        XCTAssertEqual(warnings, [],
                       "the locked files were not opened — the roster on disk said they were "
                           + "clean")
    }

    // MARK: - Date precision

    /// A file must not be re-tokenized forever because its mTime lost precision on the way to
    /// disk. The persistence format carries milliseconds; the file system carries nanoseconds.
    ///
    /// RED: drop `normalizedMTime` from the walk → the round-tripped roster never matches a
    /// fresh walk, every build is a full re-read of every file, and nothing looks wrong.
    func testMTimePrecision_survivesTheDiskRoundTrip() async throws {
        for i in 0..<5 { try write("f\(i).swift", "let word\(i) = \(i)") }
        let first = makeService()
        let built = await first.loadOrBuild()
        await first.flush()

        let reopened = makeService()
        let reloaded = await reopened.loadOrBuild()
        XCTAssertEqual(reloaded.generatedAt, built.generatedAt,
                       "nothing changed, so the reopened index must be the SAME index — a "
                           + "different stamp means every file was read again")
    }

    // MARK: - Deletion

    func testDeletedFile_leavesTheRosterWithoutReadingAnything() async throws {
        try write("A.swift", "let alpha = 1")
        try write("B.swift", "let beta = 2")
        let service = makeService()
        _ = await service.loadOrBuild()

        try fm.removeItem(at: tempDir.appendingPathComponent("B.swift"))
        let after = await service.loadOrBuild()
        XCTAssertEqual(after.files.map(\.path), ["A.swift"])
        XCTAssertTrue(after.vocabulary.contains("beta"),
                      "its words linger until a full rebuild — bounded by the churn budget")
        XCTAssertEqual(after.changedSinceFullBuild, 1)
    }

    // MARK: - The churn budget, end to end

    /// Enough small edits and a full rebuild fires by itself, collecting the dead words.
    ///
    /// RED: make the budget per-run instead of cumulative → `goneword` is still in the
    /// vocabulary after twenty edits, and after two hundred.
    func testChurnBudget_eventuallyCollectsTheWordsOfDeletedFiles() async throws {
        for i in 0..<8 { try write("f\(i).swift", "let word\(i) = \(i)") }
        try write("gone.swift", "let goneword = 1")
        let service = makeService()
        _ = await service.loadOrBuild()

        try fm.removeItem(at: tempDir.appendingPathComponent("gone.swift"))
        var index = await service.loadOrBuild()
        XCTAssertTrue(index.vocabulary.contains("goneword"), "one deletion is just an increment")

        // Budget over a roster of 8 is ⌈0.25 × 8⌉ = 2, and the deletion already spent one.
        // Two more edits: the first lands on the budget, the second crosses it.
        for i in 0..<2 {
            try write("f\(i).swift", "let edited\(i) = \(i)")
            index = await service.loadOrBuild()
        }
        XCTAssertEqual(index.changedSinceFullBuild, 0,
                       "the budget was exhausted, so a full rebuild ran and reset it")
        XCTAssertFalse(index.vocabulary.contains("goneword"),
                       "…and that rebuild is what collects a deleted file's words")
    }

    // MARK: - Cancellation

    /// A cancelled build must leave NOTHING behind: no cache, no file, no diff. A truncated
    /// candidate list is indistinguishable from a mass deletion, and acting on it would drop
    /// the vocabulary of every file the walk had not reached yet (Д2).
    ///
    /// RED: drop the `walk.isComplete` guard → the on-disk index is replaced by one describing
    /// a fraction of the tree.
    func testCancelledBuild_persistsNothing() async throws {
        for i in 0..<200 { try write("pkg\(i % 8)/f\(i).swift", "let word\(i) = \(i)") }

        let service = makeService()
        let task = Task { await service.loadOrBuild(force: true) }
        task.cancel()
        _ = await task.value

        XCTAssertFalse(fm.fileExists(atPath: indexFileURL.path),
                       "a build that was cancelled before it finished must not leave a "
                           + "half-tree index on disk")
    }

    /// …and the next build, uncancelled, produces the whole thing.
    func testCancelledBuild_isFinishedByTheNextOne() async throws {
        // Each word lands in TWO files. A roster of 50 is over the filter's skip threshold, so
        // a word appearing in exactly one file is dropped as a singleton — which would make
        // this test about the filter rather than about resuming a cancelled build.
        for i in 0..<50 { try write("f\(i).swift", "let word\(i) = 1\nlet word\(i + 1) = 1") }
        let service = makeService()
        let task = Task { await service.loadOrBuild(force: true) }
        task.cancel()
        _ = await task.value

        let complete = await service.loadOrBuild()
        XCTAssertEqual(complete.files.count, 50)
        XCTAssertTrue(complete.vocabulary.contains("word49"))
    }

    // MARK: - Symlink containment (Д5)

    /// A symlink whose target is inside `.nanoteams/internal` must be skipped SILENTLY.
    ///
    /// The relative-prefix exclusion cannot catch this by construction: `notes ->
    /// .nanoteams/internal` has relative path `notes`, matches no prefix, and its target is
    /// legitimately inside the work folder. Silent because a warning would tell the model the
    /// internal directory exists — the same reason `SandboxPathResolver.restrictedPath` reports
    /// "file not found".
    ///
    /// Worse under an incremental vocabulary than it was before: a word read once now stays in
    /// the index until a full rebuild.
    ///
    /// RED: drop the `internalCanonical` check from `entryAttributes` → `teamsecret` is in the
    /// vocabulary.
    func testSymlinkIntoInternalDir_isSkippedSilently() async throws {
        try write("A.swift", "let alpha = 1")
        try Data("let teamsecret = 1".utf8)
            .write(to: internalDir.appendingPathComponent("teams.json"))
        try fm.createSymbolicLink(at: tempDir.appendingPathComponent("notes"),
                                  withDestinationURL: internalDir)

        let service = makeService()
        let index = await service.loadOrBuild()

        XCTAssertFalse(index.vocabulary.contains("teamsecret"),
                       "the internal directory is not indexable through an alias either")
        XCTAssertFalse(index.files.contains { $0.path.hasPrefix("notes") })
        let warnings = await service.lastIndexWarnings
        XCTAssertEqual(warnings, [],
                       "and silently: a message here would confirm the directory exists")
    }

    /// A dangling symlink — one whose target does not exist — is skipped with a warning
    /// naming it, rather than dropped in silence or stamped into the roster with invented
    /// attributes.
    ///
    /// RED: return `nil` without appending in the resolved-values guard → the entry vanishes
    /// and a tree with a broken link is indistinguishable from a smaller tree.
    func testDanglingSymlink_isSkippedWithAWarning() async throws {
        try write("A.swift", "let alpha = 1")
        try fm.createSymbolicLink(
            at: tempDir.appendingPathComponent("broken.swift"),
            withDestinationURL: tempDir.appendingPathComponent("does-not-exist.swift"))

        let service = makeService()
        let index = await service.loadOrBuild()

        XCTAssertFalse(index.files.contains { $0.path == "broken.swift" })
        let warnings = await service.lastIndexWarnings
        XCTAssertTrue(warnings.contains { $0.contains("broken.swift") }, "got: \(warnings)")
    }

    /// The OTHER way a build is abandoned: the walk finished, but a content pass was cancelled.
    ///
    /// Deterministic despite the concurrency, and the flat fixture is what makes it so: with
    /// every file in ONE directory the walk checks `Task.isCancelled` exactly once, on entry.
    /// A cancellation that lands after that cannot be seen by the walk at all — so the walk
    /// necessarily reports complete, and the cancellation necessarily lands in the passes.
    ///
    /// RED: let `SearchIndexPlanner.build` skip `.cancelled` passes the way it skips
    /// `.unreadable` ones → a fraction of the tree is written to disk as though it were the
    /// whole vocabulary, and the filter drops its shared words as singletons.
    func testCancelledContentPass_abandonsTheBuildAndKeepsWhatWasThere() async throws {
        for i in 0..<1500 { try write("f\(i).swift", "let word\(i) = \(i)") }

        let service = makeService()
        let task = Task { await service.loadOrBuild(force: true) }
        // Long enough that the task has entered the walk, short enough that a 1500-file build
        // is nowhere near done (a full rebuild of 2154 files measures 4.7 s).
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        let abandoned = await task.value

        XCTAssertTrue(abandoned.files.isEmpty,
                      "nothing was there before, so nothing is what comes back")
        XCTAssertFalse(fm.fileExists(atPath: indexFileURL.path),
                       "a partial full build must not be checkpointed")

        let complete = await service.loadOrBuild()
        XCTAssertEqual(complete.files.count, 1500, "…and the next build does the whole job")
    }

    /// A symlink pointing OUT of the work folder is skipped with a warning — the user asked for
    /// something the sandbox cannot honour, and unlike the internal case there is nothing to
    /// conceal.
    ///
    /// RED: drop the `canonicalRoot` check → files outside the work folder are tokenized into
    /// the index, which is the escape the grep walk has guarded since it learned to follow
    /// symlinks.
    func testSymlinkOutsideTheWorkFolder_isSkippedWithAWarning() async throws {
        try write("A.swift", "let alpha = 1")
        let outside = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outside) }
        try Data("let outsideword = 1".utf8)
            .write(to: outside.appendingPathComponent("Secret.swift"))
        try fm.createSymbolicLink(at: tempDir.appendingPathComponent("escape"),
                                  withDestinationURL: outside)

        let service = makeService()
        let index = await service.loadOrBuild()

        XCTAssertFalse(index.vocabulary.contains("outsideword"))
        let warnings = await service.lastIndexWarnings
        XCTAssertTrue(warnings.contains { $0.contains("escape") }, "got: \(warnings)")
    }

    // MARK: - Logical paths across a directory symlink

    /// A roster path is the chain of NAMES the walk enumerated on its way down, not a string
    /// derived from where the entry physically lives.
    ///
    /// The two are the same until the walk crosses a directory symlink. From there the walk
    /// reads the RESOLVED target — it must, because `contentsOfDirectory(at:)` returns zero
    /// entries for a link url — so a path derived from the entry's own absolute url describes
    /// the target, not the route taken to it. `SearchIndexServiceTests`'
    /// `testWalk_symlinkToFile_indexesTargetSizeUnderTheLinkPath` already fixes the house
    /// semantics for a symlink to a FILE; this is the same rule one level up.
    ///
    /// The `fileExists` loop is the assertion that matters: every roster path is handed to the
    /// model as a `filename_matches` entry, so a path that does not open from the root is a
    /// `read_file` failure the model was invited to make.
    ///
    /// RED: derive the path from the entry's absolute url against the root's prefix
    /// (`relativePath(from:)`) instead of threading it down the recursion → the walk enumerates
    /// the resolved target, the prefix stops matching, and the roster says `deep/a.swift` or
    /// `a.swift` — neither of which opens from the work folder root.
    func testWalk_underADirectorySymlink_indexesUnderTheLinkPath() async throws {
        try write("real/deep/a.swift", "let underalias = 1")
        try fm.createSymbolicLink(at: tempDir.appendingPathComponent("mirror"),
                                  withDestinationURL: tempDir.appendingPathComponent("real"))

        let index = await makeService().loadOrBuild()

        // `mirror` sorts before `real`, so the link is entered first and the real directory is
        // then collapsed by the cycle guard — one row, named for the route that reached it.
        XCTAssertEqual(index.files.map(\.path), ["mirror/deep/a.swift"])
        XCTAssertTrue(index.vocabulary.contains("underalias"), "anti-vacuum: the file was read")
        for file in index.files {
            XCTAssertTrue(
                fm.fileExists(atPath: tempDir.appendingPathComponent(file.path).path),
                "roster path '\(file.path)' does not open from the work folder root")
        }
    }

    /// The permanent half: a roster path derived from a string prefix can COLLIDE, and a
    /// duplicate path is the one defect this index cannot recover from on its own.
    ///
    /// `SearchIndex.init(from:)` rejects a duplicate path on decode, a full rebuild checkpoints
    /// itself immediately, and the rebuild that rejection triggers walks the same tree — so the
    /// index is unloadable on every launch, forever, and the second row also diffs as `added`
    /// on every build, which burns the churn budget and puts `.reuse` permanently out of reach.
    ///
    /// The root is opened through `alias` on purpose: it is the shape that makes the failure
    /// visible on an ordinary root such as `~/Developer -> /Volumes/SSD/Developer`, and it does
    /// not depend on whether the test's temp directory happens to sit under a symlink.
    ///
    /// RED: derive each path from its absolute url against the root's prefix → both files come
    /// back as `a.swift`, `SearchIndexPlanner.build` mints the duplicate, the checkpoint
    /// persists it, and the relaunched service reports `search_index.json corrupt:
    /// duplicateFilePaths("a.swift")` — permanently, because its rebuild mints it again.
    func testWalk_throughASymlinkedRoot_doesNotMintDuplicateRosterPaths() async throws {
        try write("real/sub/x/a.swift", "let underalias = 1")
        try write("real/sub/y/a.swift", "let alsoalias = 2")
        try fm.createSymbolicLink(
            at: tempDir.appendingPathComponent("real/mirror"),
            withDestinationURL: tempDir.appendingPathComponent("real/sub"))
        let aliasRoot = tempDir.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: aliasRoot,
                                  withDestinationURL: tempDir.appendingPathComponent("real"))
        try fm.createDirectory(
            at: aliasRoot.appendingPathComponent(".nanoteams/internal", isDirectory: true),
            withIntermediateDirectories: true)

        let service = makeService(root: aliasRoot)
        let index = await service.loadOrBuild()

        let paths = index.files.map(\.path).sorted()
        XCTAssertEqual(paths, ["mirror/x/a.swift", "mirror/y/a.swift"])
        XCTAssertEqual(Set(paths).count, index.files.count, "roster paths must be unique")
        XCTAssertNoThrow(try SearchIndex.validate(files: index.files))
        for file in index.files {
            XCTAssertTrue(
                fm.fileExists(atPath: aliasRoot.appendingPathComponent(file.path).path),
                "roster path '\(file.path)' does not open from the work folder root")
        }

        // The durable half: what the full rebuild checkpointed must still decode next launch.
        let relaunched = makeService(root: aliasRoot)
        _ = await relaunched.loadOrBuild()
        let loadError = await relaunched.lastLoadError
        XCTAssertNil(loadError, "the checkpointed index must survive a relaunch")
    }

    /// A walk warning names the link the user can act on, in the work folder's own terms.
    ///
    /// `SearchDirectoryWalker` already reports its skips as relative paths; an absolute one here
    /// cannot be joined against the roster it is about, and for a cycle it named the RESOLVED
    /// target — which is the one path in the story that is not the link you would delete.
    ///
    /// RED: report `dir.path` in the cycle arm → the warning names
    /// `/var/folders/…/UUID/nested`, so it neither identifies the link nor stays inside the
    /// work folder's vocabulary.
    func testWalkWarnings_nameRelativePathsNotAbsoluteOnes() async throws {
        try write("nested/Bar.swift", "let bar = 1")
        try fm.createSymbolicLink(
            at: tempDir.appendingPathComponent("nested/loop"),
            withDestinationURL: tempDir.appendingPathComponent("nested"))

        let service = makeService()
        _ = await service.loadOrBuild()
        let warnings = await service.lastIndexWarnings

        XCTAssertTrue(warnings.contains { $0.contains("symlink cycle") }, "got: \(warnings)")
        XCTAssertTrue(warnings.contains { $0.contains("nested/loop") }, "got: \(warnings)")
        XCTAssertFalse(warnings.contains { $0.contains(tempDir.path) },
                       "a warning must not carry the machine's directory layout: \(warnings)")
    }
}
