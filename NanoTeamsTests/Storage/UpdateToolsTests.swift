import XCTest

@testable import NanoTeams

/// `NTMSRepository.updateTools(at:tools:)` was at 0% coverage — the only writer
/// of `tools.json`, and the one place a user's custom tool definitions survive
/// or are lost.
///
/// It bootstraps the folder, merges the incoming list with the built-in
/// defaults, writes, and re-assembles the context. The merge is the interesting
/// part: it must NORMALISE built-ins back to their shipped definition (so an
/// edited built-in cannot drift), PRESERVE custom entries, and APPEND any
/// default the caller omitted — otherwise a save from a stale UI silently drops
/// every tool added since that UI was rendered.
///
/// `NTMSRepository` is a `nonisolated struct`, so this class stays nonisolated.
final class UpdateToolsTests: XCTestCase {

    private var tempDir: URL!
    private var paths: NTMSPaths!
    private var sut: NTMSRepository!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("update-tools-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        paths = NTMSPaths(workFolderRoot: tempDir)
        sut = NTMSRepository()
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        sut = nil
        paths = nil
        tempDir = nil
        super.tearDown()
    }

    private func customTool(id: String) -> ToolDefinitionRecord {
        ToolDefinitionRecord(
            id: id,
            name: id,
            prompt: "a tool the user wrote",
            parameters: JSONSchema(type: "object"),
            isBuiltIn: false)
    }

    private var defaultIDs: [String] {
        ToolDefinitionRecord.defaultDefinitions().map(\.id)
    }

    // MARK: - Bootstrapping

    func testUpdateTools_onAVirginFolder_createsTheLayoutAndWritesToolsJSON() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.toolsJSON.path))

        let context = try sut.updateTools(at: tempDir, tools: [])

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: paths.toolsJSON.path),
            "updateTools is responsible for its own layout — it is reachable before any open")
        XCTAssertFalse(context.toolDefinitions.isEmpty)
    }

    // MARK: - The merge

    func testUpdateTools_emptyInput_stillYieldsEveryBuiltInTool() throws {
        let context = try sut.updateTools(at: tempDir, tools: [])
        XCTAssertEqual(
            Set(context.toolDefinitions.map(\.id)), Set(defaultIDs),
            "an empty save must not be able to erase the built-in catalogue")
        XCTAssertTrue(context.toolDefinitions.allSatisfy(\.isBuiltIn))
    }

    func testUpdateTools_customTool_isPreservedAlongsideTheDefaults() throws {
        let mine = customTool(id: "my_custom_tool")
        let context = try sut.updateTools(at: tempDir, tools: [mine])

        let ids = context.toolDefinitions.map(\.id)
        XCTAssertTrue(ids.contains("my_custom_tool"))
        XCTAssertEqual(Set(ids), Set(defaultIDs + ["my_custom_tool"]))

        let stored = try XCTUnwrap(context.toolDefinitions.first { $0.id == "my_custom_tool" })
        XCTAssertFalse(stored.isBuiltIn)
        XCTAssertEqual(stored.prompt, "a tool the user wrote")
    }

    func testUpdateTools_customToolKeepsItsPositionAheadOfAppendedDefaults() throws {
        let mine = customTool(id: "aaa_custom")
        let context = try sut.updateTools(at: tempDir, tools: [mine])
        XCTAssertEqual(context.toolDefinitions.first?.id, "aaa_custom",
                       "caller order is preserved; only omitted defaults are appended, at the end")
    }

    /// A built-in's shipped prompt/schema is the source of truth. Round-tripping
    /// an edited copy must snap back, or a stale UI save would fork the tool
    /// description that ships in every system prompt.
    func testUpdateTools_editedBuiltIn_isNormalisedBackToItsShippedDefinition() throws {
        let shipped = try XCTUnwrap(ToolDefinitionRecord.defaultDefinitions().first)
        var tampered = shipped
        tampered.prompt = "TAMPERED"
        tampered.isBuiltIn = false

        let context = try sut.updateTools(at: tempDir, tools: [tampered])
        let result = try XCTUnwrap(context.toolDefinitions.first { $0.id == shipped.id })

        XCTAssertEqual(result.prompt, shipped.prompt)
        XCTAssertTrue(result.isBuiltIn, "a built-in id cannot be demoted to a custom tool")
    }

    /// Timestamps are the one thing the caller's copy wins on — they record when
    /// the user last touched the row, and the shipped default has no idea.
    func testUpdateTools_builtIn_keepsTheCallersTimestamps() throws {
        let shipped = try XCTUnwrap(ToolDefinitionRecord.defaultDefinitions().first)
        let then = Date(timeIntervalSince1970: 1_000_000)
        var withHistory = shipped
        withHistory.createdAt = then
        withHistory.updatedAt = then

        let context = try sut.updateTools(at: tempDir, tools: [withHistory])
        let result = try XCTUnwrap(context.toolDefinitions.first { $0.id == shipped.id })

        XCTAssertEqual(result.createdAt.timeIntervalSince1970, then.timeIntervalSince1970,
                       accuracy: 1.0)
        XCTAssertEqual(result.updatedAt.timeIntervalSince1970, then.timeIntervalSince1970,
                       accuracy: 1.0)
    }

    func testUpdateTools_duplicateIDsInInput_areCollapsedToTheFirst() throws {
        let first = customTool(id: "dup")
        var second = customTool(id: "dup")
        second.prompt = "the loser"

        let context = try sut.updateTools(at: tempDir, tools: [first, second])
        let matches = context.toolDefinitions.filter { $0.id == "dup" }

        XCTAssertEqual(matches.count, 1, "a duplicated id must not produce two rows")
        XCTAssertEqual(matches.first?.prompt, "a tool the user wrote")
    }

    // MARK: - Persistence

    func testUpdateTools_writesWhatItReturns() throws {
        let context = try sut.updateTools(at: tempDir, tools: [customTool(id: "persisted_tool")])

        let onDisk = try JSONCoderFactory.makeDateDecoder()
            .decode([ToolDefinitionRecord].self, from: Data(contentsOf: paths.toolsJSON))

        XCTAssertEqual(onDisk.map(\.id), context.toolDefinitions.map(\.id),
                       "the returned context must describe the bytes actually written")
        XCTAssertTrue(onDisk.contains { $0.id == "persisted_tool" })
    }

    func testUpdateTools_isIdempotentWhenReappliedToItsOwnOutput() throws {
        let first = try sut.updateTools(at: tempDir, tools: [customTool(id: "stable")])
        let second = try sut.updateTools(at: tempDir, tools: first.toolDefinitions)

        XCTAssertEqual(second.toolDefinitions.map(\.id), first.toolDefinitions.map(\.id),
                       "re-saving an unchanged list must not reorder or duplicate anything")
    }

    func testUpdateTools_secondSaveDroppingTheCustomTool_actuallyRemovesIt() throws {
        _ = try sut.updateTools(at: tempDir, tools: [customTool(id: "temporary")])
        let after = try sut.updateTools(at: tempDir, tools: [])

        XCTAssertFalse(after.toolDefinitions.contains { $0.id == "temporary" },
                       "the write is a replacement, not a union — deleting a custom tool must stick")
        XCTAssertEqual(Set(after.toolDefinitions.map(\.id)), Set(defaultIDs))
    }
}
