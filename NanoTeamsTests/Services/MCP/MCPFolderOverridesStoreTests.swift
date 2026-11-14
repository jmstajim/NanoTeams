import XCTest

@testable import NanoTeams

/// Which of the configured servers a work folder may reach. Stored as a DISABLED list, which
/// is the whole design decision worth pinning.
final class MCPFolderOverridesStoreTests: XCTestCase {

    private var directory: URL!
    private var store: MCPFolderOverridesStore!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-folder-\(UUID().uuidString)", isDirectory: true)
        store = MCPFolderOverridesStore(
            fileURL: directory.appendingPathComponent("internal/mcp/mcp_folder.json"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        store = nil
        super.tearDown()
    }

    /// The common case — a folder that never disabled anything has no file at all, and that
    /// is an answer rather than a failure.
    func testAFolderWithNoFileAllowsEverything() {
        XCTAssertTrue(store.allows(UUID()))
        XCTAssertTrue(store.load().disabledServerIDs.isEmpty)
    }

    /// With an ENABLED list, a server added later would be silently absent from every folder
    /// that predates it — and "the tool is not there" is the hardest failure here to
    /// diagnose, because nothing is wrong anywhere.
    func testAServerAddedAfterTheFileWasWrittenIsStillAllowed() throws {
        try store.setServer(UUID(), enabled: false)
        XCTAssertTrue(store.allows(UUID()), "a server nobody disabled is allowed")
    }

    func testDisablingAndReEnablingRoundTrips() throws {
        let id = UUID()
        try store.setServer(id, enabled: false)
        XCTAssertFalse(store.allows(id))

        let reloaded = MCPFolderOverridesStore(
            fileURL: directory.appendingPathComponent("internal/mcp/mcp_folder.json"))
        XCTAssertFalse(reloaded.allows(id))

        try store.setServer(id, enabled: true)
        XCTAssertTrue(store.allows(id))
    }

    func testTheFileLivesUnderInternalAndIsOwnerOnly() throws {
        try store.setServer(UUID(), enabled: false)
        let url = directory.appendingPathComponent("internal/mcp/mcp_folder.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let directoryMode = try FileManager.default
            .attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int
        XCTAssertEqual(directoryMode, 0o700)
    }

    /// The path comes from `NTMSPaths`, so the file cannot drift out of the tree the LLM's
    /// file tools are blind to.
    func testTheConvenienceInitializerUsesTheWorkFolderPath() throws {
        let paths = NTMSPaths(workFolderRoot: directory)
        let fromPaths = MCPFolderOverridesStore(paths: paths)
        let id = UUID()
        try fromPaths.setServer(id, enabled: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.mcpFolderJSON.path))
        XCTAssertTrue(paths.mcpFolderJSON.path.contains("/internal/"))
        XCTAssertFalse(fromPaths.allows(id))
    }

    /// A hand-broken file loses the opt-outs rather than the folder: the safe direction is
    /// "allow what the app-wide catalogue allows", which the user can then narrow again.
    func testAnUnreadableFileReadsAsNoOverrides() throws {
        let url = directory.appendingPathComponent("internal/mcp/mcp_folder.json")
        try store.setServer(UUID(), enabled: false)
        try Data("{ not json".utf8).write(to: url)
        XCTAssertTrue(store.load().disabledServerIDs.isEmpty)
    }
}
