import XCTest

@testable import NanoTeams

@MainActor
final class WorkFolderManagementServiceTests: XCTestCase {

    private let fileManager = FileManager.default
    private var tempDir: URL!
    private var repository: NTMSRepository!
    private var service: WorkFolderManagementService!
    /// Fresh service instance for round-trip persistence tests
    private var freshService: WorkFolderManagementService!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        repository = NTMSRepository()
        service = WorkFolderManagementService(repository: repository)
        freshService = WorkFolderManagementService(repository: repository)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? fileManager.removeItem(at: tempDir)
        }
//        service = nil
//        freshService = nil
        repository = nil
        tempDir = nil
        try await super.tearDown()
    }

    // MARK: - openOrCreateWorkFolder

    func testOpenOrCreateProject_CreatesNewProject() async throws {
        let context = try await service.openOrCreateWorkFolder(at: tempDir)
        XCTAssertNotNil(context.workFolder)
        XCTAssertEqual(context.workFolder.name, tempDir.lastPathComponent)
    }

    func testOpenOrCreateProject_OpensExistingProject() async throws {
        // Create project first
        _ = try await service.openOrCreateWorkFolder(at: tempDir)

        // Open again
        let context = try await service.openOrCreateWorkFolder(at: tempDir)
        XCTAssertNotNil(context.workFolder)
    }

    func testOpenOrCreateProject_CreatesNanoteamsDirectory() async throws {
        _ = try await service.openOrCreateWorkFolder(at: tempDir)
        let nanoteamsDir = tempDir.appendingPathComponent(".nanoteams")
        XCTAssertTrue(fileManager.fileExists(atPath: nanoteamsDir.path))
    }

    // MARK: - updateWorkFolderContext

    func testUpdateWorkFolderContext_UpdatesContext() async throws {
        _ = try await service.openOrCreateWorkFolder(at: tempDir)

        let context = try service.updateWorkFolderContext("New context", at: tempDir, activeTask: nil)
        XCTAssertEqual(context.workFolder.settings.context, "New context")
    }

    func testUpdateWorkFolderContext_TrimsWhitespace() async throws {
        _ = try await service.openOrCreateWorkFolder(at: tempDir)

        let context = try service.updateWorkFolderContext("  Trimmed  \n", at: tempDir, activeTask: nil)
        XCTAssertEqual(context.workFolder.settings.context, "Trimmed")
    }

    func testUpdateWorkFolderContext_EmptyString() async throws {
        _ = try await service.openOrCreateWorkFolder(at: tempDir)

        let context = try service.updateWorkFolderContext("", at: tempDir, activeTask: nil)
        XCTAssertEqual(context.workFolder.settings.context, "")
    }

    // MARK: - updateSelectedScheme

    func testUpdateSelectedScheme_SetsScheme() async throws {
        _ = try await service.openOrCreateWorkFolder(at: tempDir)

        let context = try service.updateSelectedScheme("NanoTeams", at: tempDir, activeTask: nil)
        XCTAssertEqual(context.workFolder.settings.selectedScheme, "NanoTeams")
    }

    func testUpdateSelectedScheme_ClearsScheme() async throws {
        _ = try await service.openOrCreateWorkFolder(at: tempDir)

        let context = try service.updateSelectedScheme(nil, at: tempDir, activeTask: nil)
        XCTAssertNil(context.workFolder.settings.selectedScheme)
    }

    // MARK: - fetchAvailableSchemes

    func testFetchAvailableSchemes_ReturnsEmptyForNonXcodeProject() async {
        let schemes = await service.fetchAvailableSchemes(workFolderRoot: tempDir)
        // No Xcode project in temp dir — should return empty
        XCTAssertTrue(schemes.isEmpty)
    }

    // MARK: - Round-trip Persistence

    func testRoundTrip_ContextPersistsAcrossOpens() async throws {
        _ = try await service.openOrCreateWorkFolder(at: tempDir)
        _ = try service.updateWorkFolderContext("Persisted context", at: tempDir, activeTask: nil)

        // Use fresh service to simulate fresh open
        let context2 = try await freshService.openOrCreateWorkFolder(at: tempDir)
        XCTAssertEqual(context2.workFolder.settings.context, "Persisted context")
    }

    func testRoundTrip_SchemePersistsAcrossOpens() async throws {
        _ = try await service.openOrCreateWorkFolder(at: tempDir)
        _ = try service.updateSelectedScheme("MyScheme", at: tempDir, activeTask: nil)

        // Use fresh service to simulate fresh open
        let context2 = try await freshService.openOrCreateWorkFolder(at: tempDir)
        XCTAssertEqual(context2.workFolder.settings.selectedScheme, "MyScheme")
    }

    // MARK: - Reset Produces New Identity

    /// Validates the fix for draft state sync after reset.
    /// When .nanoteams is deleted and re-created (simulating "Reset All Application Settings"),
    /// the new WorkFolder must have a different `id` even though `contextPrompt` stays
    /// at the same default value. This ensures `onChange(of: workFolder.id)` fires in the view,
    /// re-syncing @State drafts — whereas `onChange(of: contextPrompt)` would NOT fire
    /// because the value is identical.
    func testResetProducesNewIdentity_WithSameDefaultPrompt() async throws {
        let contextBefore = try await service.openOrCreateWorkFolder(at: tempDir)
        let idBefore = contextBefore.workFolder.id
        let promptBefore = contextBefore.workFolder.settings.contextPrompt

        // Simulate reset: delete .nanoteams and re-create
        let nanoteamsDir = tempDir.appendingPathComponent(".nanoteams")
        try fileManager.removeItem(at: nanoteamsDir)

        let contextAfter = try await service.openOrCreateWorkFolder(at: tempDir)
        let idAfter = contextAfter.workFolder.id
        let promptAfter = contextAfter.workFolder.settings.contextPrompt

        // ID must change — this is what triggers onChange(of: id) in the view
        XCTAssertNotEqual(idBefore, idAfter, "Reset must produce a new WorkFolder identity")

        // contextPrompt stays the same default — onChange(of: contextPrompt) would NOT fire
        XCTAssertEqual(promptBefore, promptAfter, "Both should have the same default prompt")
        XCTAssertEqual(promptAfter, AppDefaults.workFolderContextPrompt)
    }
}
