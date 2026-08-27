import XCTest

@testable import NanoTeams

@MainActor
final class FolderAccessManagerTests: XCTestCase, @unchecked Sendable {

    var manager: FolderAccessManager!
    private var storage: InMemoryConfigurationStorage!

    override func setUp() async throws {
        try await super.setUp()
        // The isolation this suite had been BUILDING and discarding since it was written: it
        // minted a UUID suite name and removed that persistent domain in tearDown, but never
        // constructed a `UserDefaults(suiteName:)` — the manager was built no-arg, so every
        // read and write landed in the SHARED domain that parallel workers see. `DEBTS.md` D-4.
        storage = InMemoryConfigurationStorage()
        manager = FolderAccessManager(storage: storage)
    }

    override func tearDown() async throws {
        manager = nil
        storage = nil
        try await super.tearDown()
    }

    // MARK: - Initial State Tests

    func testInitialStateHasNilProjectFolder() {
        XCTAssertNil(manager.workFolderURL)
    }

    // MARK: - Restore Tests

    func testRestoreWithNoSavedBookmarkDoesNothing() async {
        // Ensure no bookmark exists
        storage.removeObject(forKey: "NanoTeams.projectFolderBookmark.v1")

        await manager.restoreLastFolderIfPossible()

        XCTAssertNil(manager.workFolderURL)
    }

    func testRestoreWithInvalidBookmarkDataClearsStorage() async {
        // Store invalid bookmark data
        let invalidData = "not valid bookmark data".data(using: .utf8)!
        storage.set(invalidData, forKey: "NanoTeams.projectFolderBookmark.v1")

        await manager.restoreLastFolderIfPossible()

        // Should clear the invalid bookmark
        XCTAssertNil(storage.data(forKey: "NanoTeams.projectFolderBookmark.v1"))
        XCTAssertNil(manager.workFolderURL)
    }

    func testRestoreWithEmptyDataClearsStorage() async {
        // Store empty data
        storage.set(Data(), forKey: "NanoTeams.projectFolderBookmark.v1")

        await manager.restoreLastFolderIfPossible()

        // Should clear the empty bookmark
        XCTAssertNil(storage.data(forKey: "NanoTeams.projectFolderBookmark.v1"))
        XCTAssertNil(manager.workFolderURL)
    }

    func testRestoreWithCorruptedBookmarkClearsStorage() async {
        // Store corrupted bookmark data (random bytes)
        let corruptedData = Data([0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE, 0xFD])
        storage.set(corruptedData, forKey: "NanoTeams.projectFolderBookmark.v1")

        await manager.restoreLastFolderIfPossible()

        // Should clear the corrupted bookmark
        XCTAssertNil(storage.data(forKey: "NanoTeams.projectFolderBookmark.v1"))
        XCTAssertNil(manager.workFolderURL)
    }

    // MARK: - Published Property Tests

    func testProjectFolderURLIsPublished() {
        // Verify the property exists and is accessible
        let url = manager.workFolderURL
        XCTAssertNil(url, "Initial state should be nil")
    }

    // MARK: - Bookmark Key Tests

    func testBookmarkKeyIsVersioned() {
        // The key should be versioned to allow future migrations
        let key = "NanoTeams.projectFolderBookmark.v1"

        // Store something with the key
        storage.set(Data([0x01]), forKey: key)

        // Verify it's stored
        XCTAssertNotNil(storage.data(forKey: key))

        // Clean up
        storage.removeObject(forKey: key)
    }

    // MARK: - Multiple Restore Attempts

    func testMultipleRestoreAttemptsWithNoBookmark() async {
        storage.removeObject(forKey: "NanoTeams.projectFolderBookmark.v1")

        // Multiple restore attempts should be safe
        await manager.restoreLastFolderIfPossible()
        await manager.restoreLastFolderIfPossible()
        await manager.restoreLastFolderIfPossible()

        XCTAssertNil(manager.workFolderURL)
    }

    // MARK: - Manager Lifecycle Tests

    func testNewManagerInstanceHasIndependentState() {
        let manager1 = FolderAccessManager(storage: storage)
        let manager2 = FolderAccessManager(storage: storage)

        XCTAssertNil(manager1.workFolderURL)
        XCTAssertNil(manager2.workFolderURL)
    }

    // MARK: - Concurrent Access Safety

    func testRestoreCanBeCalledConcurrently() async {
        storage.removeObject(forKey: "NanoTeams.projectFolderBookmark.v1")

        // Call restore from multiple tasks
        let captured = manager!
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    await captured.restoreLastFolderIfPossible()
                }
            }
        }

        // Should complete without crash
        XCTAssertNil(manager.workFolderURL)
    }
}

// MARK: - Integration Tests with Temporary Directory

@MainActor
final class FolderAccessManagerIntegrationTests: XCTestCase {

    var manager: FolderAccessManager!
    var tempDir: URL!
    private var storage: InMemoryConfigurationStorage!

    override func setUp() async throws {
        try await super.setUp()
        storage = InMemoryConfigurationStorage()
        manager = FolderAccessManager(storage: storage)

        // Create a temporary directory for testing
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderAccessManagerTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Clear any existing bookmark
        storage.removeObject(forKey: "NanoTeams.projectFolderBookmark.v1")
    }

    override func tearDown() async throws {
        manager = nil
        // The store is per-test and dies with the class — there is no shared key left to
        // clear, which is the point of injecting it. (An earlier draft nil'd `storage` here
        // and then called `removeObject` on it, crashing the worker.)
        storage = nil
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try await super.tearDown()
    }

    // MARK: - Bookmark Persistence Flow Tests

    func testRestoreAfterInvalidBookmarkLeavesManagerClean() async {
        // Simulate a scenario where a previously valid bookmark becomes invalid
        // (e.g., folder was deleted)
        let invalidData = "simulated-stale-bookmark".data(using: .utf8)!
        storage.set(invalidData, forKey: "NanoTeams.projectFolderBookmark.v1")

        await manager.restoreLastFolderIfPossible()

        // Manager should be in a clean state
        XCTAssertNil(manager.workFolderURL)
        // Invalid bookmark should be cleared
        XCTAssertNil(storage.data(forKey: "NanoTeams.projectFolderBookmark.v1"))
    }

    // MARK: - State Consistency Tests

    func testManagerStateAfterFailedRestore() async {
        // Store invalid data
        storage.set(Data([0xFF, 0xFE]), forKey: "NanoTeams.projectFolderBookmark.v1")

        await manager.restoreLastFolderIfPossible()

        // State should be consistent
        XCTAssertNil(manager.workFolderURL, "URL should be nil after failed restore")

        // A second restore attempt should also work
        await manager.restoreLastFolderIfPossible()
        XCTAssertNil(manager.workFolderURL, "URL should still be nil")
    }

    // MARK: - UserDefaults Interaction Tests

    func testBookmarkDataTypeIsData() {
        // Store valid bookmark format (even if content is invalid)
        let testData = Data([0x62, 0x6F, 0x6F, 0x6B]) // "book" in ASCII
        storage.set(testData, forKey: "NanoTeams.projectFolderBookmark.v1")

        let retrieved = storage.data(forKey: "NanoTeams.projectFolderBookmark.v1")
        XCTAssertEqual(retrieved, testData)
    }

    func testBookmarkKeyDoesNotConflictWithOtherKeys() {
        // Store some other data in UserDefaults
        storage.set("test", forKey: "NanoTeams.someOtherKey")
        storage.set(Data([0x01]), forKey: "NanoTeams.projectFolderBookmark.v1")

        // Both should coexist
        XCTAssertEqual(storage.string(forKey: "NanoTeams.someOtherKey"), "test")
        XCTAssertNotNil(storage.data(forKey: "NanoTeams.projectFolderBookmark.v1"))

        // Cleanup
        storage.removeObject(forKey: "NanoTeams.someOtherKey")
    }
}
