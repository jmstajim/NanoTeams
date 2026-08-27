import XCTest
@testable import NanoTeams

/// Integration tests routing the `search` tool through the full
/// `ToolRegistry.defaultRegistry` + `ToolRuntime` stack — confirming that
/// argument parsing, handler dispatch, alias resolution, and signal
/// propagation all line up end-to-end.
final class ExploratorySearchRuntimeIntegrationTests: XCTestCase {

    private let fm = FileManager.default
    private var tempDir: URL!
    private var runtime: ToolRuntime!
    private var context: ToolExecutionContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let paths = NTMSPaths(workFolderRoot: tempDir)
        try fm.createDirectory(at: paths.nanoteamsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.internalDir, withIntermediateDirectories: true)

        let (_, run) = ToolRegistry.defaultRegistry(
            workFolderRoot: tempDir,
            toolCallsLogURL: paths.toolCallsJSONL(taskID: 0, runID: 0)
        )
        runtime = run
        context = ToolExecutionContext(
            workFolderRoot: tempDir, taskID: 0, runID: 0, roleID: "tester"
        )
    }

    override func tearDownWithError() throws {
        if let tempDir { try? fm.removeItem(at: tempDir) }
        tempDir = nil
        runtime = nil
        context = nil
        try super.tearDownWithError()
    }

    private func write(_ relPath: String, content: String) throws {
        let url = tempDir.appendingPathComponent(relPath)
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Plain search via runtime: parity with old behavior

    func testPlainSearch_viaRuntime_returnsExpectedShape() async throws {
        try write("a.swift", content: "let target = 1\n")

        let call = StepToolCall(
            name: "search",
            argumentsJSON: #"{"query": "target"}"#
        )
        let results = await runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertEqual(results.count, 1)
        let r = results[0]
        XCTAssertFalse(r.isError)
        XCTAssertNil(r.signal, "Plain search must not emit any signal.")
        XCTAssertTrue(r.outputJSON.contains("\"matches\""))
        XCTAssertTrue(r.outputJSON.contains("\"query\":\"target\""))
        XCTAssertTrue(r.outputJSON.contains("\"path\":\"a.swift\""))
    }

    // MARK: - Broad search via runtime: signal makes it back

    func testExploratorySearch_viaRuntime_emitsExploratorySearchSignal() async throws {
        try write("a.swift", content: "anything\n")

        let call = StepToolCall(
            name: "search",
            argumentsJSON: #"{"query": "scroll", "exploratory": true}"#
        )
        let results = await runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertEqual(results.count, 1)
        guard case .exploratorySearch(let payload) = results[0].signal else {
            XCTFail("Expected .exploratorySearch signal, got \(String(describing: results[0].signal))")
            return
        }
        XCTAssertEqual(payload.query, "scroll")
        XCTAssertFalse(results[0].isError)
    }

    // MARK: - Aliases route to exploratory search too

    func testGrepAlias_withExploratorySearch_emitsSignal() async throws {
        let call = StepToolCall(
            name: "grep",
            argumentsJSON: #"{"query": "scroll", "exploratory": true}"#
        )
        let results = await runtime.executeAll(context: context, toolCalls: [call])
        guard case .exploratorySearch = results[0].signal else {
            XCTFail("grep alias must route to SearchTool and propagate exploratory_search.")
            return
        }
    }

    func testFindAlias_withExploratorySearch_emitsSignal() async throws {
        let call = StepToolCall(
            name: "find",
            argumentsJSON: #"{"query": "scroll", "exploratory": true}"#
        )
        let results = await runtime.executeAll(context: context, toolCalls: [call])
        guard case .exploratorySearch = results[0].signal else {
            XCTFail("find alias must route to SearchTool and propagate exploratory_search.")
            return
        }
    }

    // MARK: - Provider-prefix tool name: functions.search

    func testFunctionsPrefix_withExploratorySearch_emitsSignal() async throws {
        let call = StepToolCall(
            name: "functions.search",
            argumentsJSON: #"{"query": "scroll", "exploratory": true}"#
        )
        let results = await runtime.executeAll(context: context, toolCalls: [call])
        guard case .exploratorySearch = results[0].signal else {
            XCTFail("functions.* prefix must be stripped before dispatch.")
            return
        }
    }

    // MARK: - All passthrough parameters preserved

    func testExploratorySearch_passesAllOptionalParametersIntoSignal() async throws {
        let call = StepToolCall(
            name: "search",
            argumentsJSON: #"""
            {
              "query": "scroll",
              "exploratory": true,
              "mode": "regex",
              "paths": ["src", "lib"],
              "file_glob": "*.swift",
              "context_before": 1,
              "context_after": 2,
              "max_results": 5,
              "max_match_lines": 8
            }
            """#
        )
        let results = await runtime.executeAll(context: context, toolCalls: [call])
        guard case .exploratorySearch(let payload) = results[0].signal else {
            XCTFail("Expected .exploratorySearch")
            return
        }
        XCTAssertEqual(payload.query, "scroll")
        XCTAssertEqual(payload.mode, .regex)
        XCTAssertEqual(payload.paths, ["src", "lib"])
        XCTAssertEqual(payload.fileGlob, "*.swift")
        XCTAssertEqual(payload.contextBefore, 1)
        XCTAssertEqual(payload.contextAfter, 2)
        XCTAssertEqual(payload.maxResults, 5)
        XCTAssertEqual(payload.offset, 0)
    }

    // MARK: - providerID is set by the runtime even on signal results

    func testExploratorySearch_signalResult_hasProviderID() async throws {
        let call = StepToolCall(
            providerID: "call_xyz_123",
            name: "search",
            argumentsJSON: #"{"query": "x", "exploratory": true}"#
        )
        let results = await runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertEqual(results[0].providerID, "call_xyz_123",
                       "ToolRuntime must propagate providerID into the exploratorySearch signal result.")
    }

    // MARK: - Plain regex still works through runtime

    func testPlainSearch_regexMode_viaRuntime() async throws {
        try write("a.swift", content: "hello42\nworld43\n")
        let call = StepToolCall(
            name: "search",
            argumentsJSON: #"{"query": "^world\\d+$", "mode": "regex"}"#
        )
        let results = await runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)

        // Inspect the parsed `matches` array — `hello42` can legitimately
        // appear inside `context_before` (AppDefaults is non-zero), but the
        // anchored `^world\d+$` regex must match `world43` only.
        let data = results[0].outputJSON.data(using: .utf8) ?? Data()
        let env = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let payload = env?["data"] as? [String: Any]
        let matches = payload?["matches"] as? [[String: Any]]
        XCTAssertEqual(matches?.count, 1)
        XCTAssertEqual(matches?.first?["text"] as? String, "world43")
        XCTAssertEqual(matches?.first?["line"] as? Int, 2)
    }
}
