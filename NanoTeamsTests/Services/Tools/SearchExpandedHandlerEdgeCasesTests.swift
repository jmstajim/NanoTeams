import XCTest
@testable import NanoTeams

/// Edge cases for `SearchTool.handle` under the `expand` flag —
/// defensive against LLM-ugly arg permutations and ensures the plain path
/// behavior doesn't regress when the flag is absent.
final class SearchExpandedHandlerEdgeCasesTests: XCTestCase {

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
        ToolExecutionContext(workFolderRoot: tempDir, taskID: 1, runID: 1, roleID: "tester")
    }

    // MARK: - Plain path still honors paths / file_glob

    func testPlain_withFileGlob_scopedMatches() throws {
        try "target\n".write(
            to: tempDir.appendingPathComponent("a.swift"),
            atomically: true, encoding: .utf8
        )
        try "target\n".write(
            to: tempDir.appendingPathComponent("a.md"),
            atomically: true, encoding: .utf8
        )
        let result = makeTool().handle(
            context: ctx(),
            args: ["query": "target", "file_glob": "*.swift"]
        )
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.outputJSON.contains("a.swift"))
        XCTAssertFalse(result.outputJSON.contains("\"a.md\""))
    }

    // MARK: - Missing query — the only required arg

    func testMissingQuery_returnsInvalidArgsError() {
        let result = makeTool().handle(
            context: ctx(),
            args: ["expand": true]
        )
        XCTAssertTrue(result.isError)
        XCTAssertNil(result.signal)
    }

    // MARK: - expand with non-bool value (defensive)

    func testExpand_stringValue_treatedAsFalse() throws {
        // LLMs sometimes emit `"true"` (string) instead of `true` (bool).
        // `optionalBool` doesn't coerce strings → falls back to default false
        // → plain path.
        try "target\n".write(
            to: tempDir.appendingPathComponent("a.swift"),
            atomically: true, encoding: .utf8
        )
        let result = makeTool().handle(
            context: ctx(),
            args: ["query": "target", "expand": "true"]
        )
        XCTAssertNil(result.signal,
                     "String 'true' must not trigger expanded search — only real bool true.")
    }

    func testExpand_intValue_treatedAsFalse() throws {
        try "target\n".write(
            to: tempDir.appendingPathComponent("a.swift"),
            atomically: true, encoding: .utf8
        )
        let result = makeTool().handle(
            context: ctx(),
            args: ["query": "target", "expand": 1]
        )
        XCTAssertNil(result.signal)
    }

    // MARK: - Signal carries optional args as expected

    func testSignal_noOptionalArgs_allDefaults() {
        let result = makeTool().handle(
            context: ctx(),
            args: ["query": "scroll", "expand": true]
        )
        guard case .expandedSearch(let payload) = result.signal else {
            XCTFail("Expected expandedSearch signal")
            return
        }
        XCTAssertEqual(payload.mode, .substring)
        XCTAssertNil(payload.paths)
        XCTAssertNil(payload.fileGlob)
        XCTAssertEqual(payload.contextBefore, 0)
        XCTAssertEqual(payload.contextAfter, 0)
        XCTAssertEqual(payload.maxResults, 20)
        XCTAssertEqual(payload.maxMatchLines, 40)
    }

    // MARK: - Signal envelope shape

    func testSignal_envelopeIsValidJSON_andMentionsExpanding() throws {
        let result = makeTool().handle(
            context: ctx(),
            args: ["query": "scroll", "expand": true]
        )
        let data = result.outputJSON.data(using: .utf8) ?? Data()
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(parsed, "Interim envelope must be valid JSON")
        let inner = parsed?["data"] as? [String: Any]
        XCTAssertEqual(inner?["status"] as? String, "expanding")
        XCTAssertEqual(inner?["query"] as? String, "scroll")
    }

    // MARK: - Schema description & parameter shape

    func testSchema_expandProperty_isBoolean() {
        let schema = SearchTool.schema
        let expand = schema.parameters.properties?["expand"]
        XCTAssertEqual(expand?.type, "boolean")
    }

    func testSchema_expand_notRequired() {
        let schema = SearchTool.schema
        XCTAssertFalse(schema.parameters.required?.contains("expand") ?? false,
                       "expand must remain optional — always-on would double charge every search.")
    }

    // MARK: - Aliases still land on SearchTool

    func testAlias_grep_resolvesToSearch() {
        XCTAssertEqual(ToolRegistry.resolveToolName("grep"), ToolNames.search)
    }

    func testAlias_find_resolvesToSearch() {
        XCTAssertEqual(ToolRegistry.resolveToolName("find"), ToolNames.search)
    }
}
