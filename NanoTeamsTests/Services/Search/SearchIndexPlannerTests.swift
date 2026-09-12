import XCTest
@testable import NanoTeams

/// The decisions "only new and changed files" rests on, tested as values.
///
/// No temp directory anywhere in this file, which is the point: the cases that matter — an
/// in-place edit of the same size, a rename that preserves mTime, a cancelled pass, the churn
/// budget crossing its threshold — are all expressible as inputs, and arranging them on a real
/// file system is either slow, flaky, or impossible.
final class SearchIndexPlannerTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func candidate(
        _ path: String, mTime: Date? = nil, size: Int64 = 100, rtfd: Bool = false
    ) -> SearchIndexPlanner.IndexCandidate {
        SearchIndexPlanner.IndexCandidate(
            url: URL(fileURLWithPath: "/w/" + path),
            relativePath: path,
            isRTFDBundle: rtfd,
            mTime: mTime ?? epoch,
            size: size)
    }

    private func base(
        _ files: [IndexedFile], vocabulary: Set<String> = ["old"], churn: Int = 0
    ) -> SearchIndex {
        SearchIndex(
            generatedAt: epoch, files: files, vocabulary: vocabulary,
            changedSinceFullBuild: churn)
    }

    private func row(_ path: String, mTime: Date? = nil, size: Int64 = 100) -> IndexedFile {
        IndexedFile(path: path, mTime: mTime ?? epoch, size: size)
    }

    // MARK: - plan

    func testPlan_noBase_isAFullRebuild() {
        XCTAssertEqual(
            SearchIndexPlanner.plan(candidates: [candidate("A.swift")], base: nil),
            .fullRebuild)
    }

    func testPlan_nothingMoved_isReuse() {
        let plan = SearchIndexPlanner.plan(
            candidates: [candidate("A.swift"), candidate("B.swift")],
            base: base([row("A.swift"), row("B.swift")]))
        XCTAssertEqual(plan, .reuse)
    }

    func testPlan_newFile_isDirty() {
        let plan = SearchIndexPlanner.plan(
            candidates: [candidate("A.swift"), candidate("B.swift")],
            base: base([row("A.swift")]))
        XCTAssertEqual(
            plan, .incremental(.init(dirty: [1], added: 1, changed: 0, deleted: 0)))
    }

    /// Д3, half one: an edit that leaves the file the same SIZE.
    ///
    /// The aggregate `IndexSignature` cannot see this — `fileCount` and `totalSize` are
    /// unchanged, and `maxMTime` only moves if this happened to be the newest file. The
    /// per-file diff sees it because it compares per file.
    ///
    /// RED: compare `base.signature` against a freshly folded one instead → `.reuse`, and the
    /// edit is invisible until something else in the tree changes.
    func testPlan_inPlaceEditOfTheSameSize_isDirty() {
        // A second, NEWER file keeps `maxMTime` pinned, so the aggregate signature of this
        // tree is identical before and after the edit — which is exactly the blind spot.
        let previous = base([
            row("A.swift"),
            row("Newest.swift", mTime: epoch.addingTimeInterval(3600)),
        ])
        let plan = SearchIndexPlanner.plan(
            candidates: [
                candidate("A.swift", mTime: epoch.addingTimeInterval(60)),
                candidate("Newest.swift", mTime: epoch.addingTimeInterval(3600)),
            ],
            base: previous)
        XCTAssertEqual(previous.signature.fileCount, 2)
        XCTAssertEqual(
            plan, .incremental(.init(dirty: [0], added: 0, changed: 1, deleted: 0)))
    }

    /// Д3, half two: `mv a.txt b.txt` — the mTime does not move, the size does not change, and
    /// the file count is identical. One added, one deleted, and the aggregate signature is
    /// byte-for-byte the same.
    func testPlan_renamePreservingMTime_isDirtyOnBothSides() {
        // A roster of 20 so the rename (one added + one deleted = 2 touched) stays under the
        // churn budget and the DETECTION is what is observed, not the budget.
        var roster = (0..<19).map { row("keep\($0).swift") }
        roster.append(row("a.txt"))
        var candidates = (0..<19).map { candidate("keep\($0).swift") }
        candidates.append(candidate("b.txt"))

        XCTAssertEqual(
            SearchIndexPlanner.plan(candidates: candidates, base: base(roster)),
            .incremental(.init(dirty: [19], added: 1, changed: 0, deleted: 1)))
    }

    /// An `.rtfd` is a DIRECTORY that is a document: editing the text inside it does not move
    /// the bundle's own mTime, so it can never be proven clean.
    func testPlan_rtfdBundle_isAlwaysDirty() {
        let plan = SearchIndexPlanner.plan(
            candidates: [candidate("Notes.rtfd", rtfd: true)],
            base: base([row("Notes.rtfd")]))
        XCTAssertEqual(
            plan, .incremental(.init(dirty: [0], added: 0, changed: 1, deleted: 0)))
    }

    /// Deletions need no content pass at all: the roster shrinks and the vocabulary is
    /// unchanged (its dead words wait for the next full rebuild).
    func testPlan_deletionOnly_isAnIncrementalWithNoDirtyFiles() {
        let plan = SearchIndexPlanner.plan(
            candidates: [candidate("A.swift")],
            base: base([row("A.swift"), row("B.swift")]))
        XCTAssertEqual(
            plan, .incremental(.init(dirty: [], added: 0, changed: 0, deleted: 1)))
    }

    // MARK: - The churn budget

    /// One cumulative budget, not a per-run one: ten runs of one file each must eventually
    /// force a full rebuild, or an incremental vocabulary drifts forever.
    ///
    /// RED: compare `touched` alone against the budget instead of
    /// `base.changedSinceFullBuild + touched` → a folder edited one file at a time never
    /// rebuilds, and the words of every deleted file live on.
    func testPlan_churnAccumulatesAcrossRuns_andEventuallyForcesAFullRebuild() {
        // Roster of 8 → budget ⌈0.25 × 8⌉ = 2.
        let roster = (0..<8).map { row("f\($0).swift") }
        var candidates = (0..<8).map { candidate("f\($0).swift") }
        candidates[0] = candidate("f0.swift", mTime: epoch.addingTimeInterval(1))

        // Two already spent + one now = 3 > 2.
        XCTAssertEqual(
            SearchIndexPlanner.plan(candidates: candidates, base: base(roster, churn: 2)),
            .fullRebuild)
        // One already spent + one now = 2, which is not YET over.
        XCTAssertEqual(
            SearchIndexPlanner.plan(candidates: candidates, base: base(roster, churn: 1)),
            .incremental(.init(dirty: [0], added: 0, changed: 1, deleted: 0)))
    }

    /// A tiny roster must not livelock: the budget rounds UP, so one file out of four is still
    /// an increment, and the full rebuild that eventually fires resets the counter to zero.
    func testPlan_tinyRoster_doesNotRebuildOnEveryEdit() {
        let roster = (0..<4).map { row("f\($0).swift") }
        var candidates = (0..<4).map { candidate("f\($0).swift") }
        candidates[0] = candidate("f0.swift", mTime: epoch.addingTimeInterval(1))
        XCTAssertEqual(
            SearchIndexPlanner.plan(candidates: candidates, base: base(roster, churn: 0)),
            .incremental(.init(dirty: [0], added: 0, changed: 1, deleted: 0)))
    }

    /// An empty folder with an empty base is `.reuse`, not a full rebuild on every call — the
    /// budget for a zero-file roster is zero, and `touched == 0` must be decided first.
    func testPlan_emptyFolderWithEmptyBase_isReuse() {
        XCTAssertEqual(SearchIndexPlanner.plan(candidates: [], base: base([])), .reuse)
    }

    // MARK: - merge

    func testMerge_unionsTheWordsOfDirtyFilesOnly() {
        let candidates = [candidate("A.swift"), candidate("B.swift", mTime: epoch.addingTimeInterval(9))]
        let diff = SearchIndexPlanner.Diff(dirty: [1], added: 0, changed: 1, deleted: 0)
        let merged = SearchIndexPlanner.merge(
            base: base([row("A.swift"), row("B.swift")], vocabulary: ["alpha", "stale"]),
            candidates: candidates, diff: diff,
            passes: [.indexed(["beta"])],
            generatedAt: epoch.addingTimeInterval(100))

        XCTAssertEqual(merged.vocabulary, ["alpha", "stale", "beta"],
                       "union, never subtraction — a word the incremental pass cannot prove "
                           + "gone stays until the next full rebuild")
        XCTAssertEqual(merged.files.map(\.path), ["A.swift", "B.swift"])
        XCTAssertEqual(merged.files[1].mTime, epoch.addingTimeInterval(9),
                       "the file that was read gets its NEW stamp")
        XCTAssertEqual(merged.changedSinceFullBuild, 1)
    }

    /// Д1: a pass that did not run must leave the OLD roster row in place, so the file stays
    /// dirty and the next run finishes the job. Stamping it would freeze it clean forever with
    /// none of its words in the vocabulary.
    ///
    /// RED: append a fresh `IndexedFile` in the `.cancelled` / `.unreadable` arms → the mTime
    /// assertion fails, and in production that file's content becomes unreachable.
    func testMerge_passThatDidNotRun_keepsTheOldRosterRow() {
        let candidates = [candidate("A.swift", mTime: epoch.addingTimeInterval(50))]
        let diff = SearchIndexPlanner.Diff(dirty: [0], added: 0, changed: 1, deleted: 0)
        for pass in [SearchIndexPlanner.IndexFilePass.cancelled,
                     .unreadable(warning: "nope")] {
            let merged = SearchIndexPlanner.merge(
                base: base([row("A.swift")], vocabulary: ["alpha"]),
                candidates: candidates, diff: diff, passes: [pass],
                generatedAt: epoch.addingTimeInterval(100))
            XCTAssertEqual(merged.files.map(\.mTime), [epoch],
                           "\(pass): the row must still say what was actually read")
            XCTAssertEqual(merged.vocabulary, ["alpha"])
        }
    }

    /// A brand-new file whose pass did not run gets no row at all — there is no old row to
    /// keep, and inventing one would be the same freeze by another route.
    func testMerge_newFileWhosePassDidNotRun_isNotStamped() {
        let candidates = [candidate("A.swift"), candidate("New.swift")]
        let diff = SearchIndexPlanner.Diff(dirty: [1], added: 1, changed: 0, deleted: 0)
        let merged = SearchIndexPlanner.merge(
            base: base([row("A.swift")], vocabulary: ["alpha"]),
            candidates: candidates, diff: diff, passes: [.cancelled],
            generatedAt: epoch.addingTimeInterval(100))
        XCTAssertEqual(merged.files.map(\.path), ["A.swift"])
    }

    func testMerge_deletedFile_leavesTheRoster() {
        let merged = SearchIndexPlanner.merge(
            base: base([row("A.swift"), row("B.swift")], vocabulary: ["alpha", "beta"]),
            candidates: [candidate("A.swift")],
            diff: .init(dirty: [], added: 0, changed: 0, deleted: 1),
            passes: [], generatedAt: epoch.addingTimeInterval(100))
        XCTAssertEqual(merged.files.map(\.path), ["A.swift"])
        XCTAssertEqual(merged.vocabulary, ["alpha", "beta"],
                       "its words linger until a full rebuild — that is what the budget bounds")
        XCTAssertEqual(merged.changedSinceFullBuild, 1)
    }

    // MARK: - build

    func testBuild_countsDocumentFrequencyAndResetsTheBudget() {
        let candidates = (0..<30).map { candidate("f\($0).swift") }
        // "shared" in two files, "lonely" in one.
        var passes = [SearchIndexPlanner.IndexFilePass](
            repeating: .indexed([]), count: candidates.count)
        passes[0] = .indexed(["shared", "lonely"])
        passes[1] = .indexed(["shared"])

        let built = SearchIndexPlanner.build(
            candidates: candidates, passes: passes, filter: .default,
            generatedAt: epoch.addingTimeInterval(100))

        XCTAssertEqual(built?.vocabulary, ["shared"],
                       "the singleton is dropped on a corpus this size")
        XCTAssertEqual(built?.changedSinceFullBuild, 0)
        XCTAssertEqual(built?.files.count, 30)
    }

    /// Atomic: one cancelled pass and the whole build is refused. A document-frequency filter
    /// over a subset of the tree would drop shared words as singletons, so a partial full build
    /// is worse than none.
    ///
    /// RED: skip `.cancelled` the way `.unreadable` is skipped → a half-walked tree produces a
    /// vocabulary missing most of its real words, and it is CHECKPOINTED to disk.
    func testBuild_anyCancelledPass_refusesTheWholeBuild() {
        let candidates = [candidate("A.swift"), candidate("B.swift")]
        XCTAssertNil(SearchIndexPlanner.build(
            candidates: candidates, passes: [.indexed(["alpha"]), .cancelled],
            filter: .default, generatedAt: epoch))
    }

    /// An UNREADABLE file is not that: it is a fact about one file, so the build succeeds
    /// without it. Otherwise a single `chmod 0o000` anywhere in the tree would make a full
    /// rebuild impossible — including the very first one, which has no base to fall back to.
    func testBuild_unreadableFile_isSkippedAndTheBuildStands() {
        let candidates = [candidate("A.swift"), candidate("locked.swift")]
        let built = SearchIndexPlanner.build(
            candidates: candidates,
            passes: [.indexed(["alpha"]), .unreadable(warning: "denied")],
            filter: .default, generatedAt: epoch)
        XCTAssertEqual(built?.files.map(\.path), ["A.swift"])
        XCTAssertEqual(built?.vocabulary, ["alpha"], "tiny corpus — the filter accepts singletons")
    }

    func testBuild_passCountDisagreesWithCandidates_refuses() {
        XCTAssertNil(SearchIndexPlanner.build(
            candidates: [candidate("A.swift"), candidate("B.swift")],
            passes: [.indexed(["alpha"])], filter: .default, generatedAt: epoch))
    }

    // MARK: - VocabularyFilter

    /// Below the skip threshold every rule is statistically meaningless — on four files every
    /// word appears in exactly one — so the filter accepts everything. Without this a small
    /// project would have an EMPTY vocabulary and no query expansion at all.
    func testFilter_belowSkipThreshold_acceptsSingletons() {
        let filter = SearchIndexPlanner.VocabularyFilter.default
        XCTAssertTrue(filter.accepts(fileCount: 1, rosterCount: 4))
        XCTAssertTrue(filter.accepts(
            fileCount: 1, rosterCount: filter.nearUniversalSkipBelowFileCount))
    }

    func testFilter_aboveSkipThreshold_dropsSingletonsAndStopwords() {
        let filter = SearchIndexPlanner.VocabularyFilter.default
        XCTAssertFalse(filter.accepts(fileCount: 1, rosterCount: 100),
                       "one file out of a hundred is a hash or a typo")
        XCTAssertFalse(filter.accepts(fileCount: 95, rosterCount: 100),
                       "95% of files is a stopword — `func`, `import`, `the`")
        XCTAssertTrue(filter.accepts(fileCount: 10, rosterCount: 100))
        // Exactly at the ratio is kept: the rule is "more than", not "at least".
        XCTAssertTrue(filter.accepts(fileCount: 80, rosterCount: 100))
    }

    // MARK: - The roster invariant, on the producing side

    /// `SearchIndex.init(from:)` has always rejected a duplicate `path` on DECODE, and `build`
    /// and `merge` — the only two producers of `SearchIndex.files` — never checked it. That
    /// asymmetry is what turns a walk bug from transient into permanent: a full rebuild
    /// checkpoints itself, the next launch decodes the file into `duplicateFilePaths`, calls it
    /// corrupt, and rebuilds from the same tree into the same duplicate. There is no exit.
    ///
    /// FIRST occurrence wins — the same tie-break `plan` and `merge` already apply to the base
    /// roster with `uniquingKeysWith: { first, _ in first }`, so the roster and the diff cannot
    /// disagree about which row a repeated path means.
    ///
    /// RED: return `candidates` unchanged → `build` mints two rows for `x/a.swift`, and
    /// `SearchIndex.validate` throws on the very value the service is about to checkpoint.
    func testDeduplicated_dropsALaterRepeatOfAPathAndNamesIt() {
        let result = SearchIndexPlanner.deduplicated([
            candidate("x/a.swift"),
            candidate("y/a.swift", size: 7),
            candidate("x/a.swift", size: 9),
        ])

        XCTAssertEqual(result.candidates.map(\.relativePath), ["x/a.swift", "y/a.swift"])
        XCTAssertEqual(result.candidates.first?.size, 100, "first occurrence wins")
        XCTAssertEqual(result.droppedPaths, ["x/a.swift"])
        XCTAssertEqual(
            result.warnings,
            ["index roster: 1 duplicate path(s) dropped — x/a.swift"],
            "and it reaches `lastIndexWarnings`, because a walk that mints a duplicate is a "
                + "defect the settings card should name rather than absorb")
    }

    /// A healthy walk is the overwhelmingly common case, and it must come back untouched — not
    /// merely equal, but in the same ORDER.
    ///
    /// RED: dedup by pushing through a `Set` or `Dictionary` and rebuilding the array from it →
    /// the order becomes hash order, and since `Diff.dirty` holds INDICES into this array that
    /// `merge` zips against `passes`, every pass is then folded into the wrong file.
    func testDeduplicated_preservesWalkOrder() {
        let input = [candidate("z.swift"), candidate("a.swift"), candidate("m/b.swift")]

        let result = SearchIndexPlanner.deduplicated(input)

        XCTAssertEqual(result.candidates, input)
        XCTAssertTrue(result.droppedPaths.isEmpty)
        XCTAssertTrue(result.warnings.isEmpty, "a healthy walk says nothing")
    }
}
