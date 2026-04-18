import XCTest

@testable import NanoTeams

/// Run 6 regression: CR called `create_artifact(format: "zip", ...)` and the
/// handler silently accepted it, producing a broken artifact. Unsupported
/// formats must now return an actionable error envelope.
final class CreateArtifactFormatValidationTests: XCTestCase {

    private var tempDir: URL!
    private var runtime: ToolRuntime!
    private var context: ToolExecutionContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let paths = NTMSPaths(workFolderRoot: tempDir)
        try FileManager.default.createDirectory(at: paths.nanoteamsDir, withIntermediateDirectories: true)
        let (_, run) = ToolRegistry.defaultRegistry(
            workFolderRoot: tempDir,
            toolCallsLogURL: paths.toolCallsJSONL(taskID: 0, runID: 0)
        )
        runtime = run
        context = ToolExecutionContext(
            workFolderRoot: tempDir,
            taskID: 0,
            runID: 0,
            roleID: "test_role"
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        context = nil
        tempDir = nil
        try super.tearDownWithError()
    }

    func testCreateArtifact_unsupportedFormat_returnsError() throws {
        let call = StepToolCall(
            name: "create_artifact",
            argumentsJSON: "{\"name\":\"Code Review\",\"content\":\"# r\",\"format\":\"zip\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertTrue(results[0].isError, "zip must be rejected")
        let out = results[0].outputJSON
        XCTAssertTrue(out.contains("Unsupported format"), "Error message must be actionable")
        XCTAssertTrue(out.contains("markdown") && out.contains("pdf") && out.contains("rtf") && out.contains("docx"),
                      "Error must list supported formats")
    }

    func testCreateArtifact_markdownFormat_accepted() throws {
        let call = StepToolCall(
            name: "create_artifact",
            argumentsJSON: "{\"name\":\"Plan\",\"content\":\"# plan\",\"format\":\"markdown\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
    }

    func testCreateArtifact_mdAlias_accepted() throws {
        let call = StepToolCall(
            name: "create_artifact",
            argumentsJSON: "{\"name\":\"Plan\",\"content\":\"# plan\",\"format\":\"md\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
    }

    func testCreateArtifact_pdfFormat_accepted() throws {
        let call = StepToolCall(
            name: "create_artifact",
            argumentsJSON: "{\"name\":\"Plan\",\"content\":\"# plan\",\"format\":\"pdf\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
    }

    /// Case-insensitive match per whitelist design.
    func testCreateArtifact_uppercaseFormat_accepted() throws {
        let call = StepToolCall(
            name: "create_artifact",
            argumentsJSON: "{\"name\":\"Plan\",\"content\":\"# plan\",\"format\":\"DOCX\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
    }

    func testCreateArtifact_noFormat_accepted() throws {
        let call = StepToolCall(
            name: "create_artifact",
            argumentsJSON: "{\"name\":\"Plan\",\"content\":\"# plan\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
    }

    // MARK: - Reentrant envelope through the runtime

    /// End-to-end: `{"name":"create_artifact","arguments":{"name":"CalculatorDemo",...}}`
    /// → unwrap kicks in → handler sees `name="CalculatorDemo"`. In Run 6 the
    /// artifact was literally named `create_artifact`. Strict assertions ensure
    /// that deleting `unwrapReentrantEnvelope` fails this test — a loose
    /// `contains("CalculatorDemo")` would still pass because CalculatorDemo
    /// survives in `argumentsJSON`.
    func testCreateArtifact_reentrantEnvelope_usesInnerName() throws {
        let argsJSON = "{\"name\":\"create_artifact\",\"arguments\":{\"name\":\"CalculatorDemo\",\"content\":\"# x\"}}"
        let call = StepToolCall(name: "create_artifact", argumentsJSON: argsJSON)
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)

        // The signal carries the canonical artifact name — the persistence path
        // in `LLMExecutionService` keys on this, not on `outputJSON` strings.
        guard case .artifact(let name, _, _) = results[0].signal else {
            XCTFail("Expected .artifact signal, got \(String(describing: results[0].signal))")
            return
        }
        XCTAssertEqual(name, "CalculatorDemo",
                       "Signal must carry the inner artifact name — Run 6 bug put 'create_artifact' here.")

        // Output envelope must also spell out the inner name so the LLM observes
        // the correct artifact in its tool-result view.
        XCTAssertTrue(results[0].outputJSON.contains("\"artifact\":\"CalculatorDemo\""),
                      "Output envelope must announce the inner name, not the outer tool name.")
        XCTAssertFalse(results[0].outputJSON.contains("\"artifact\":\"create_artifact\""),
                       "Outer tool name must not become the artifact name.")
    }

    /// Prefixed outer name (`functions.create_artifact`) must also unwrap.
    /// This is the C2 review fix: `unwrapReentrantEnvelope` now canonicalizes
    /// both sides of the name comparison.
    func testCreateArtifact_reentrantEnvelope_prefixedOuterName_unwraps() throws {
        let argsJSON = "{\"name\":\"functions.create_artifact\",\"arguments\":{\"name\":\"PlanDoc\",\"content\":\"...\"}}"
        let call = StepToolCall(name: "create_artifact", argumentsJSON: argsJSON)
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
        guard case .artifact(let name, _, _) = results[0].signal else {
            XCTFail("Expected .artifact signal")
            return
        }
        XCTAssertEqual(name, "PlanDoc",
                       "Prefixed outer name must still canonicalize and unwrap to inner dict.")
    }
}
