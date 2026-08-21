import XCTest

@testable import NanoTeams

/// `XcodeBuildRunner.parseTestOutcome` — the half of `run_xcodetests` that reads
/// xcodebuild's output.
///
/// It was inline in `RunXcodetestsTool.handle`, wrapped around
/// `ProcessRunner.runXcodebuild`, which spawns a real multi-minute build — so 194
/// lines of `XcodeHandlers` were structurally unreachable from a test process. The
/// extraction mirrors `parseIssues`, which lives beside it for the same reason.
///
/// Every result-line shape below is VERBATIM from a real run (Xcode 26.3, this
/// repository), not recalled — that is the whole point of the case-sensitivity bug
/// this suite pins.
final class XcodeTestOutcomeParserTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/Users/dev/Proj").standardizedFileURL

    private func parse(_ output: String, scheme: String = "App") -> XcodeBuildRunner.TestOutcome {
        XcodeBuildRunner.parseTestOutcome(output: output, scheme: scheme, workFolderRoot: root)
    }

    // MARK: - Result-line counting

    /// THE regression. Xcode 26 prints a lowercase `Test case`; the pattern was
    /// `#"Test Case .+ passed"#`, so on the current toolchain it matched nothing and
    /// `run_xcodetests` reported `passed: 0, failed: 0` for every run — a green suite
    /// and a red one produced identical counts.
    func testCurrentXcodeLowercaseSpelling_isCounted() {
        let output = """
        Test case 'GitHandlerTailTests.testGitStash_unknownAction()' passed on 'My Mac - NanoTeams (54350)' (0.450 seconds)
        Test case 'GitHandlerTailTests.testGitStatus_unbornRepo()' passed on 'My Mac - NanoTeams (54350)' (1.002 seconds)
        Test case 'GitHandlerTailTests.testBroken()' failed on 'My Mac - NanoTeams (54350)' (0.113 seconds)
        """

        let outcome = parse(output)

        XCTAssertEqual(outcome.passed, 2, "lowercase `Test case` is what Xcode 26 emits")
        XCTAssertEqual(outcome.failed, 1)
    }

    /// The older bracketed spelling must keep working — the fix widens, it does not swap.
    func testLegacyBracketedSpelling_isStillCounted() {
        let output = """
        Test Case '-[NanoTeamsTests.FooTests testA]' passed (0.001 seconds)
        Test Case '-[NanoTeamsTests.FooTests testB]' failed (0.004 seconds)
        """

        let outcome = parse(output)

        XCTAssertEqual(outcome.passed, 1)
        XCTAssertEqual(outcome.failed, 1)
    }

    /// A skipped test is neither passed nor failed. `XCTSkip` is used deliberately in
    /// this project (LLM-dependent suites, Keychain opt-in), so counting one as a pass
    /// would overstate green.
    func testSkippedTests_countAsNeither() {
        let output = """
        Test case 'FooTests.testA()' passed on 'My Mac' (0.1 seconds)
        Test case 'FooTests.testB()' skipped on 'My Mac' (0.0 seconds)
        """

        let outcome = parse(output)

        XCTAssertEqual(outcome.passed, 1)
        XCTAssertEqual(outcome.failed, 0)
    }

    /// Serial runs print `Test Suite 'X' passed`. Counting suite lines would inflate
    /// the totals by roughly the number of classes.
    func testSuiteLines_areNotCountedAsTests() {
        let output = """
        Test Suite 'FooTests' passed at 2026-08-08 00:00:00.000.
        Test Suite 'All tests' failed at 2026-08-08 00:00:01.000.
        Test case 'FooTests.testA()' passed on 'My Mac' (0.1 seconds)
        """

        let outcome = parse(output)

        XCTAssertEqual(outcome.passed, 1, "only per-CASE lines count: \(outcome)")
        XCTAssertEqual(outcome.failed, 0)
    }

    func testNoTestLines_isZeroZeroRatherThanAFailure() {
        XCTAssertEqual(parse("** BUILD SUCCEEDED **"), .empty)
        XCTAssertEqual(parse(""), .empty)
    }

    // MARK: - Failure records

    func testFailure_carriesSchemeFileLineAndMessage() {
        let output = "/Users/dev/Proj/Sources/A.swift:42: error: XCTAssertEqual failed: 1 != 2"

        let outcome = parse(output, scheme: "MyScheme")

        XCTAssertEqual(outcome.failures.count, 1)
        let failure = outcome.failures[0]
        XCTAssertEqual(failure["scheme"], "MyScheme")
        XCTAssertEqual(failure["file"], "Sources/A.swift",
                       "the path must be work-folder relative so read_file can take it verbatim")
        XCTAssertEqual(failure["line"], "42")
        XCTAssertTrue(failure["message"]?.contains("1 != 2") ?? false, "got: \(failure)")
    }

    /// `line` is a STRING all the way to the model — `MemoryTagStore` reads it back
    /// from JSON, and a reader that expects `Int` silently drops it.
    func testFailureLine_isAString() {
        let outcome = parse("/Users/dev/Proj/A.swift:7: error: boom")
        XCTAssertEqual(outcome.failures.first?["line"], "7")
    }

    /// A file outside the work folder keeps its ABSOLUTE path. Truncating it would
    /// fabricate a plausible-but-nonexistent relative path and hide that the failure
    /// came from somewhere else entirely.
    func testFailureOutsideTheWorkFolder_keepsItsAbsolutePath() {
        let outcome = parse("/opt/vendor/Lib.swift:3: error: boom")
        XCTAssertEqual(outcome.failures.first?["file"], "/opt/vendor/Lib.swift")
    }

    func testMultipleFailures_areAllCollectedInOrder() {
        let output = """
        /Users/dev/Proj/A.swift:1: error: first
        /Users/dev/Proj/B.swift:2: error: second
        """

        let outcome = parse(output)

        XCTAssertEqual(outcome.failures.map { $0["file"] }, ["A.swift", "B.swift"])
        XCTAssertEqual(outcome.failures.map { $0["message"] }, ["first", "second"])
    }

    /// Warnings are not failures. The pattern requires the literal `error:`, and this
    /// pins that a noisy build log doesn't manufacture failure records.
    func testWarnings_produceNoFailureRecords() {
        let output = """
        /Users/dev/Proj/A.swift:9: warning: unused variable 'x'
        /Users/dev/Proj/A.swift:9: note: did you mean
        """

        XCTAssertTrue(parse(output).failures.isEmpty, "only `error:` lines are failures")
    }

    // MARK: - Real fixture logs

    /// The seven checked-in xcodebuild logs are BUILD output, so a test parse of them
    /// must report no tests. Chiefly an anti-vacuity guard on the counter: a pattern
    /// loose enough to match ordinary build noise would show up here.
    func testCheckedInBuildLogs_reportNoTests() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tools
            .deletingLastPathComponent()   // Services
            .deletingLastPathComponent()   // NanoTeamsTests
            .appendingPathComponent("Fixtures/XcodebuildLogs")
        // The public CI mirror carries build sources only, so a .log fixture can be
        // absent there — skip rather than fail, per the rule in CLAUDE.md (2026-07-27).
        guard let logs = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter({ $0.hasSuffix(".log") }), !logs.isEmpty else {
            throw XCTSkip("fixture logs not present in this checkout (\(dir.path))")
        }
        XCTAssertGreaterThanOrEqual(logs.count, 5, "expected the checked-in fixture logs")

        for name in logs {
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            let outcome = parse(text)
            XCTAssertEqual(outcome.passed, 0, "\(name) is a BUILD log — no test cases in it")
            XCTAssertEqual(outcome.failed, 0, "\(name)")
        }
    }
}
