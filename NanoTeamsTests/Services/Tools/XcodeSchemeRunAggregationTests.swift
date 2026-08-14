import XCTest

@testable import NanoTeams

/// `XcodeBuildRunner.aggregateBuild` / `aggregateTests` — the fold that turns one
/// `xcodebuild` invocation per scheme into the envelope payload the model reads.
///
/// Coverage context (measured 2026-08-07, `coverage/files.json`):
/// `XcodeHandlers.swift` was 214 of 335 executable lines, and essentially the entire
/// 121-line gap was the two handlers' per-scheme loop bodies plus their envelope
/// assembly — code that only runs AFTER `ProcessRunner.runXcodebuild` returns, i.e.
/// after a real multi-minute build. That logic is now a pure seam on
/// `XcodeBuildRunner`, extracted for exactly the reason `parseTestOutcome` and
/// `parseIssues` were before it, and this file drives it against fixture logs.
///
/// Nothing here spawns a process.
final class XcodeSchemeRunAggregationTests: XCTestCase {

    /// The root the fixture logs' absolute paths sit under, so relativization has
    /// something real to strip. No file is created — `relativizeIssuePath` is
    /// component-wise string work over the two paths.
    private let root = URL(fileURLWithPath: "/Users/me/Proj")

    private func run(
        _ scheme: String, _ output: String, success: Bool = true, exitCode: Int = 0
    ) -> XcodeBuildRunner.SchemeRun {
        XcodeBuildRunner.SchemeRun(
            scheme: scheme, output: output, success: success, exitCode: exitCode)
    }

    // MARK: - combinedLog

    func testCombinedLog_noRuns_isEmpty() {
        XCTAssertEqual(XcodeBuildRunner.combinedLog(for: []), "")
    }

    func testCombinedLog_singleRun_isHeaderThenOutput() {
        let log = XcodeBuildRunner.combinedLog(for: [run("App", "line one\n")])

        XCTAssertEqual(log, "--- Scheme: App ---\nline one\n")
    }

    /// The blank line between schemes is what lets a reader tell two invocations apart
    /// in one blob; the FIRST header deliberately has no leading blank line.
    func testCombinedLog_twoRuns_separatesThemWithABlankLine() {
        let log = XcodeBuildRunner.combinedLog(for: [
            run("App", "a\n"), run("Framework", "b\n"),
        ])

        XCTAssertEqual(log, "--- Scheme: App ---\na\n\n\n--- Scheme: Framework ---\nb\n")
        XCTAssertFalse(log.hasPrefix("\n"), "the first header must not be pushed down")
    }

    func testCombinedLog_emptyOutput_stillEmitsTheHeader() {
        XCTAssertEqual(
            XcodeBuildRunner.combinedLog(for: [run("App", "")]),
            "--- Scheme: App ---\n",
            "a scheme that printed nothing must still be visibly accounted for")
    }

    // MARK: - aggregateBuild: counts and issue collection

    func testAggregateBuild_countsErrorsAndWarningsSeparatelyAndIgnoresNotes() throws {
        let (data, _) = XcodeBuildRunner.aggregateBuild(
            runs: [run("App", try fixture("clang_mixed.log"), success: false, exitCode: 65)],
            workFolderRoot: root, duration: 1, maxLines: 100)

        XCTAssertEqual(data.error_count, 1)
        XCTAssertEqual(data.warning_count, 1)
        XCTAssertEqual(data.issues.count, 2)
    }

    /// `note` is parsed as an issue (the model wants to see it) but counted as neither
    /// an error nor a warning — otherwise a clean build with a deprecation note would
    /// report a warning count of two.
    func testAggregateBuild_warningOnlyBuild_hasZeroErrorsAndKeepsTheNoteAsAnIssue() throws {
        let (data, _) = XcodeBuildRunner.aggregateBuild(
            runs: [run("App", try fixture("build_warnings_only.log"))],
            workFolderRoot: root, duration: 1, maxLines: 100)

        XCTAssertEqual(data.error_count, 0)
        XCTAssertEqual(data.warning_count, 1)
        XCTAssertEqual(data.issues.count, 2, "the note must survive as an issue: \(data.issues)")
        XCTAssertEqual(data.issues.map(\.severity), ["warning", "note"])
        XCTAssertTrue(data.success)
    }

    /// A build that dies before compiling anything emits no `file:line:col:` issues at
    /// all. The envelope must still report the failure — `error_count: 0` alongside
    /// `success: false` is the honest shape, and the log is the only diagnostic left.
    func testAggregateBuild_failureBeforeCompiling_hasNoIssuesButKeepsTheLog() throws {
        let output = try fixture("xcodebuild_error.log")

        let (data, _) = XcodeBuildRunner.aggregateBuild(
            runs: [run("App", output, success: false, exitCode: 66)],
            workFolderRoot: root, duration: 1, maxLines: 100)

        XCTAssertTrue(data.issues.isEmpty)
        XCTAssertEqual(data.error_count, 0)
        XCTAssertFalse(data.success)
        XCTAssertEqual(data.exit_code, 66)
        XCTAssertTrue(data.log.contains("cannot be opened"),
                      "with no parsed issues the raw log is all the model has; got: \(data.log)")
    }

    func testAggregateBuild_multipleSchemes_accumulatesIssuesFromEachInOrder() throws {
        let (data, _) = XcodeBuildRunner.aggregateBuild(
            runs: [
                run("App", try fixture("clang_mixed.log")),
                run("Framework", try fixture("swiftlint_warning.log")),
            ],
            workFolderRoot: root, duration: 2, maxLines: 100)

        XCTAssertEqual(data.issues.count, 3)
        XCTAssertEqual(data.error_count, 1)
        XCTAssertEqual(data.warning_count, 2)
        XCTAssertEqual(data.issues.last?.file, "Sources/App/Thing.swift",
                       "the second scheme's issue must be present and relativized")
    }

    func testAggregateBuild_noRuns_isASuccessfulEmptyResult() {
        let (data, truncated) = XcodeBuildRunner.aggregateBuild(
            runs: [], workFolderRoot: root, duration: 0, maxLines: 30)

        XCTAssertTrue(data.success)
        XCTAssertEqual(data.exit_code, 0)
        XCTAssertTrue(data.issues.isEmpty)
        XCTAssertEqual(data.log, "")
        XCTAssertFalse(truncated)
    }

    // MARK: - aggregateBuild: success, exit code, log withholding

    /// The log is withheld on success on purpose — a green build's output is thousands
    /// of lines the model must not pay for. It has to come back the moment it fails.
    func testAggregateBuild_logIsWithheldOnSuccessAndReturnedOnFailure() throws {
        let output = try fixture("clang_mixed.log")

        let green = XcodeBuildRunner.aggregateBuild(
            runs: [run("App", output)], workFolderRoot: root, duration: 1, maxLines: 100).data
        XCTAssertEqual(green.log, "", "a successful build must not ship its log")

        let red = XcodeBuildRunner.aggregateBuild(
            runs: [run("App", output, success: false, exitCode: 65)],
            workFolderRoot: root, duration: 1, maxLines: 100).data
        XCTAssertTrue(red.log.contains("--- Scheme: App ---"), "got: \(red.log)")
        XCTAssertTrue(red.log.contains("cannot find 'foo' in scope"), "got: \(red.log)")
    }

    /// The handler stops feeding runs after the first failure, so at most one run can
    /// be unsuccessful — `exit_code` therefore names that run.
    func testAggregateBuild_exitCodeComesFromTheFailingScheme() {
        let (data, _) = XcodeBuildRunner.aggregateBuild(
            runs: [run("App", "ok\n"), run("Framework", "bad\n", success: false, exitCode: 70)],
            workFolderRoot: root, duration: 1, maxLines: 100)

        XCTAssertEqual(data.exit_code, 70)
        XCTAssertFalse(data.success)
    }

    func testAggregateBuild_durationIsPassedThroughUntouched() {
        let (data, _) = XcodeBuildRunner.aggregateBuild(
            runs: [], workFolderRoot: root, duration: 12.5, maxLines: 30)

        XCTAssertEqual(data.duration, 12.5, accuracy: 0.0001)
    }

    // MARK: - aggregateBuild: truncation reporting (no silent caps)

    func testAggregateBuild_overTheLineCap_flagsTruncationAndKeepsTheTail() {
        let output = (1...50).map { "line \($0)" }.joined(separator: "\n")

        let (data, truncated) = XcodeBuildRunner.aggregateBuild(
            runs: [run("App", output, success: false, exitCode: 1)],
            workFolderRoot: root, duration: 1, maxLines: 5)

        XCTAssertTrue(truncated)
        XCTAssertEqual(data.log.components(separatedBy: "\n").count, 5)
        XCTAssertTrue(data.log.hasSuffix("line 50"), "the TAIL is what matters; got: \(data.log)")
    }

    /// The 5000-character cap that used to sit on top of the line cap is GONE.
    ///
    /// It only ever applied to `run_xcodebuild`, never `run_xcodetests`, and the log ships only
    /// when the build FAILED — so it truncated precisely the diagnostic the model needs, and a
    /// single long linker invocation or Swift type name pushes a real error past 5000 characters
    /// while the line cap would have kept it. One long line is ONE line: it must survive whole.
    func testAggregateBuild_oneVeryLongLine_isNotCutByAnyCharacterCap() {
        let oneHugeLine = String(repeating: "x", count: 20_000)

        let (data, truncated) = XcodeBuildRunner.aggregateBuild(
            runs: [run("App", oneHugeLine, success: false, exitCode: 1)],
            workFolderRoot: root, duration: 1, maxLines: 30)

        XCTAssertTrue(data.log.contains(oneHugeLine),
                      "the line was cut to \(data.log.count) chars; a failed build's log must arrive whole")
        XCTAssertFalse(truncated, "nothing was dropped, so nothing may be reported as dropped")
    }

    /// The line cap is still the one cap, and still reported. Removing the char cap must not
    /// have removed the honesty of the remaining one.
    func testAggregateBuild_overTheLineCap_isStillReportedAsTruncated() {
        let manyLines = (1...200).map { "line \($0)" }.joined(separator: "\n")

        let (_, truncated) = XcodeBuildRunner.aggregateBuild(
            runs: [run("App", manyLines, success: false, exitCode: 1)],
            workFolderRoot: root, duration: 1, maxLines: 30)

        XCTAssertTrue(truncated)
    }

    /// Build and test paths now cap identically — one line cap, no character cap. The asymmetry
    /// was the thing being resolved; a future edit that reintroduces it on either side breaks
    /// here rather than silently diverging again.
    func testBuildAndTestAggregation_capIdentically() {
        let oneHugeLine = String(repeating: "y", count: 20_000)

        let (build, buildTruncated) = XcodeBuildRunner.aggregateBuild(
            runs: [run("App", oneHugeLine, success: false, exitCode: 1)],
            workFolderRoot: root, duration: 1, maxLines: 30)
        let (tests, testsTruncated) = XcodeBuildRunner.aggregateTests(
            runs: [run("App", oneHugeLine, success: false, exitCode: 1)],
            workFolderRoot: root, duration: 1, maxLines: 30)

        XCTAssertEqual(build.log.count, tests.log.count)
        XCTAssertEqual(buildTruncated, testsTruncated)
    }

    // MARK: - aggregateBuild: path relativization

    /// Both directions in one run: a path under the work folder comes back relative, a
    /// path outside it comes back ABSOLUTE rather than truncated into a
    /// plausible-but-nonexistent relative one.
    func testAggregateBuild_relativizesPathsUnderTheRootAndLeavesOutsidersAbsolute() {
        let output = """
        /Users/me/Proj/Sources/App/Inside.swift:1:1: error: inside the work folder
        /Users/me/ProjSibling/Sources/App/Outside.swift:2:2: error: sibling whose name extends the root's
        /opt/homebrew/include/thing.h:3:3: warning: entirely elsewhere
        Sources/App/Already.swift:4:4: note: already relative
        """

        let (data, _) = XcodeBuildRunner.aggregateBuild(
            runs: [run("App", output, success: false, exitCode: 65)],
            workFolderRoot: root, duration: 1, maxLines: 100)

        XCTAssertEqual(data.issues.map(\.file), [
            "Sources/App/Inside.swift",
            "/Users/me/ProjSibling/Sources/App/Outside.swift",
            "/opt/homebrew/include/thing.h",
            "Sources/App/Already.swift",
        ])
    }

    /// A symlinked work-folder root is the shape `/var` → `/private/var` produces, and
    /// xcodebuild mixes the two spellings freely. Containment has to survive it, so
    /// this drives real directories rather than string literals.
    func testAggregateBuild_symlinkedRoot_stillRelativizesPathsUnderIt() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("nt_symlink_\(UUID().uuidString.prefix(8))", isDirectory: true)
        let real = base.appendingPathComponent("real", isDirectory: true)
        let link = base.appendingPathComponent("link", isDirectory: true)
        try fm.createDirectory(at: real.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? fm.removeItem(at: base) }

        // The issue names the REAL path; the work folder was opened through the LINK.
        let output = "\(real.standardizedFileURL.path)/Sources/A.swift:7:3: error: boom"

        let (data, _) = XcodeBuildRunner.aggregateBuild(
            runs: [run("App", output, success: false, exitCode: 65)],
            workFolderRoot: link, duration: 1, maxLines: 100)

        XCTAssertEqual(data.issues.first?.file, "Sources/A.swift",
                       "symlink-aware containment failed; got \(String(describing: data.issues.first?.file))")
    }

    // MARK: - aggregateBuild: malformed and hostile input

    func testAggregateBuild_emptyOutput_producesNoIssues() {
        let (data, _) = XcodeBuildRunner.aggregateBuild(
            runs: [run("App", "")], workFolderRoot: root, duration: 1, maxLines: 30)

        XCTAssertTrue(data.issues.isEmpty)
    }

    func testAggregateBuild_pureNoise_producesNoIssues() throws {
        let (data, _) = XcodeBuildRunner.aggregateBuild(
            runs: [run("App", try fixture("noise.log"), success: false, exitCode: 65)],
            workFolderRoot: root, duration: 1, maxLines: 30)

        XCTAssertTrue(data.issues.isEmpty,
                      "`note: Using new build system` has no file/line — it is not an issue")
    }

    /// A malformed issue line (severity present, line/column missing) must simply not
    /// match, rather than yielding an issue with nil coordinates the model would then
    /// try to `read_lines`.
    func testAggregateBuild_malformedIssueLines_areSkippedNotHalfParsed() {
        let output = """
        /Users/me/Proj/A.swift: error: no line or column
        /Users/me/Proj/B.swift:notanumber:1: error: line is not a number
        /Users/me/Proj/C.swift:5:9: error: well formed
        """

        let (data, _) = XcodeBuildRunner.aggregateBuild(
            runs: [run("App", output, success: false, exitCode: 65)],
            workFolderRoot: root, duration: 1, maxLines: 30)

        XCTAssertEqual(data.issues.count, 1)
        XCTAssertEqual(data.issues.first?.file, "C.swift")
        XCTAssertEqual(data.issues.first?.line, 5)
    }

    /// `ProcessRunner` hands the aggregator a `String`, so genuinely invalid bytes have
    /// already become U+FFFD by the time they arrive. Together with an embedded NUL
    /// that is the worst input this seam can actually see, and neighbouring lines must
    /// still parse.
    func testAggregateBuild_replacementCharactersAndNulBytes_doNotDerailParsing() {
        let output = "\u{FFFD}\u{0000}garbage\u{FFFD}\n"
            + "/Users/me/Proj/Good.swift:3:1: error: still found\n"
            + "\u{FFFD}\u{FFFD}\n"

        let (data, _) = XcodeBuildRunner.aggregateBuild(
            runs: [run("App", output, success: false, exitCode: 65)],
            workFolderRoot: root, duration: 1, maxLines: 30)

        XCTAssertEqual(data.issues.count, 1)
        XCTAssertEqual(data.issues.first?.file, "Good.swift")
    }

    /// A scheme name is model-supplied and lands verbatim in the header. It must not be
    /// able to forge a second header and make one invocation look like two.
    func testAggregateBuild_schemeNameContainingAHeader_isNotSplitIntoTwoSections() {
        let (data, _) = XcodeBuildRunner.aggregateBuild(
            runs: [run("A\n--- Scheme: B ---", "out\n", success: false, exitCode: 1)],
            workFolderRoot: root, duration: 1, maxLines: 30)

        XCTAssertEqual(data.log.components(separatedBy: "--- Scheme:").count - 1, 2,
                       "characterization: an embedded header IS echoed; got \(data.log)")
    }

    // MARK: - aggregateTests

    func testAggregateTests_fixtureLog_countsPassesFailuresAndRecordsEachFailure() throws {
        let (data, _) = XcodeBuildRunner.aggregateTests(
            runs: [run("App", try fixture("xcodetest_failures.log"), success: false, exitCode: 65)],
            workFolderRoot: root, duration: 3, maxLines: 100)

        XCTAssertEqual(data.passed, 1)
        XCTAssertEqual(data.failed, 2, "a skipped test counts as neither")
        XCTAssertEqual(data.failures.count, 2)
        XCTAssertEqual(data.failures.map { $0["scheme"] }, ["App", "App"])
        XCTAssertEqual(data.failures.map { $0["line"] }, ["42", "8"])
    }

    /// The failure records carry the file the way the model will hand it to `read_file`:
    /// relativized when it is under the work folder, left alone when it is already
    /// relative.
    func testAggregateTests_failureFiles_areRelativizedAndRelativeOnesLeftAlone() throws {
        let (data, _) = XcodeBuildRunner.aggregateTests(
            runs: [run("App", try fixture("xcodetest_failures.log"), success: false, exitCode: 65)],
            workFolderRoot: root, duration: 3, maxLines: 100)

        XCTAssertEqual(data.failures.map { $0["file"] }, [
            "Tests/CalculatorTests/DivisionTests.swift",
            "Tests/CalculatorTests/ParsingTests.swift",
        ])
    }

    func testAggregateTests_multipleSchemes_sumTheCountsAndTagEachFailure() throws {
        let failing = try fixture("xcodetest_failures.log")
        let green = "Test case 'A.testB()' passed on 'My Mac - App (1)' (0.001 seconds)\n"

        let (data, _) = XcodeBuildRunner.aggregateTests(
            runs: [run("App", green), run("Framework", failing, success: false, exitCode: 65)],
            workFolderRoot: root, duration: 5, maxLines: 200)

        XCTAssertEqual(data.passed, 2)
        XCTAssertEqual(data.failed, 2)
        XCTAssertEqual(Set(data.failures.compactMap { $0["scheme"] }), ["Framework"],
                       "every failure must name the scheme that produced it")
    }

    /// The two halves of `success` are independent, and each alone must sink it.
    func testAggregateTests_successRequiresBothACleanExitAndZeroFailures() throws {
        let failing = try fixture("xcodetest_failures.log")

        // Exit 0, but the log reports failures — a runner that swallowed its status.
        let exitedCleanly = XcodeBuildRunner.aggregateTests(
            runs: [run("App", failing)], workFolderRoot: root, duration: 1, maxLines: 100).data
        XCTAssertFalse(exitedCleanly.success, "parsed failures must sink a zero exit code")
        XCTAssertEqual(exitedCleanly.exit_code, 0)

        // Non-zero exit with no test having run at all — a build error before testing.
        let brokenBuild = XcodeBuildRunner.aggregateTests(
            runs: [run("App", try fixture("xcodebuild_error.log"), success: false, exitCode: 66)],
            workFolderRoot: root, duration: 1, maxLines: 100).data
        XCTAssertFalse(brokenBuild.success, "a non-zero exit must sink a zero failure count")
        XCTAssertEqual(brokenBuild.failed, 0)
        XCTAssertEqual(brokenBuild.exit_code, 66)
        XCTAssertFalse(brokenBuild.log.isEmpty,
                       "with no failure records the log is the only diagnostic")
    }

    func testAggregateTests_greenRun_withholdsTheLog() {
        let (data, _) = XcodeBuildRunner.aggregateTests(
            runs: [run("App", "Test case 'A.testB()' passed on 'My Mac - App (1)' (0.1 seconds)\n")],
            workFolderRoot: root, duration: 1, maxLines: 100)

        XCTAssertTrue(data.success)
        XCTAssertEqual(data.log, "")
        XCTAssertEqual(data.passed, 1)
    }

    func testAggregateTests_noRuns_isASuccessfulEmptyResult() {
        let (data, truncated) = XcodeBuildRunner.aggregateTests(
            runs: [], workFolderRoot: root, duration: 0, maxLines: 30)

        XCTAssertTrue(data.success)
        XCTAssertEqual(data.passed, 0)
        XCTAssertEqual(data.failed, 0)
        XCTAssertTrue(data.failures.isEmpty)
        XCTAssertEqual(data.log, "")
        XCTAssertFalse(truncated)
    }

    /// `skipped` is hardcoded to zero — `xcodebuild`'s plain-text output carries no
    /// count this parser can read, and reporting a guess would be worse. Pinned so the
    /// zero is a decision rather than a forgotten field.
    func testAggregateTests_skippedIsAlwaysZero() throws {
        let (data, _) = XcodeBuildRunner.aggregateTests(
            runs: [run("App", try fixture("xcodetest_failures.log"), success: false, exitCode: 65)],
            workFolderRoot: root, duration: 1, maxLines: 100)

        XCTAssertEqual(data.skipped, 0)
    }

    func testAggregateTests_overTheLineCap_flagsTruncation() {
        let output = (1...50).map { "noise \($0)" }.joined(separator: "\n")

        let (data, truncated) = XcodeBuildRunner.aggregateTests(
            runs: [run("App", output, success: false, exitCode: 65)],
            workFolderRoot: root, duration: 1, maxLines: 5)

        XCTAssertTrue(truncated)
        XCTAssertEqual(data.log.components(separatedBy: "\n").count, 5)
    }

    // MARK: - Envelope shape

    /// Both payloads are what `makeSuccessResult` encodes, so their key names are a wire
    /// contract with the model (and with `MemoryTagStore`, which reads them back).
    func testResultPayloads_encodeTheSnakeCaseKeysTheModelReads() throws {
        let build = XcodeBuildRunner.aggregateBuild(
            runs: [run("App", "x", success: false, exitCode: 65)],
            workFolderRoot: root, duration: 1, maxLines: 30).data
        let buildJSON = try String(decoding: JSONEncoder().encode(build), as: UTF8.self)
        for key in ["success", "exit_code", "duration", "error_count", "warning_count", "issues", "log"] {
            XCTAssertTrue(buildJSON.contains("\"\(key)\""), "BuildResult lost `\(key)`: \(buildJSON)")
        }

        let tests = XcodeBuildRunner.aggregateTests(
            runs: [run("App", "x", success: false, exitCode: 65)],
            workFolderRoot: root, duration: 1, maxLines: 30).data
        let testsJSON = try String(decoding: JSONEncoder().encode(tests), as: UTF8.self)
        for key in ["success", "exit_code", "passed", "failed", "skipped", "duration", "failures", "log"] {
            XCTAssertTrue(testsJSON.contains("\"\(key)\""), "TestResult lost `\(key)`: \(testsJSON)")
        }
    }

    // MARK: - Fixtures

    /// Fixtures are read from the source tree via `#filePath` (same mechanism as
    /// `XcodeTestOutcomeParserTests`) — they are not bundle resources.
    ///
    /// `Fixtures/XcodebuildLogs` carries BUILD output only: a sibling suite globs that
    /// whole directory and asserts every file in it parses to zero test cases, which is
    /// a useful anti-vacuity guard on the result-line pattern. `xcodebuild test` output
    /// therefore lives next door in `Fixtures/XcodetestLogs` instead of weakening it.
    private func fixture(_ name: String) throws -> String {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tools
            .deletingLastPathComponent()   // Services
            .deletingLastPathComponent()   // NanoTeamsTests
            .appendingPathComponent("Fixtures")
        let directory = name.hasPrefix("xcodetest_") ? "XcodetestLogs" : "XcodebuildLogs"
        return try String(
            contentsOf: fixtures.appendingPathComponent(directory).appendingPathComponent(name),
            encoding: .utf8)
    }
}
