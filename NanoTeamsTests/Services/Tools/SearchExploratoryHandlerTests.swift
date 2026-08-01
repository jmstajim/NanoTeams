import XCTest
@testable import NanoTeams

final class SearchExploratoryHandlerTests: XCTestCase {

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

    private func makeTool(exploratoryByDefault: Bool = false) -> SearchTool {
        SearchTool(
            resolver: resolver,
            fileManager: fm,
            workFolderRoot: tempDir,
            internalDir: tempDir.appendingPathComponent(".nanoteams/internal", isDirectory: true),
            exploratoryByDefault: exploratoryByDefault,
            defaultMaxResults: AppDefaults.searchMaxResults,
            defaultContextBefore: AppDefaults.searchContextBefore,
            defaultContextAfter: AppDefaults.searchContextAfter
        )
    }

    private func ctx() -> ToolExecutionContext {
        ToolExecutionContext(
            workFolderRoot: tempDir, taskID: 1, runID: 1, roleID: "tester"
        )
    }

    // MARK: - exploratory=true → signal

    func testExpandTrue_emitsExploratorySearchSignal() {
        let result = makeTool().handle(
            context: ctx(),
            args: ["query": "scroll", "exploratory": true]
        )
        guard case .exploratorySearch(let payload) = result.signal else {
            XCTFail("Expected .exploratorySearch signal, got \(String(describing: result.signal))")
            return
        }
        XCTAssertEqual(payload.query, "scroll")
        XCTAssertFalse(result.isError)
    }

    func testExploratoryTrue_placeholderEnvelopeMarksExploring() {
        let result = makeTool().handle(
            context: ctx(),
            args: ["query": "scroll", "exploratory": true]
        )
        XCTAssertTrue(result.outputJSON.contains("\"status\""))
        XCTAssertTrue(result.outputJSON.contains("exploring"))
    }

    func testExpandTrue_passesThroughParameters() {
        let result = makeTool().handle(
            context: ctx(),
            args: [
                "query": "scroll",
                "exploratory": true,
                "mode": "regex",
                "paths": ["src"],
                "file_glob": "*.swift",
                "context_before": 2,
                "context_after": 3,
                "max_results": 15,
                "max_match_lines": 25,
            ]
        )
        guard case .exploratorySearch(let payload) = result.signal else {
            XCTFail("Expected exploratorySearch signal")
            return
        }
        XCTAssertEqual(payload.query, "scroll")
        XCTAssertEqual(payload.mode, .regex)
        XCTAssertEqual(payload.paths, ["src"])
        XCTAssertEqual(payload.fileGlob, "*.swift")
        XCTAssertEqual(payload.contextBefore, 2)
        XCTAssertEqual(payload.contextAfter, 3)
        XCTAssertEqual(payload.maxResults, 15)
        XCTAssertEqual(payload.offset, 0)
    }

    // MARK: - expand missing / false → plain search

    func testExpandFalse_runsPlainSearch() throws {
        let fileURL = tempDir.appendingPathComponent("a.swift")
        try "target here\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let result = makeTool().handle(
            context: ctx(),
            args: ["query": "target", "exploratory": false]
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

    /// User toggle "Default `search` calls to exploratory" is plumbed through
    /// `ToolHandlerDependencies.searchExploratoryByDefault`. When ON, a missing
    /// `exploratory` arg is treated as `true` and the handler emits a signal.
    func testExpandMissing_withExploratoryByDefault_emitsSignal() throws {
        let fileURL = tempDir.appendingPathComponent("a.swift")
        try "target here\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let result = makeTool(exploratoryByDefault: true).handle(
            context: ctx(),
            args: ["query": "target"]
        )
        guard case .exploratorySearch = result.signal else {
            XCTFail("Expected .exploratorySearch signal when default is on, got \(String(describing: result.signal))")
            return
        }
    }

    /// Explicit `exploratory: false` always wins over the user-toggle default.
    func testExpandFalseExplicit_withExploratoryByDefault_runsPlainSearch() throws {
        let fileURL = tempDir.appendingPathComponent("a.swift")
        try "target here\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let result = makeTool(exploratoryByDefault: true).handle(
            context: ctx(),
            args: ["query": "target", "exploratory": false]
        )
        XCTAssertNil(result.signal,
            "Explicit `exploratory: false` must override the user-toggle default.")
    }

    /// The old `expand` key is retired (pre-release rename). Asserting
    /// its absence ensures we don't accidentally re-introduce a silent alias.
    func testLegacyExploratorySearchKey_isIgnored() {
        let result = makeTool().handle(
            context: ctx(),
            args: ["query": "scroll", "exploratory_search": true]
        )
        XCTAssertNil(result.signal,
            "Legacy `expand` key is removed; must behave as plain search.")
    }

    // MARK: - Schema

    func testSchema_exposesExpandParameter() {
        let params = SearchTool.schema.parameters
        let keys = Set(params.properties?.keys ?? [:].keys)
        XCTAssertTrue(keys.contains("exploratory"),
            "Schema must expose `expand` as the primary flag. Keys: \(keys)")
        XCTAssertFalse(keys.contains("exploratory_search"),
            "Legacy `expand` key must not appear in the schema.")
    }
}
