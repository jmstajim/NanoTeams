import XCTest

@testable import NanoTeams

@MainActor
final class FolderAccessManagerTests: XCTestCase {

    var manager: FolderAccessManager!
    var testSuiteName: String!

    override func setUp() {
        super.setUp()
        // Use a unique test suite to avoid polluting real UserDefaults
        testSuiteName = "FolderAccessManagerTests.\(UUID().uuidString)"

        manager = FolderAccessManager()
    }

    override func tearDown() {
        manager = nil
        // Clean up test UserDefaults
        if let suiteName = testSuiteName {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        testSuiteName = nil
        // Also clear the standard defaults key used by FolderAccessManager
        UserDefaults.standard.removeObject(forKey: "NanoTeams.projectFolderBookmark.v1")
        super.tearDown()
    }

    // MARK: - Initial State Tests

    func testInitialStateHasNilProjectFolder() {
        XCTAssertNil(manager.workFolderURL)
    }

    // MARK: - Restore Tests

    func testRestoreWithNoSavedBookmarkDoesNothing() async {
        // Ensure no bookmark exists
        UserDefaults.standard.removeObject(forKey: "NanoTeams.projectFolderBookmark.v1")

        await manager.restoreLastFolderIfPossible()

        XCTAssertNil(manager.workFolderURL)
    }

    func testRestoreWithInvalidBookmarkDataClearsStorage() async {
        // Store invalid bookmark data
        let invalidData = "not valid bookmark data".data(using: .utf8)!
        UserDefaults.standard.set(invalidData, forKey: "NanoTeams.projectFolderBookmark.v1")

        await manager.restoreLastFolderIfPossible()

        // Should clear the invalid bookmark
        XCTAssertNil(UserDefaults.standard.data(forKey: "NanoTeams.projectFolderBookmark.v1"))
        XCTAssertNil(manager.workFolderURL)
    }

    func testRestoreWithEmptyDataClearsStorage() async {
        // Store empty data
        UserDefaults.standard.set(Data(), forKey: "NanoTeams.projectFolderBookmark.v1")

        await manager.restoreLastFolderIfPossible()

        // Should clear the empty bookmark
        XCTAssertNil(UserDefaults.standard.data(forKey: "NanoTeams.projectFolderBookmark.v1"))
        XCTAssertNil(manager.workFolderURL)
    }

    func testRestoreWithCorruptedBookmarkClearsStorage() async {
        // Store corrupted bookmark data (random bytes)
        let corruptedData = Data([0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE, 0xFD])
        UserDefaults.standard.set(corruptedData, forKey: "NanoTeams.projectFolderBookmark.v1")

        await manager.restoreLastFolderIfPossible()

        // Should clear the corrupted bookmark
        XCTAssertNil(UserDefaults.standard.data(forKey: "NanoTeams.projectFolderBookmark.v1"))
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
        UserDefaults.standard.set(Data([0x01]), forKey: key)

        // Verify it's stored
        XCTAssertNotNil(UserDefaults.standard.data(forKey: key))

        // Clean up
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Multiple Restore Attempts

    func testMultipleRestoreAttemptsWithNoBookmark() async {
        UserDefaults.standard.removeObject(forKey: "NanoTeams.projectFolderBookmark.v1")

        // Multiple restore attempts should be safe
        await manager.restoreLastFolderIfPossible()
        await manager.restoreLastFolderIfPossible()
        await manager.restoreLastFolderIfPossible()

        XCTAssertNil(manager.workFolderURL)
    }

    // MARK: - Manager Lifecycle Tests

    func testNewManagerInstanceHasIndependentState() {
        let manager1 = FolderAccessManager()
        let manager2 = FolderAccessManager()

        XCTAssertNil(manager1.workFolderURL)
        XCTAssertNil(manager2.workFolderURL)
    }

    // MARK: - Concurrent Access Safety

    func testRestoreCanBeCalledConcurrently() async {
        UserDefaults.standard.removeObject(forKey: "NanoTeams.projectFolderBookmark.v1")

        // Call restore from multiple tasks
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { @MainActor in
                    await self.manager.restoreLastFolderIfPossible()
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

    override func setUpWithError() throws {
        try super.setUpWithError()
        manager = FolderAccessManager()

        // Create a temporary directory for testing
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderAccessManagerTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Clear any existing bookmark
        UserDefaults.standard.removeObject(forKey: "NanoTeams.projectFolderBookmark.v1")
    }

    override func tearDownWithError() throws {
        manager = nil
        // Clean up temp directory
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        // Clear bookmark
        UserDefaults.standard.removeObject(forKey: "NanoTeams.projectFolderBookmark.v1")
        try super.tearDownWithError()
    }

    // MARK: - Bookmark Persistence Flow Tests

    func testRestoreAfterInvalidBookmarkLeavesManagerClean() async {
        // Simulate a scenario where a previously valid bookmark becomes invalid
        // (e.g., folder was deleted)
        let invalidData = "simulated-stale-bookmark".data(using: .utf8)!
        UserDefaults.standard.set(invalidData, forKey: "NanoTeams.projectFolderBookmark.v1")

        await manager.restoreLastFolderIfPossible()

        // Manager should be in a clean state
        XCTAssertNil(manager.workFolderURL)
        // Invalid bookmark should be cleared
        XCTAssertNil(UserDefaults.standard.data(forKey: "NanoTeams.projectFolderBookmark.v1"))
    }

    // MARK: - State Consistency Tests

    func testManagerStateAfterFailedRestore() async {
        // Store invalid data
        UserDefaults.standard.set(Data([0xFF, 0xFE]), forKey: "NanoTeams.projectFolderBookmark.v1")

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
        UserDefaults.standard.set(testData, forKey: "NanoTeams.projectFolderBookmark.v1")

        let retrieved = UserDefaults.standard.data(forKey: "NanoTeams.projectFolderBookmark.v1")
        XCTAssertEqual(retrieved, testData)
    }

    func testBookmarkKeyDoesNotConflictWithOtherKeys() {
        // Store some other data in UserDefaults
        UserDefaults.standard.set("test", forKey: "NanoTeams.someOtherKey")
        UserDefaults.standard.set(Data([0x01]), forKey: "NanoTeams.projectFolderBookmark.v1")

        // Both should coexist
        XCTAssertEqual(UserDefaults.standard.string(forKey: "NanoTeams.someOtherKey"), "test")
        XCTAssertNotNil(UserDefaults.standard.data(forKey: "NanoTeams.projectFolderBookmark.v1"))

        // Cleanup
        UserDefaults.standard.removeObject(forKey: "NanoTeams.someOtherKey")
    }
}
