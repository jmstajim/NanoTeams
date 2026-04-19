import XCTest
@testable import NanoTeams

/// Tests for AtomicJSONStore persistence layer
final class AtomicJSONStoreTests: XCTestCase {

    private var tempDir: URL!
    private var store: AtomicJSONStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = AtomicJSONStore()
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Test Data Types

    private struct TestModel: Codable, Equatable {
        let id: UUID
        let name: String
        let count: Int
        let createdAt: Date
    }

    private struct NestedModel: Codable, Equatable {
        let items: [TestModel]
        let metadata: [String: String]
    }

    // MARK: - Write and Read Tests

    func testWriteAndRead() throws {
        let testURL = tempDir.appendingPathComponent("test.json")
        let model = TestModel(
            id: UUID(),
            name: "Test Item",
            count: 42,
            createdAt: Date()
        )

        try store.write(model, to: testURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: testURL.path))

        let loaded = try store.read(TestModel.self, from: testURL)
        XCTAssertEqual(loaded.id, model.id)
        XCTAssertEqual(loaded.name, model.name)
        XCTAssertEqual(loaded.count, model.count)
        // Date precision may differ slightly due to ISO8601 encoding
        XCTAssertEqual(loaded.createdAt.timeIntervalSince1970, model.createdAt.timeIntervalSince1970, accuracy: 1)
    }

    func testWriteCreatesIntermediateDirectories() throws {
        let nestedURL = tempDir
            .appendingPathComponent("level1", isDirectory: true)
            .appendingPathComponent("level2", isDirectory: true)
            .appendingPathComponent("test.json", isDirectory: false)

        let model = TestModel(id: UUID(), name: "Nested", count: 1, createdAt: Date())

        try store.write(model, to: nestedURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedURL.path))
        let loaded = try store.read(TestModel.self, from: nestedURL)
        XCTAssertEqual(loaded.name, "Nested")
    }

    func testWriteOverwritesExistingFile() throws {
        let testURL = tempDir.appendingPathComponent("overwrite.json")

        let original = TestModel(id: UUID(), name: "Original", count: 1, createdAt: Date())
        try store.write(original, to: testURL)

        let updated = TestModel(id: original.id, name: "Updated", count: 2, createdAt: Date())
        try store.write(updated, to: testURL)

        let loaded = try store.read(TestModel.self, from: testURL)
        XCTAssertEqual(loaded.name, "Updated")
        XCTAssertEqual(loaded.count, 2)
    }

    func testWriteComplexModel() throws {
        let testURL = tempDir.appendingPathComponent("nested.json")
        let model = NestedModel(
            items: [
                TestModel(id: UUID(), name: "Item 1", count: 1, createdAt: Date()),
                TestModel(id: UUID(), name: "Item 2", count: 2, createdAt: Date())
            ],
            metadata: ["key1": "value1", "key2": "value2"]
        )

        try store.write(model, to: testURL)

        let loaded = try store.read(NestedModel.self, from: testURL)
        XCTAssertEqual(loaded.items.count, 2)
        XCTAssertEqual(loaded.metadata["key1"], "value1")
    }

    // MARK: - writeIfMissing Tests

    func testWriteIfMissingCreatesNewFile() throws {
        let testURL = tempDir.appendingPathComponent("conditional.json")
        let model = TestModel(id: UUID(), name: "New", count: 1, createdAt: Date())

        try store.writeIfMissing(model, to: testURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: testURL.path))
        let loaded = try store.read(TestModel.self, from: testURL)
        XCTAssertEqual(loaded.name, "New")
    }

    func testWriteIfMissingDoesNotOverwrite() throws {
        let testURL = tempDir.appendingPathComponent("donotoverwrite.json")

        let original = TestModel(id: UUID(), name: "Original", count: 1, createdAt: Date())
        try store.write(original, to: testURL)

        let replacement = TestModel(id: UUID(), name: "Replacement", count: 99, createdAt: Date())
        try store.writeIfMissing(replacement, to: testURL)

        let loaded = try store.read(TestModel.self, from: testURL)
        XCTAssertEqual(loaded.name, "Original")
        XCTAssertEqual(loaded.count, 1)
    }

    // MARK: - Read Error Tests

    func testReadNonExistentFile() {
        let testURL = tempDir.appendingPathComponent("nonexistent.json")

        XCTAssertThrowsError(try store.read(TestModel.self, from: testURL))
    }

    func testReadInvalidJSON() throws {
        let testURL = tempDir.appendingPathComponent("invalid.json")
        try "not valid json".write(to: testURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try store.read(TestModel.self, from: testURL))
    }

    func testReadWrongType() throws {
        let testURL = tempDir.appendingPathComponent("wrongtype.json")
        let model = TestModel(id: UUID(), name: "Test", count: 1, createdAt: Date())
        try store.write(model, to: testURL)

        // Try to read as NestedModel
        XCTAssertThrowsError(try store.read(NestedModel.self, from: testURL))
    }

    // MARK: - JSON Format Tests

    func testJSONIsPrettyPrinted() throws {
        let testURL = tempDir.appendingPathComponent("pretty.json")
        let model = TestModel(id: UUID(), name: "Test", count: 1, createdAt: Date())

        try store.write(model, to: testURL)

        let content = try String(contentsOf: testURL, encoding: .utf8)
        // Pretty printed JSON should have newlines
        XCTAssertTrue(content.contains("\n"))
    }

    func testJSONKeysAreSorted() throws {
        let testURL = tempDir.appendingPathComponent("sorted.json")
        let model = TestModel(id: UUID(), name: "Test", count: 1, createdAt: Date())

        try store.write(model, to: testURL)

        let content = try String(contentsOf: testURL, encoding: .utf8)
        // Keys should appear in alphabetical order: count, createdAt, id, name
        let countPos = content.range(of: "\"count\"")!.lowerBound
        let createdAtPos = content.range(of: "\"createdAt\"")!.lowerBound
        let idPos = content.range(of: "\"id\"")!.lowerBound
        let namePos = content.range(of: "\"name\"")!.lowerBound

        XCTAssertLessThan(countPos, createdAtPos)
        XCTAssertLessThan(createdAtPos, idPos)
        XCTAssertLessThan(idPos, namePos)
    }

    func testJSONUsesISO8601Dates() throws {
        let testURL = tempDir.appendingPathComponent("dates.json")
        let model = TestModel(id: UUID(), name: "Test", count: 1, createdAt: Date())

        try store.write(model, to: testURL)

        let content = try String(contentsOf: testURL, encoding: .utf8)
        // ISO8601 dates contain "T" separator
        XCTAssertTrue(content.contains("T"))
    }

    // MARK: - Error Description Tests

    func testUnableToCreateDirectoryError() {
        let url = URL(fileURLWithPath: "/test/dir")
        let error = AtomicJSONStoreError.unableToCreateDirectory(url)
        XCTAssertEqual(error.errorDescription, "Unable to create directory: /test/dir")
    }

    func testAtomicReplaceFailedError() {
        let url = URL(fileURLWithPath: "/test/file.json")
        let underlying = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Permission denied"])
        let error = AtomicJSONStoreError.atomicReplaceFailed(url, underlying: underlying)

        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("file.json"))
        XCTAssertTrue(description.contains("Permission denied"))
    }

    // MARK: - Concurrent Write Tests

    func testConcurrentWrites() async throws {
        let testURL = tempDir.appendingPathComponent("concurrent.json")

        // Perform multiple concurrent writes
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let model = TestModel(id: UUID(), name: "Writer \(i)", count: i, createdAt: Date())
                    try? self.store.write(model, to: testURL)
                }
            }
        }

        // File should still be valid JSON after concurrent writes
        let loaded = try store.read(TestModel.self, from: testURL)
        XCTAssertFalse(loaded.name.isEmpty)
    }

    // MARK: - Array and Dictionary Tests

    func testWriteAndReadArray() throws {
        let testURL = tempDir.appendingPathComponent("array.json")
        let models = [
            TestModel(id: UUID(), name: "Item 1", count: 1, createdAt: Date()),
            TestModel(id: UUID(), name: "Item 2", count: 2, createdAt: Date()),
            TestModel(id: UUID(), name: "Item 3", count: 3, createdAt: Date())
        ]

        try store.write(models, to: testURL)

        let loaded = try store.read([TestModel].self, from: testURL)
        XCTAssertEqual(loaded.count, 3)
        XCTAssertEqual(loaded[0].name, "Item 1")
        XCTAssertEqual(loaded[2].count, 3)
    }

    func testWriteAndReadEmptyArray() throws {
        let testURL = tempDir.appendingPathComponent("empty_array.json")
        let models: [TestModel] = []

        try store.write(models, to: testURL)

        let loaded = try store.read([TestModel].self, from: testURL)
        XCTAssertTrue(loaded.isEmpty)
    }

    // MARK: - Domain Model Tests

    func testWriteAndReadNTMSTask() throws {
        let testURL = tempDir.appendingPathComponent("task.json")
        let task = NTMSTask(id: 0, title: "Test Task",
            supervisorTask: "Build something",
            status: .running,
            runs: [
                Run(id: 0, steps: [
                    StepExecution(id: "test_step", role: .productManager, title: "PO Step", status: .done)
                ])
            ]
        )

        try store.write(task, to: testURL)

        let loaded = try store.read(NTMSTask.self, from: testURL)
        XCTAssertEqual(loaded.title, task.title)
        XCTAssertEqual(loaded.supervisorTask, task.supervisorTask)
        XCTAssertEqual(loaded.runs.count, 1)
        XCTAssertEqual(loaded.runs[0].steps.count, 1)
    }

    func testWriteAndReadWorkFolderState() throws {
        let testURL = tempDir.appendingPathComponent("workfolder.json")
        let state = WorkFolderState(
            name: "TestProject",
            activeTaskID: Int()
        )

        try store.write(state, to: testURL)

        let loaded = try store.read(WorkFolderState.self, from: testURL)
        XCTAssertEqual(loaded.name, state.name)
        XCTAssertEqual(loaded.activeTaskID, state.activeTaskID)
        XCTAssertEqual(loaded.schemaVersion, 6)
    }

    func testWriteAndReadProjectSettings() throws {
        let testURL = tempDir.appendingPathComponent("settings.json")
        let settings = ProjectSettings(
            description: "Desc",
            descriptionPrompt: "Prompt",
            selectedScheme: "MyScheme"
        )

        try store.write(settings, to: testURL)

        let loaded = try store.read(ProjectSettings.self, from: testURL)
        XCTAssertEqual(loaded.description, "Desc")
        XCTAssertEqual(loaded.descriptionPrompt, "Prompt")
        XCTAssertEqual(loaded.selectedScheme, "MyScheme")
        XCTAssertEqual(loaded.schemaVersion, 1)
    }

    func testWriteAndReadTeamsFile() throws {
        let testURL = tempDir.appendingPathComponent("teams.json")
        let team = Team(name: "Test Team")
        let teamsFile = TeamsFile(teams: [team])

        try store.write(teamsFile, to: testURL)

        let loaded = try store.read(TeamsFile.self, from: testURL)
        XCTAssertEqual(loaded.teams.count, 1)
        XCTAssertEqual(loaded.teams[0].name, "Test Team")
        XCTAssertEqual(loaded.schemaVersion, 1)
    }
}
