import XCTest
@testable import NanoTeams

final class SearchExpandedHandlerTests: XCTestCase {

    private let fm = FileManager.default
    private var tempDir: URL!
    private var resolver: SandboxPathResolver!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let internalDir = tempDir.appendingPathComponent(".nanoteams/internal", isDirectory: true)
        try fm.createDirectory(at: internalDir, withIntermediateDirectories: true)
        resolver = SandboxPathResolver(workFolderRoot: tempDir, internalDir: internalDir)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? fm.removeItem(at: tempDir) }
        tempDir = nil
        resolver = nil
        try super.tearDownWithError()
    }

    private func makeTool() -> SearchTool {
        SearchTool(
            resolver: resolver,
            fileManager: fm,
            workFolderRoot: tempDir,
            internalDir: tempDir.appendingPathComponent(".nanoteams/internal", isDirectory: true)
        )
    }

    private func ctx() -> ToolExecutionContext {
        ToolExecutionContext(
            workFolderRoot: tempDir, taskID: 1, runID: 1, roleID: "tester"
        )
    }

    // MARK: - expand=true → signal

    func testExpandTrue_emitsExpandedSearchSignal() {
        let result = makeTool().handle(
            context: ctx(),
            args: ["query": "scroll", "expand": true]
        )
        guard case .expandedSearch(let payload) = result.signal else {
            XCTFail("Expected .expandedSearch signal, got \(String(describing: result.signal))")
            return
        }
        XCTAssertEqual(payload.query, "scroll")
        XCTAssertFalse(result.isError)
    }

    func testExpandTrue_placeholderEnvelopeMarksExpanding() {
        let result = makeTool().handle(
            context: ctx(),
            args: ["query": "scroll", "expand": true]
        )
        XCTAssertTrue(result.outputJSON.contains("\"status\""))
        XCTAssertTrue(result.outputJSON.contains("expanding"))
    }

    func testExpandTrue_passesThroughParameters() {
        let result = makeTool().handle(
            context: ctx(),
            args: [
                "query": "scroll",
                "expand": true,
                "mode": "regex",
                "paths": ["src"],
                "file_glob": "*.swift",
                "context_before": 2,
                "context_after": 3,
                "max_results": 15,
                "max_match_lines": 25,
            ]
        )
        guard case .expandedSearch(let payload) = result.signal else {
            XCTFail("Expected expandedSearch signal")
            return
        }
        XCTAssertEqual(payload.query, "scroll")
        XCTAssertEqual(payload.mode, .regex)
        XCTAssertEqual(payload.paths, ["src"])
        XCTAssertEqual(payload.fileGlob, "*.swift")
        XCTAssertEqual(payload.contextBefore, 2)
        XCTAssertEqual(payload.contextAfter, 3)
        XCTAssertEqual(payload.maxResults, 15)
        XCTAssertEqual(payload.maxMatchLines, 25)
    }

    // MARK: - expand missing / false → plain search

    func testExpandFalse_runsPlainSearch() throws {
        let fileURL = tempDir.appendingPathComponent("a.swift")
        try "target here\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let result = makeTool().handle(
            context: ctx(),
            args: ["query": "target", "expand": false]
        )
        XCTAssertNil(result.signal, "Plain search must not emit a signal.")
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.outputJSON.contains("\"matches\""))
    }

    func testExpandMissing_runsPlainSearch() throws {
        let fileURL = tempDir.appendingPathComponent("a.swift")
        try "target here\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let result = makeTool().handle(
            context: ctx(),
            args: ["query": "target"]
        )
        XCTAssertNil(result.signal)
        XCTAssertFalse(result.isError)
    }

    /// The old `expand` key is retired (pre-release rename). Asserting
    /// its absence ensures we don't accidentally re-introduce a silent alias.
    func testLegacyExpandedSearchKey_isIgnored() {
        let result = makeTool().handle(
            context: ctx(),
            args: ["query": "scroll", "expanded_search": true]
        )
        XCTAssertNil(result.signal,
            "Legacy `expand` key is removed; must behave as plain search.")
    }

    // MARK: - Schema

    func testSchema_exposesExpandParameter() {
        let params = SearchTool.schema.parameters
        let keys = Set(params.properties?.keys ?? [:].keys)
        XCTAssertTrue(keys.contains("expand"),
            "Schema must expose `expand` as the primary flag. Keys: \(keys)")
        XCTAssertFalse(keys.contains("expanded_search"),
            "Legacy `expand` key must not appear in the schema.")
    }
}
