import XCTest

@testable import NanoTeams

/// Every fixture here is a line CAPTURED from git 2.50.1 by building the conflict in a
/// throwaway repository, not transcribed from memory. That matters twice: the wording is
/// the whole contract, and three of the five shapes look nothing like the two that the
/// previous `range(of: "in ")` extraction was written against.
///
/// What flows through this parser is the only thing a role learns about WHERE a conflict
/// is: the conflict envelope is an `ErrorEnvelope` (`data` is `nil`) and
/// `buildToolErrorGuidance`'s default arm surfaces only `error.message`.
final class GitConflictParserTests: XCTestCase {

    // MARK: - The five shapes git emits for a two-parent merge

    /// RED: revert to `line.range(of: "in ")` → `content` and `add/add` still pass and the
    /// other three return `other and modified in HEAD…`, `HEAD, but deleted in other.`
    /// and `the way of thing from HEAD…` — a branch name, a branch name, and prose.
    func testEveryConflictKind_yieldsThePath() {
        let cases: [(line: String, expected: String)] = [
            ("CONFLICT (content): Merge conflict in f.txt", "f.txt"),
            ("CONFLICT (add/add): Merge conflict in both.txt", "both.txt"),
            (
                "CONFLICT (modify/delete): doc.txt deleted in other and modified in HEAD.  "
                    + "Version HEAD of doc.txt left in tree.",
                "doc.txt"
            ),
            (
                "CONFLICT (rename/delete): r.txt renamed to r2.txt in HEAD, but deleted in other.",
                "r.txt"
            ),
            (
                "CONFLICT (file/directory): directory in the way of thing from HEAD; "
                    + "moving it to thing~HEAD instead.",
                "thing"
            ),
        ]
        for c in cases {
            XCTAssertEqual(
                GitConflictParser.conflictedPath(inLine: c.line), c.expected,
                "shape: \(c.line)")
        }
    }

    /// rename/delete contains BOTH marker phrases. Order is load-bearing.
    ///
    /// RED: move the ` deleted in ` branch above ` renamed to ` → this yields
    /// `r.txt renamed to r2.txt in HEAD, but`.
    func testRenameDelete_isMatchedBeforeModifyDelete() {
        XCTAssertEqual(
            GitConflictParser.conflictedPath(
                inLine:
                    "CONFLICT (rename/delete): r.txt renamed to r2.txt in HEAD, but deleted in other."
            ),
            "r.txt")
    }

    // MARK: - Paths git does not quote

    /// Measured: git quotes neither a path containing spaces nor a non-ASCII one in these
    /// lines, so "the first whitespace-delimited token" — the obvious parse — truncates
    /// exactly the paths a model is least able to guess.
    ///
    /// RED: parse by tokenising on whitespace → `my file.txt` becomes `my`.
    func testPathsWithSpacesAndNonASCII_surviveWhole() {
        XCTAssertEqual(
            GitConflictParser.conflictedPath(
                inLine: "CONFLICT (content): Merge conflict in my file.txt"),
            "my file.txt")
        XCTAssertEqual(
            GitConflictParser.conflictedPath(
                inLine: "CONFLICT (content): Merge conflict in привет.txt"),
            "привет.txt")
        XCTAssertEqual(
            GitConflictParser.conflictedPath(
                inLine:
                    "CONFLICT (modify/delete): my doc.txt deleted in other and modified in HEAD."),
            "my doc.txt")
    }

    /// The `content` shape ends AT the path, so nothing may be stripped from its tail —
    /// only the prose fallback earns de-punctuation.
    ///
    /// RED: apply the sentence-punctuation strip to every branch → a file legitimately
    /// named `notes.` loses its final character and the model's `read_file` misses.
    func testTrailingPunctuation_isNotStrippedFromAParsedPath() {
        XCTAssertEqual(
            GitConflictParser.conflictedPath(inLine: "CONFLICT (content): Merge conflict in notes."),
            "notes.")
    }

    // MARK: - Shapes the parser does not know

    /// An unrecognised kind must still name something. `nil` would send the model to
    /// resolve a conflict with no location at all, which is strictly worse than prose.
    ///
    /// RED: return nil from the fallback → `conflictedPaths` drops the line and the
    /// envelope ships `conflicts: ""`.
    func testUnknownKind_fallsBackToTheMessageRatherThanNothing() {
        let path = GitConflictParser.conflictedPath(
            inLine: "CONFLICT (submodule): Failed to merge submodule vendor/lib (not checked out).")
        XCTAssertEqual(path, "Failed to merge submodule vendor/lib (not checked out)")
    }

    /// A line with no `): ` separator is not a CONFLICT line this parser can read.
    func testLineWithoutTheSeparator_isNil() {
        XCTAssertNil(GitConflictParser.conflictedPath(inLine: "Automatic merge failed"))
        XCTAssertNil(GitConflictParser.conflictedPath(inLine: ""))
    }

    // MARK: - Whole-output collection

    /// Order is git's, duplicates collapse, and non-CONFLICT lines are ignored — including
    /// the diffstat line whose filename contains the marker word, which is what made the
    /// probe-before-exit-status ordering a defect in the first place.
    ///
    /// RED: drop the `seen.insert(...).inserted` guard → `f.txt` appears twice.
    func testConflictedPaths_ordersAndDeduplicates() {
        let output = """
            Auto-merging f.txt
            CONFLICT (content): Merge conflict in f.txt
             CONFLICT.md | 1 +
            CONFLICT (add/add): Merge conflict in both.txt
            CONFLICT (content): Merge conflict in f.txt
            Automatic merge failed; fix conflicts and then commit the result.
            """

        XCTAssertEqual(GitConflictParser.conflictedPaths(in: output), ["f.txt", "both.txt"])
    }

    /// Output that mentions no conflict yields none — and callers must not read that as
    /// "no conflict", which is why the two handlers gate on the exit status first.
    func testConflictedPaths_onCleanOutput_isEmpty() {
        XCTAssertTrue(GitConflictParser.conflictedPaths(in: "Fast-forward\n 1 file changed").isEmpty)
    }

    // MARK: - Unmerged index entries

    /// `git ls-files -u` prints one line PER STAGE, so a single conflicted path appears up
    /// to three times. Captured from git 2.50.1 after an autostash-pop conflict.
    ///
    /// RED: drop the `seen.insert(...).inserted` guard -> `f.txt` is reported three times
    /// and the model is told three files need resolving.
    func testUnmergedPaths_collapseTheThreeStages() {
        let output = """
            100644 df967b96a579e45a18b8251732d16804b2e56a55 1\tf.txt
            100644 045951300cf4890e4273f294da20894d587b9ad1 2\tf.txt
            100644 40830374235df1c19661a2901b7ca73cc9499f3d 3\tf.txt
            100644 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 1\tdir/other file.txt
            """

        XCTAssertEqual(
            GitConflictParser.unmergedPaths(inLsFilesOutput: output),
            ["f.txt", "dir/other file.txt"])
    }

    /// A clean tree prints nothing, and the handlers read that as "no conflict".
    func testUnmergedPaths_onACleanIndex_isEmpty() {
        XCTAssertTrue(GitConflictParser.unmergedPaths(inLsFilesOutput: "").isEmpty)
        XCTAssertTrue(GitConflictParser.unmergedPaths(inLsFilesOutput: "\n\n").isEmpty)
    }

    /// A `file/directory` message with no ` from ` clause — the shape git prints when the
    /// conflicting side is not named. The path still has to come back, so the branch falls
    /// through to the rest of the message with its sentence punctuation removed.
    ///
    /// RED: return `trim(rest)` instead of `strippingSentencePunctuation(rest)` -> the
    /// trailing period rides along and `read_file` misses.
    func testFileDirectory_withoutTheFromClause_stillYieldsThePath() {
        XCTAssertEqual(
            GitConflictParser.conflictedPath(
                inLine: "CONFLICT (file/directory): directory in the way of thing."),
            "thing")
    }
}
