import XCTest

@testable import NanoTeams

/// The orchestrator side of MCP: when the manager is built, what the snapshot reads as before
/// and after, and the four paths that take it down.
@MainActor
final class NTMSOrchestratorMCPServersTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    /// Before any folder is open there is no manager, and `.empty` — not `nil` — is what a
    /// prompt builder is handed, which is what makes a prompt built without MCP byte-identical
    /// to one built before this feature existed.
    func testBeforeAFolderIsOpenedThereIsNoManagerAndNoTools() {
        XCTAssertNil(sut.mcpServerManager)
        XCTAssertNil(sut.mcpTools)
        XCTAssertTrue(MCPToolsSnapshot.empty.isEmpty)
    }

    /// Not gated on `hasRealWorkFolder`: a chat-mode team in default storage is a normal way
    /// to use this app, and a Folio server is just as useful there.
    func testOpeningAFolderBuildsTheManagerAndAnEmptyCatalogueIsAnAnswer() async {
        await sut.openWorkFolder(tempDir)
        XCTAssertNotNil(sut.mcpServerManager)
        XCTAssertEqual(sut.mcpTools?.isEmpty, true)
        XCTAssertTrue(sut.mcpServerManager?.connections.isEmpty ?? false)
    }

    /// The manager is built once and re-pointed, rather than rebuilt: rebuilding would drop
    /// every live connection on a folder switch between two folders that both allow a server.
    func testSwitchingFoldersKeepsTheManagerAndRePointsIt() async {
        await sut.openWorkFolder(tempDir)
        let first = sut.mcpServerManager
        let second = tempDir.appendingPathComponent("other", isDirectory: true)
        try? FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        await sut.openWorkFolder(second)
        XCTAssertTrue(first === sut.mcpServerManager)
    }

    func testTearingDownLeavesNoConnections() async {
        await sut.openWorkFolder(tempDir)
        await sut.tearDownMCPServerManager(budget: 0)
        XCTAssertTrue(sut.mcpServerManager?.connections.isEmpty ?? false)
        XCTAssertEqual(sut.mcpTools?.isEmpty, true)
    }

    /// The single step the termination delegate runs, with a folder open — both halves, and
    /// well inside the five seconds the delegate has in total.
    func testShutdownForTerminationTakesDownBothHalvesWithAFolderOpen() async {
        await sut.openWorkFolder(tempDir)
        let started = Date()
        await sut.shutdownForTermination()
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertNil(sut.searchIndexCoordinator)
        XCTAssertTrue(sut.mcpServerManager?.connections.isEmpty ?? false)
    }

    /// A test orchestrator must never read the developer's own configured servers, and must
    /// never be able to open a socket for one.
    func testTheTestOrchestratorIsPointedAtAnInertEnvironmentAndATempCatalogue() {
        XCTAssertTrue(sut.mcpEnvironment.secretStorage is EmptySecureTokenStorage)
        XCTAssertFalse(sut.mcpEnvironment.writesRPCLog)
        XCTAssertFalse(sut.mcpCatalogueStore.directory.path.hasSuffix("/NanoTeams/mcp"),
                       sut.mcpCatalogueStore.directory.path)
    }
}
