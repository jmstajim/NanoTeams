import XCTest

@testable import NanoTeams

// MARK: - File-private support

private enum MTSPFailure: Error {
    /// Thrown after an `XCTFail` so the calling test can bail without force-unwrapping.
    case unexpectedResult
}

/// A processor that supports exactly one made-up tool. Exists to drive
/// `MemoryTagStore.processToolResult`'s DIP seam (injected `processors`) —
/// the production default list can only exercise the "some processor claims
/// this tool" half of the dispatch loop.
private struct MTSPStubProcessor: ToolResultProcessor {
    let supportedTools: Set<String> = ["mtsp_stub_tool"]

    func process(
        _ result: ToolExecutionResult, store: MemoryTagStore
    ) -> TagProcessingResult {
        .tagged(content: "stub:\(result.toolName)", tag: store.nextTag(.read))
    }
}

/// Corner coverage for the `MemoryTagStore` build/test/git/JSON layers.
///
/// `MemoryTagStoreTests` pins the per-tool tagging happy paths and the
/// anti-dedup contract. This suite targets what that suite leaves untouched:
/// the summary extractors (driven by the REAL xcodebuild fixtures under
/// `NanoTeamsTests/Fixtures/XcodebuildLogs/`), every `.passthrough` guard arm,
/// the `prefix(...)` caps, and the JSON helpers' malformed-input behaviour.
final class MemoryTagStoreProcessingTests: XCTestCase {

    var sut: MemoryTagStore!

    override func setUp() {
        super.setUp()
        sut = MemoryTagStore()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Real xcodebuild fixtures → parseIssues → envelope → extractBuildSummary
    //
    // The fixtures are raw xcodebuild output. Production turns them into the
    // `issues` array via `XcodeBuildRunner.parseIssues`, wraps that in a
    // `BuildResult` envelope, and only then does `extractBuildSummary` see it.
    // Driving that whole chain is what makes these assertions meaningful —
    // a hand-written `issues` array would only be testing my own transcription.

    /// `clang_mixed.log` carries one error and one warning. Both must reach the
    /// summary, with the `[E]` / `[W]` discriminator derived from `severity`.
    func testExtractBuildSummary_realClangMixedFixture_carriesBothSeverities() throws {
        let issues = try issuesFromFixture("clang_mixed")
        XCTAssertEqual(issues.count, 2, "fixture should parse into exactly two issues")

        let summary = sut.extractBuildSummary(from: buildEnvelope(from: issues, success: false))

        XCTAssertTrue(summary.hasPrefix("BUILD FAILED: 1 error(s), 1 warning(s)"),
                      "header must count severities separately; got: \(summary)")
        XCTAssertTrue(summary.contains("[E] cannot find 'foo' in scope"),
                      "error message missing from summary: \(summary)")
        XCTAssertTrue(summary.contains("[W] initialization of immutable value 'x'"),
                      "warning message missing from summary: \(summary)")
        // Path form depends on relativization (pinned separately by
        // XcodeIssuePathRelativizationTests); the line suffix is what this asserts.
        XCTAssertTrue(summary.contains("main.swift:12"), "error location missing: \(summary)")
        XCTAssertTrue(summary.contains("Util.swift:9"), "warning location missing: \(summary)")
    }

    /// `swiftlint_warning.log` parses to a single warning. With `success: true`
    /// that is the "succeeded but noisy" shape, which gets its own header.
    func testExtractBuildSummary_realWarningOnlyFixture_reportsSuccessWithWarningCount() throws {
        let issues = try issuesFromFixture("swiftlint_warning")
        XCTAssertEqual(issues.count, 1)

        let summary = sut.extractBuildSummary(from: buildEnvelope(from: issues, success: true))

        XCTAssertEqual(summary, "BUILD SUCCESS: 1 warning(s)",
                       "a successful build lists no issue lines, only the warning count")
    }

    /// A dependency warning from `.build/checkouts` is still a warning — the
    /// summary must not silently drop issues whose path is outside the source tree.
    func testExtractBuildSummary_realSwiftPMFixture_countsDependencyWarning() throws {
        let issues = try issuesFromFixture("swiftpm_warning")
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.severity, "warning")

        let summary = sut.extractBuildSummary(from: buildEnvelope(from: issues, success: true))
        XCTAssertEqual(summary, "BUILD SUCCESS: 1 warning(s)")
    }

    /// Four real logs describe a genuinely failing build that the issue regex
    /// cannot parse (linker errors, an unopenable project, `(at: file:line:col)`
    /// trailing-location form, pure noise). The summary must still say FAILED —
    /// a zero-issue parse must never be reported as a success.
    func testExtractBuildSummary_realUnparseableFailureFixtures_stillReportFailed() throws {
        for name in ["linker_duplicate_symbol", "noise", "swift_error_at", "xcodebuild_error"] {
            let issues = try issuesFromFixture(name)
            XCTAssertEqual(issues.count, 0, "\(name): the issue regex is not expected to match")

            let summary = sut.extractBuildSummary(from: buildEnvelope(from: issues, success: false))
            XCTAssertEqual(summary, "BUILD FAILED: 0 error(s), 0 warning(s)",
                           "\(name) must not read as a success")
        }
    }

    // MARK: - processBuild / processTests

    func testProcessBuild_errorResult_isPassthrough() {
        let result = ToolExecutionResult(
            toolName: ToolNames.runXcodebuild, argumentsJSON: "{}",
            outputJSON: makeErrorEnvelope(code: .commandFailed, message: "xcodebuild missing"),
            isError: true)
        guard case .passthrough = sut.processToolResult(result) else {
            return XCTFail("a failed build tool call must pass through")
        }
    }

    /// Every build — including a repeat of an identical one — carries its own
    /// full summary under a fresh tag. Driven through a REAL fixture so the
    /// summary content is the production shape, not a transcription.
    func testProcessBuild_everyRun_emitsItsOwnFullSummary() throws {
        let envelope = buildEnvelope(from: try issuesFromFixture("clang_mixed"), success: false)

        let (first, firstTag) = try tagged(sut.processToolResult(buildResult(envelope: envelope)))
        let (second, secondTag) = try tagged(sut.processToolResult(buildResult(envelope: envelope)))

        XCTAssertEqual(firstTag, "<§B1§>")
        XCTAssertEqual(secondTag, "<§B2§>")
        for content in [first, second] {
            let obj = try jsonObject(content)
            let summary = try XCTUnwrap(obj["summary"] as? String)
            XCTAssertTrue(summary.contains("[E] cannot find 'foo' in scope"), summary)
        }
    }

    func testProcessTests_errorResult_isPassthrough() {
        let result = ToolExecutionResult(
            toolName: ToolNames.runXcodetests, argumentsJSON: "{}",
            outputJSON: makeErrorEnvelope(code: .commandFailed, message: "no scheme"),
            isError: true)
        guard case .passthrough = sut.processToolResult(result) else {
            return XCTFail("a failed test tool call must pass through")
        }
    }

    func testProcessTests_emitsTaggedSummary() throws {
        let (content, tag) = try tagged(
            sut.processToolResult(makeTestRunResult(passed: 3, failed: 1)))

        XCTAssertEqual(tag, "<§B1§>", "tests share the B tag type")
        let summary = try XCTUnwrap(try jsonObject(content)["summary"] as? String)
        XCTAssertTrue(summary.hasPrefix("TESTS FAILED: 3 passed, 1 failed"), summary)
    }

    // MARK: - extractBuildSummary corners

    func testExtractBuildSummary_malformedJSON_returnsUnknown() {
        XCTAssertEqual(sut.extractBuildSummary(from: "not json at all"), "BUILD UNKNOWN")
        XCTAssertEqual(sut.extractBuildSummary(from: ""), "BUILD UNKNOWN")
        XCTAssertEqual(sut.extractBuildSummary(from: "{\"ok\":true"), "BUILD UNKNOWN")
    }

    func testExtractBuildSummary_missingOrWrongTypedDataObject_returnsUnknown() {
        XCTAssertEqual(sut.extractBuildSummary(from: "{\"ok\":true}"), "BUILD UNKNOWN")
        XCTAssertEqual(sut.extractBuildSummary(from: "{\"ok\":true,\"data\":\"oops\"}"), "BUILD UNKNOWN")
        XCTAssertEqual(sut.extractBuildSummary(from: "{\"ok\":true,\"data\":[1,2]}"), "BUILD UNKNOWN")
        XCTAssertEqual(sut.extractBuildSummary(from: "{\"ok\":true,\"data\":null}"), "BUILD UNKNOWN")
    }

    /// A JSON array is valid JSON but not an envelope; `parseJSON`'s cast must
    /// reject it rather than crashing or half-reading it.
    func testExtractBuildSummary_topLevelArray_returnsUnknown() {
        XCTAssertEqual(sut.extractBuildSummary(from: "[{\"data\":{}}]"), "BUILD UNKNOWN")
    }

    func testExtractBuildSummary_cleanSuccess_hasNoWarningSuffix() {
        XCTAssertEqual(
            sut.extractBuildSummary(from: buildEnvelope(from: [], success: true)),
            "BUILD SUCCESS")
    }

    /// `success && errorCount == 0` is the gate: a server claiming success while
    /// still reporting errors must NOT be summarised as a success.
    func testExtractBuildSummary_successFlagWithErrorCount_reportsFailed() {
        let envelope = buildEnvelope(from: [], success: true, errorOverride: 3)
        XCTAssertTrue(sut.extractBuildSummary(from: envelope).hasPrefix("BUILD FAILED: 3 error(s)"))
    }

    /// An entirely absent `success`/`error_count`/`warning_count` trio defaults to
    /// a failed build with zero counts — the conservative direction.
    func testExtractBuildSummary_dataWithNoKnownKeys_reportsZeroedFailure() {
        XCTAssertEqual(
            sut.extractBuildSummary(from: "{\"ok\":true,\"data\":{\"unrelated\":1}}"),
            "BUILD FAILED: 0 error(s), 0 warning(s)")
    }

    func testExtractBuildSummary_issueWithoutFile_omitsLocationEntirely() {
        let envelope = buildEnvelope(
            from: [issue(severity: "error", message: "linker died", file: nil, line: nil)],
            success: false)
        let summary = sut.extractBuildSummary(from: envelope)
        XCTAssertTrue(summary.contains("[E] linker died"))
        XCTAssertFalse(summary.contains("—"), "no file ⇒ no em-dash location clause: \(summary)")
    }

    /// A file with no line number keeps the file but must not emit a bare
    /// trailing colon.
    func testExtractBuildSummary_fileWithoutLine_emitsFileOnly() {
        let envelope = buildEnvelope(
            from: [issue(severity: "error", message: "bad", file: "A.swift", line: nil)],
            success: false)
        let summary = sut.extractBuildSummary(from: envelope)
        XCTAssertTrue(summary.contains("[E] bad — A.swift"), summary)
        XCTAssertFalse(summary.contains("A.swift:"), summary)
    }

    /// Severity is matched by a lowercased `w` prefix, so anything else — a
    /// missing severity, `note`, an unexpected token — is rendered as an error.
    /// That is the safe direction: an unclassified issue must not be downgraded
    /// to a warning and read as ignorable.
    func testExtractBuildSummary_severityDiscriminator_defaultsToError() {
        let envelope = buildEnvelope(
            from: [
                issue(severity: nil, message: "no-severity", file: nil, line: nil),
                issue(severity: "note", message: "a-note", file: nil, line: nil),
                issue(severity: "WARNING", message: "shouty-warning", file: nil, line: nil),
                issue(severity: "warning", message: "plain-warning", file: nil, line: nil),
            ],
            success: false)
        let summary = sut.extractBuildSummary(from: envelope)

        XCTAssertTrue(summary.contains("[E] no-severity"), summary)
        XCTAssertTrue(summary.contains("[E] a-note"), summary)
        XCTAssertTrue(summary.contains("[W] shouty-warning"), "matching is case-insensitive: \(summary)")
        XCTAssertTrue(summary.contains("[W] plain-warning"), summary)
    }

    func testExtractBuildSummary_issuesCappedAtTen() {
        let many = (0..<12).map {
            issue(severity: "error", message: "E-\(String(format: "%02d", $0))", file: nil, line: nil)
        }
        let summary = sut.extractBuildSummary(from: buildEnvelope(from: many, success: false))

        XCTAssertEqual(summary.components(separatedBy: "\n").count, 11,
                       "1 header + at most 10 issues")
        XCTAssertTrue(summary.contains("[E] E-09"), summary)
        XCTAssertFalse(summary.contains("[E] E-10"), "the 11th issue must be dropped: \(summary)")
        XCTAssertTrue(summary.hasPrefix("BUILD FAILED: 12 error(s)"),
                      "the header still reports the TRUE count, not the capped one")
    }

    /// `issues` present but not an array of objects: the cast fails and the
    /// summary degrades to the header alone rather than crashing.
    func testExtractBuildSummary_issuesWrongShape_degradesToHeaderOnly() {
        let json = "{\"ok\":true,\"data\":{\"success\":false,\"error_count\":2,"
            + "\"warning_count\":0,\"issues\":[\"a\",\"b\"]}}"
        XCTAssertEqual(sut.extractBuildSummary(from: json), "BUILD FAILED: 2 error(s), 0 warning(s)")
    }

    // MARK: - extractTestSummary corners

    func testExtractTestSummary_malformedOrMissingData_returnsUnknown() {
        XCTAssertEqual(sut.extractTestSummary(from: "nope"), "TESTS UNKNOWN")
        XCTAssertEqual(sut.extractTestSummary(from: ""), "TESTS UNKNOWN")
        XCTAssertEqual(sut.extractTestSummary(from: "{\"ok\":true}"), "TESTS UNKNOWN")
        XCTAssertEqual(sut.extractTestSummary(from: "{\"ok\":true,\"data\":42}"), "TESTS UNKNOWN")
    }

    func testExtractTestSummary_allPassing_reportsPassedCountOnly() {
        let envelope = makeSuccessEnvelope(data: XcodeBuildRunner.TestResult(
            success: true, exit_code: 0, passed: 42, failed: 0, skipped: 0,
            duration: 1, failures: [], log: ""))
        XCTAssertEqual(sut.extractTestSummary(from: envelope), "TESTS PASSED: 42 passed")
    }

    /// `failed == 0` alone is not enough — a non-success exit (e.g. the run
    /// aborted before any assertion) must still read as FAILED.
    func testExtractTestSummary_successFalseWithZeroFailures_reportsFailed() {
        let envelope = makeSuccessEnvelope(data: XcodeBuildRunner.TestResult(
            success: false, exit_code: 65, passed: 0, failed: 0, skipped: 0,
            duration: 1, failures: [], log: ""))
        XCTAssertEqual(sut.extractTestSummary(from: envelope),
                       "TESTS FAILED: 0 passed, 0 failed, 0 skipped")
    }

    /// Legacy envelopes spell the counters `tests_passed` / `tests_failed`; the
    /// fallback chain must pick them up.
    func testExtractTestSummary_legacyCounterKeys_areHonoured() {
        let json = "{\"ok\":true,\"data\":{\"success\":true,\"tests_passed\":7,\"tests_failed\":0}}"
        XCTAssertEqual(sut.extractTestSummary(from: json), "TESTS PASSED: 7 passed")

        let failing = "{\"ok\":true,\"data\":{\"success\":false,\"tests_passed\":5,"
            + "\"tests_failed\":2,\"skipped\":1}}"
        XCTAssertEqual(sut.extractTestSummary(from: failing),
                       "TESTS FAILED: 5 passed, 2 failed, 1 skipped")
    }

    /// The canonical key wins when both spellings are present.
    func testExtractTestSummary_canonicalKeyWinsOverLegacy() {
        let json = "{\"ok\":true,\"data\":{\"success\":true,\"passed\":9,\"tests_passed\":1,\"failed\":0}}"
        XCTAssertEqual(sut.extractTestSummary(from: json), "TESTS PASSED: 9 passed")
    }

    func testExtractTestSummary_failureWithFileAndLine_rendersLocation() throws {
        let json = try rawTestEnvelope(
            success: false, passed: 1, failed: 1, skipped: 0,
            failures: [["message": "XCTAssertEqual failed", "file": "FooTests.swift", "line": 15]])
        let summary = sut.extractTestSummary(from: json)

        XCTAssertTrue(summary.hasPrefix("TESTS FAILED: 1 passed, 1 failed, 0 skipped"), summary)
        XCTAssertTrue(summary.contains("[F] XCTAssertEqual failed — FooTests.swift:15"), summary)
    }

    /// The REAL producer is `XcodeBuildRunner.TestResult.failures`, typed
    /// `[[String: String]]`, so `line` arrives as a STRING. The reader's
    /// `as? Int` therefore never once succeeded in production and every test
    /// failure reached the model without its line number — invisible, because
    /// a hand-built fixture naturally spells the number as an Int and passes.
    func testExtractTestSummary_stringEncodedLine_isTheShapeProductionActuallySends() throws {
        let json = try rawTestEnvelope(
            success: false, passed: 1, failed: 1, skipped: 0,
            failures: [["message": "XCTAssertEqual failed", "file": "FooTests.swift", "line": "15"]])
        let summary = sut.extractTestSummary(from: json)

        XCTAssertTrue(summary.contains("[F] XCTAssertEqual failed — FooTests.swift:15"), summary)
    }

    func testExtractTestSummary_unparseableLine_keepsTheFileAndDropsTheColon() throws {
        let json = try rawTestEnvelope(
            success: false, passed: 0, failed: 1, skipped: 0,
            failures: [["message": "boom", "file": "FooTests.swift", "line": "not-a-number"]])
        let summary = sut.extractTestSummary(from: json)

        XCTAssertTrue(summary.contains("[F] boom — FooTests.swift"), summary)
        XCTAssertFalse(summary.contains("FooTests.swift:"), summary)
    }

    func testExtractTestSummary_failureWithoutFile_omitsLocation() throws {
        let json = try rawTestEnvelope(
            success: false, passed: 0, failed: 1, skipped: 0,
            failures: [["message": "crashed"]])
        let summary = sut.extractTestSummary(from: json)
        XCTAssertTrue(summary.contains("[F] crashed"), summary)
        XCTAssertFalse(summary.contains("—"), summary)
    }

    func testExtractTestSummary_failureWithNoMessage_usesQuestionMarkPlaceholder() throws {
        let json = try rawTestEnvelope(
            success: false, passed: 0, failed: 1, skipped: 0,
            failures: [["file": "FooTests.swift"]])
        XCTAssertTrue(sut.extractTestSummary(from: json).contains("[F] ? — FooTests.swift"))
    }

    func testExtractTestSummary_failuresCappedAtTen() throws {
        let failures: [[String: Any]] = (0..<12).map {
            ["message": "F-\(String(format: "%02d", $0))"]
        }
        let json = try rawTestEnvelope(
            success: false, passed: 0, failed: 12, skipped: 0, failures: failures)
        let summary = sut.extractTestSummary(from: json)

        XCTAssertEqual(summary.components(separatedBy: "\n").count, 11, "1 header + at most 10")
        XCTAssertTrue(summary.contains("[F] F-09"), summary)
        XCTAssertFalse(summary.contains("[F] F-10"), summary)
    }

    // MARK: - Git processing

    func testProcessGitStatus_errorResult_isPassthrough() {
        let result = ToolExecutionResult(
            toolName: ToolNames.gitStatus, argumentsJSON: "{}",
            outputJSON: makeErrorEnvelope(code: .commandFailed, message: "not a repo"),
            isError: true)
        guard case .passthrough = sut.processToolResult(result) else {
            return XCTFail("a failed git_status must pass through")
        }
    }

    func testProcessGitDiff_errorResult_isPassthrough() {
        let result = ToolExecutionResult(
            toolName: ToolNames.gitDiff, argumentsJSON: "{}",
            outputJSON: makeErrorEnvelope(code: .commandFailed, message: "not a repo"),
            isError: true)
        guard case .passthrough = sut.processToolResult(result) else {
            return XCTFail("a failed git_diff must pass through")
        }
    }

    /// A well-formed handler envelope is spliced in RAW (nested JSON object),
    /// never re-escaped as a string — double-escaping inflated git/bash payloads
    /// ~25-40% in escape-pair tokens and forced the model to mentally unescape
    /// nested JSON.
    ///
    /// RED: route the body through `jsonEscape` instead of the raw splice → the
    /// nested-object cast fails.
    func testProcessGitStatus_taggedEnvelope_splicesTheBodyRawAndUnescaped() throws {
        let body = "{\"ok\":true,\"data\":{\"branch\":\"feature/a-b\",\"modified\":[\"src/x.swift\"]}}"
        let (content, tag) = try tagged(sut.processToolResult(
            ToolExecutionResult(toolName: ToolNames.gitStatus, argumentsJSON: "{}",
                                outputJSON: body, isError: false)))

        XCTAssertFalse(content.contains("\\\""), "no escape pairs — the body is nested, not stringified: \(content)")
        let obj = try jsonObject(content)
        XCTAssertEqual(obj["tag"] as? String, tag)
        let nested = try XCTUnwrap(obj["content"] as? [String: Any],
                                   "a valid-JSON body must arrive as a nested object")
        let data = try XCTUnwrap(nested["data"] as? [String: Any])
        XCTAssertEqual(data["branch"] as? String, "feature/a-b")
    }

    /// The non-JSON fallback: a body that does not parse (raw text fixtures,
    /// corrupt output) is escaped as a string value so the wrapper stays valid.
    func testProcessGitDiff_nonJSONBody_isEscapedAsAStringValue() throws {
        let body = "diff --git a/x b/x\n+plain text, not JSON"
        let (content, _) = try tagged(sut.processToolResult(
            ToolExecutionResult(toolName: ToolNames.gitDiff, argumentsJSON: "{}",
                                outputJSON: body, isError: false)))

        let obj = try jsonObject(content)
        XCTAssertEqual(obj["content"] as? String, body, "a non-JSON body must round-trip verbatim as a string")
    }

    // MARK: - File-processing guard arms

    func testProcessRead_missingContentKey_isPassthrough() {
        let result = ToolExecutionResult(
            toolName: ToolNames.readFile,
            argumentsJSON: "{\"path\":\"A.swift\"}",
            outputJSON: "{\"ok\":true,\"data\":{\"path\":\"A.swift\",\"total_lines\":3}}",
            isError: false)
        guard case .passthrough = sut.processToolResult(result) else {
            return XCTFail("a read result with no content must pass through")
        }
    }

    func testProcessRead_missingPathArgument_isPassthrough() {
        let result = ToolExecutionResult(
            toolName: ToolNames.readFile,
            argumentsJSON: "{}",
            outputJSON: "{\"ok\":true,\"data\":{\"content\":\"x\",\"start_line\":1,"
                + "\"end_line\":1,\"total_lines\":1}}",
            isError: false)
        guard case .passthrough = sut.processToolResult(result) else {
            return XCTFail("a read with no path argument must pass through")
        }
    }

    func testProcessRead_errorResult_isPassthrough() {
        let result = ToolExecutionResult(
            toolName: ToolNames.readFile,
            argumentsJSON: "{\"path\":\"A.swift\"}",
            outputJSON: "{\"ok\":false,\"data\":{\"content\":\"partial\"}}",
            isError: true)
        guard case .passthrough = sut.processToolResult(result) else {
            return XCTFail("an errored read must pass through even if it carries content")
        }
    }

    /// A degenerate range (`end < start`) still gets a tag — the range is
    /// rendered as-is; there is no bookkeeping left to confuse.
    func testProcessRead_reversedRange_stillTags() throws {
        let result = readLinesResult(path: "A.swift", content: "x", start: 5, end: 2, total: 10)
        let (content, tag) = try tagged(sut.processToolResult(result))

        XCTAssertEqual(tag, "<§R1§>")
        XCTAssertTrue(content.contains("\"lines\":\"5-2\""), content)
    }

    /// Missing `start_line`/`end_line` default to 0, rendering the `0-0` range.
    func testProcessRead_missingLineBounds_defaultToZeroRange() throws {
        let result = ToolExecutionResult(
            toolName: ToolNames.readFile,
            argumentsJSON: "{\"path\":\"A.swift\"}",
            outputJSON: "{\"ok\":true,\"data\":{\"content\":\"body\"}}",
            isError: false)

        let (content, _) = try tagged(sut.processToolResult(result))
        XCTAssertTrue(content.contains("\"lines\":\"0-0\""), content)
    }

    func testProcessWrite_errorResult_isPassthrough() {
        let result = ToolExecutionResult(
            toolName: ToolNames.writeFile,
            argumentsJSON: "{\"path\":\"A.swift\",\"content\":\"x\"}",
            outputJSON: makeErrorEnvelope(code: .permissionDenied, message: "read-only"),
            isError: true)
        guard case .passthrough = sut.processToolResult(result) else {
            return XCTFail("a failed write must pass through")
        }
    }

    /// `write_file` takes its line count from the ARGUMENTS. When the key is
    /// absent the content is the empty string, which counts as one line.
    func testProcessWrite_missingContentArgument_rendersOneLine() throws {
        let result = ToolExecutionResult(
            toolName: ToolNames.writeFile,
            argumentsJSON: "{\"path\":\"A.swift\"}",
            outputJSON: "{\"ok\":true,\"data\":{\"path\":\"A.swift\",\"status\":\"success\"}}",
            isError: false)
        let (content, _) = try tagged(sut.processToolResult(result))

        let obj = try jsonObject(content)
        XCTAssertEqual(obj["lines"] as? Int, 1)
        XCTAssertEqual(obj["status"] as? String, "success")
    }

    func testProcessWrite_multilineContent_reportsLineCount() throws {
        let body = "a\nb\nc"
        let result = ToolExecutionResult(
            toolName: ToolNames.writeFile,
            argumentsJSON: "{\"path\":\"A.swift\",\"content\":\(sut.jsonEscape(body))}",
            outputJSON: "{\"ok\":true,\"data\":{\"path\":\"A.swift\",\"status\":\"success\"}}",
            isError: false)
        let (content, _) = try tagged(sut.processToolResult(result))
        XCTAssertEqual(try jsonObject(content)["lines"] as? Int, 3)
    }

    /// The edit envelope is read back by the model, so it must be parseable and
    /// name both the new edit tag and the path.
    func testProcessEdit_envelope_isValidJSONNamingTagAndPath() throws {
        let (content, tag) = try tagged(sut.processToolResult(
            editResult(path: "src/app/Main.swift")))

        XCTAssertFalse(content.contains("\\/"), "edit envelope must keep slashes literal: \(content)")
        let obj = try jsonObject(content)
        XCTAssertEqual(obj["tag"] as? String, tag)
        XCTAssertEqual(obj["path"] as? String, "src/app/Main.swift")
        XCTAssertEqual(obj["status"] as? String, "success")
    }

    // MARK: - JSON helpers

    func testParseJSON_rejectsNonObjects() {
        XCTAssertNil(sut.parseJSON(""))
        XCTAssertNil(sut.parseJSON("   "))
        XCTAssertNil(sut.parseJSON("[1,2,3]"))
        XCTAssertNil(sut.parseJSON("\"a bare string\""))
        XCTAssertNil(sut.parseJSON("{\"unterminated\": "))
        XCTAssertNil(sut.parseJSON("{'single':'quotes'}"))
        XCTAssertNotNil(sut.parseJSON("{}"))
    }

    func testExtractDataString_missingWrongTypeOrMissingEnvelope_returnsNil() {
        XCTAssertNil(sut.extractDataString(from: "garbage", key: "content"))
        XCTAssertNil(sut.extractDataString(from: "{\"ok\":true}", key: "content"))
        XCTAssertNil(sut.extractDataString(from: "{\"data\":{\"other\":1}}", key: "content"))
        XCTAssertNil(sut.extractDataString(from: "{\"data\":{\"content\":123}}", key: "content"),
                     "an int must not be coerced into a string")
        XCTAssertNil(sut.extractDataString(from: "{\"data\":{\"content\":null}}", key: "content"))
        XCTAssertEqual(sut.extractDataString(from: "{\"data\":{\"content\":\"x\"}}", key: "content"), "x")
        XCTAssertEqual(sut.extractDataString(from: "{\"data\":{\"content\":\"\"}}", key: "content"), "",
                       "an empty string is a real value, not a miss")
    }

    func testExtractDataInt_missingOrWrongType_returnsNil() {
        XCTAssertNil(sut.extractDataInt(from: "garbage", key: "total_lines"))
        XCTAssertNil(sut.extractDataInt(from: "{\"ok\":true}", key: "total_lines"))
        XCTAssertNil(sut.extractDataInt(from: "{\"data\":{\"total_lines\":\"12\"}}", key: "total_lines"),
                     "a string-encoded number must not be coerced")
        XCTAssertNil(sut.extractDataInt(from: "{\"data\":{\"total_lines\":null}}", key: "total_lines"))
        XCTAssertEqual(sut.extractDataInt(from: "{\"data\":{\"total_lines\":12}}", key: "total_lines"), 12)
        XCTAssertEqual(sut.extractDataInt(from: "{\"data\":{\"total_lines\":0}}", key: "total_lines"), 0)
        XCTAssertEqual(sut.extractDataInt(from: "{\"data\":{\"total_lines\":-3}}", key: "total_lines"), -3)
    }

    func testExtractString_flatObjectLookup() {
        XCTAssertNil(sut.extractString(from: "not json", key: "path"))
        XCTAssertNil(sut.extractString(from: "{}", key: "path"))
        XCTAssertNil(sut.extractString(from: "{\"path\":7}", key: "path"))
        XCTAssertEqual(sut.extractString(from: "{\"path\":\"a/b.swift\"}", key: "path"), "a/b.swift")
    }

    func testExtractPath_missingKeyOrMalformedJSON_returnsNil() {
        XCTAssertNil(sut.extractPath(from: "{}"))
        XCTAssertNil(sut.extractPath(from: "not json"))
        XCTAssertNil(sut.extractPath(from: "{\"file\":\"A.swift\"}"))
        XCTAssertNil(sut.extractPath(from: "{\"path\":42}"))
        XCTAssertEqual(sut.extractPath(from: "{\"path\":\"\"}"), "",
                       "without a work-folder root the raw value passes through unchanged")
    }

    func testJsonEscape_controlCharactersAndUnicodeRoundTrip() throws {
        for original in ["", "\u{0}\u{1}\u{1F}", "emoji 🧩 mixed", "tab\tnl\ncr\r", "已完成/done"] {
            let escaped = sut.jsonEscape(original)
            let decoded = try JSONSerialization.jsonObject(
                with: Data(escaped.utf8), options: [.fragmentsAllowed]) as? String
            XCTAssertEqual(decoded, original, "round-trip failed; escaped=\(escaped)")
        }
    }

    // MARK: - Dispatch seam

    /// The DIP seam: a caller-supplied processor claims a tool the production
    /// list has never heard of.
    func testProcessToolResult_injectedProcessor_isDispatched() throws {
        let procs: [any ToolResultProcessor] = [MTSPStubProcessor()]
        let store = MemoryTagStore(processors: procs)
        let call = ToolExecutionResult(
            toolName: "mtsp_stub_tool", argumentsJSON: "{}", outputJSON: "{}", isError: false)

        let (content, tag) = try tagged(store.processToolResult(call))
        XCTAssertEqual(content, "stub:mtsp_stub_tool")
        XCTAssertEqual(tag, "<§R1§>")
    }

    /// With no processors at all, every tool falls off the end of the dispatch
    /// loop — the branch the default list can never reach for a file tool.
    func testProcessToolResult_noProcessors_everyToolIsPassthrough() {
        let store = MemoryTagStore(processors: [])
        for name in [ToolNames.readFile, ToolNames.runXcodebuild, ToolNames.gitDiff] {
            let call = ToolExecutionResult(
                toolName: name, argumentsJSON: "{\"path\":\"A.swift\"}",
                outputJSON: "{\"ok\":true,\"data\":{\"content\":\"x\"}}", isError: false)
            guard case .passthrough = store.processToolResult(call) else {
                return XCTFail("\(name) must pass through when no processor claims it")
            }
        }
    }

    // MARK: - Fixture loading

    /// Reads a real xcodebuild log from `NanoTeamsTests/Fixtures/XcodebuildLogs/`
    /// and runs it through the production issue parser.
    ///
    /// Skips (rather than fails) when the fixture is absent: CI builds from a
    /// public mirror that carries build sources only, so a missing non-build
    /// asset must not turn into a red test.
    private func issuesFromFixture(_ name: String) throws -> [XcodeIssue] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LLM/
            .deletingLastPathComponent()   // Services/
            .deletingLastPathComponent()   // NanoTeamsTests/
            .appendingPathComponent("Fixtures/XcodebuildLogs/\(name).log")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("fixture \(name).log is not present in this checkout")
        }
        let log = try String(contentsOf: url, encoding: .utf8)
        return XcodeBuildRunner.parseIssues(
            from: log, workFolderRoot: URL(fileURLWithPath: "/Users/me/Proj"))
    }

    // MARK: - Envelope builders (production shapes)

    /// Wraps issues in the exact `BuildResult` envelope `run_xcodebuild` emits,
    /// deriving the counts the way `XcodeHandlers` does.
    private func buildEnvelope(
        from issues: [XcodeIssue],
        success: Bool,
        errorOverride: Int? = nil,
        warningOverride: Int? = nil
    ) -> String {
        makeSuccessEnvelope(data: XcodeBuildRunner.BuildResult(
            success: success,
            exit_code: success ? 0 : 65,
            duration: 0.5,
            error_count: errorOverride ?? issues.filter { $0.severity == "error" }.count,
            warning_count: warningOverride ?? issues.filter { $0.severity == "warning" }.count,
            issues: issues,
            log: success ? "" : "** BUILD FAILED **"))
    }

    private func issue(severity: String?, message: String, file: String?, line: Int?) -> XcodeIssue {
        XcodeIssue(file: file, line: line, column: nil, severity: severity, message: message, raw: nil)
    }

    private func buildResult(envelope: String) -> ToolExecutionResult {
        ToolExecutionResult(
            toolName: ToolNames.runXcodebuild, argumentsJSON: "{}",
            outputJSON: envelope, isError: false)
    }

    private func makeTestRunResult(passed: Int, failed: Int) -> ToolExecutionResult {
        let envelope = makeSuccessEnvelope(data: XcodeBuildRunner.TestResult(
            success: failed == 0, exit_code: failed == 0 ? 0 : 65,
            passed: passed, failed: failed, skipped: 0, duration: 1,
            failures: [], log: ""))
        return ToolExecutionResult(
            toolName: ToolNames.runXcodetests, argumentsJSON: "{}",
            outputJSON: envelope, isError: false)
    }

    /// A hand-built test envelope, needed where the failure dictionaries must
    /// carry heterogeneous value types that `TestResult`'s `[[String: String]]`
    /// cannot express.
    private func rawTestEnvelope(
        success: Bool, passed: Int, failed: Int, skipped: Int, failures: [[String: Any]]
    ) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: failures)
        let json = String(decoding: data, as: UTF8.self)
        return "{\"ok\":true,\"data\":{\"success\":\(success),\"passed\":\(passed),"
            + "\"failed\":\(failed),\"skipped\":\(skipped),\"failures\":\(json)}}"
    }

    private func readLinesResult(
        path: String, content: String, start: Int, end: Int, total: Int
    ) -> ToolExecutionResult {
        ToolExecutionResult(
            toolName: ToolNames.readLines,
            argumentsJSON: "{\"path\":\"\(path)\",\"start_line\":\(start),\"end_line\":\(end)}",
            outputJSON: "{\"ok\":true,\"data\":{\"path\":\"\(path)\",\"content\":"
                + "\(sut.jsonEscape(content)),\"start_line\":\(start),\"end_line\":\(end),"
                + "\"total_lines\":\(total)}}",
            isError: false)
    }

    private func editResult(path: String) -> ToolExecutionResult {
        ToolExecutionResult(
            toolName: ToolNames.editFile,
            argumentsJSON: "{\"path\":\"\(path)\",\"old_text\":\"x\",\"new_text\":\"y\"}",
            outputJSON: "{\"ok\":true,\"data\":{\"path\":\"\(path)\",\"status\":\"success\"}}",
            isError: false)
    }

    // MARK: - Assertion helpers

    private func tagged(
        _ result: TagProcessingResult, file: StaticString = #filePath, line: UInt = #line
    ) throws -> (content: String, tag: String) {
        guard case .tagged(let content, let tag) = result else {
            XCTFail("expected .tagged, got \(result)", file: file, line: line)
            throw MTSPFailure.unexpectedResult
        }
        return (content, tag)
    }

    private func jsonObject(
        _ json: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            XCTFail("not a JSON object: \(json)", file: file, line: line)
            throw MTSPFailure.unexpectedResult
        }
        return obj
    }
}
