import XCTest
@testable import NanoTeams

/// Edge cases for `SearchTool.handle` under the `expand` flag —
/// defensive against LLM-ugly arg permutations and ensures the plain path
/// behavior doesn't regress when the flag is absent.
final class SearchExploratoryHandlerEdgeCasesTests: XCTestCase {

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
            internalDir: tempDir.appendingPathComponent(".nanoteams/internal", isDirectory: true),
            exploratoryByDefault: false,
            defaultMaxResults: AppDefaults.searchMaxResults,
            defaultContextBefore: AppDefaults.searchContextBefore,
            defaultContextAfter: AppDefaults.searchContextAfter
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
            args: ["exploratory": true]
        )
        XCTAssertTrue(result.isError)
        XCTAssertNil(result.signal)
    }

    // MARK: - expand with non-bool value (defensive)

    func testExpand_stringValue_coerces() throws {
        // LLMs sometimes emit `"true"` (string) instead of `true` (bool).
        // `optionalBool` coerces the unambiguous spellings, so the model gets
        // the search it asked for instead of silently getting the plain path.
        try "target\n".write(
            to: tempDir.appendingPathComponent("a.swift"),
            atomically: true, encoding: .utf8
        )
        let result = makeTool().handle(
            context: ctx(),
            args: ["query": "target", "exploratory": "true"]
        )
        XCTAssertNotNil(result.signal,
                        "String 'true' must request exploratory search, same as a real bool.")
    }

    func testExpand_intValue_coerces() throws {
        try "target\n".write(
            to: tempDir.appendingPathComponent("a.swift"),
            atomically: true, encoding: .utf8
        )
        let result = makeTool().handle(
            context: ctx(),
            args: ["query": "target", "exploratory": 1]
        )
        XCTAssertNotNil(result.signal)
    }

    func testExpand_ambiguousValue_treatedAsFalse() throws {
        // Coercion covers only unambiguous spellings — a value that is not a
        // boolean in any reading keeps the default rather than being guessed at.
        try "target\n".write(
            to: tempDir.appendingPathComponent("a.swift"),
            atomically: true, encoding: .utf8
        )
        let result = makeTool().handle(
            context: ctx(),
            args: ["query": "target", "exploratory": "sometimes"]
        )
        XCTAssertNil(result.signal)
    }

    // MARK: - Signal carries optional args as expected

    func testSignal_noOptionalArgs_allDefaults() {
        let result = makeTool().handle(
            context: ctx(),
            args: ["query": "scroll", "exploratory": true]
        )
        guard case .exploratorySearch(let payload) = result.signal else {
            XCTFail("Expected exploratorySearch signal")
            return
        }
        XCTAssertEqual(payload.mode, .substring)
        XCTAssertNil(payload.paths)
        XCTAssertNil(payload.fileGlob)
        XCTAssertEqual(payload.contextBefore, AppDefaults.searchContextBefore)
        XCTAssertEqual(payload.contextAfter, AppDefaults.searchContextAfter)
        XCTAssertEqual(payload.maxResults, AppDefaults.searchMaxResults)
        XCTAssertEqual(payload.offset, 0)
    }

    // MARK: - Signal envelope shape

    func testSignal_envelopeIsValidJSON_andMentionsExploring() throws {
        let result = makeTool().handle(
            context: ctx(),
            args: ["query": "scroll", "exploratory": true]
        )
        let data = result.outputJSON.data(using: .utf8) ?? Data()
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(parsed, "Interim envelope must be valid JSON")
        let inner = parsed?["data"] as? [String: Any]
        XCTAssertEqual(inner?["status"] as? String, "exploring")
        XCTAssertEqual(inner?["query"] as? String, "scroll")
    }

    // MARK: - Schema description & parameter shape

    func testSchema_expandProperty_isBoolean() {
        let schema = SearchTool.schema
        let expand = schema.parameters.properties?["exploratory"]
        XCTAssertEqual(expand?.type, "boolean")
    }

    func testSchema_expand_notRequired() {
        let schema = SearchTool.schema
        XCTAssertFalse(schema.parameters.required?.contains("exploratory") ?? false,
                       "expand must remain optional — always-on would double charge every search.")
    }

    func testSchema_exposesPathsAsArrayOfStrings() {
        let paths = SearchTool.schema.parameters.properties?["paths"]
        XCTAssertEqual(paths?.type, "array")
        XCTAssertEqual(paths?.items?.type, "string")
    }

    func testSchema_exposesFileGlobAsString() {
        let glob = SearchTool.schema.parameters.properties?["file_glob"]
        XCTAssertEqual(glob?.type, "string")
    }

    func testSchema_pathsAndFileGlobAreOptional() {
        let required = SearchTool.schema.parameters.required ?? []
        XCTAssertFalse(required.contains("paths"))
        XCTAssertFalse(required.contains("file_glob"))
    }

    // MARK: - Aliases still land on SearchTool

    func testAlias_grep_resolvesToSearch() {
        XCTAssertEqual(ToolRegistry.resolveToolName("grep"), ToolNames.search)
    }

    func testAlias_find_resolvesToSearch() {
        XCTAssertEqual(ToolRegistry.resolveToolName("find"), ToolNames.search)
    }
}
