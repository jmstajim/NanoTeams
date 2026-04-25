import XCTest
import Observation
@testable import NanoTeams

/// Mutable reference cell for capturing observer-fired state out of a
/// `withObservationTracking { ... } onChange: { ... }` closure. `@unchecked
/// Sendable` is safe here because the test thread-joins via `await` before
/// reading `.value`.
private final class UncheckedBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// End-to-end user scenarios for the expanded-search lifecycle — covers the
/// flow a user actually touches via the Advanced settings tab:
/// 1. Toggle on → coordinator spins up, watcher starts, index lands on disk.
/// 2. Toggle off → coordinator torn down, on-disk file deleted.
/// 3. Folder close/reopen → index persists on disk, reuses cache on reopen.
/// 4. Rebuild button → forces a full rebuild.
/// 5. Schema stays stable regardless of toggle state.
///
/// Corner cases covered here:
/// - Toggling while no work folder is open (coordinator must be nil).
/// - Toggling rapidly on/off/on (no orphaned coordinators or FS watchers).
/// - `awaitSearchIndex` returns nil when the feature is off.
/// - Closing a folder with the feature on tears down the coordinator.
/// - `onExpandedSearchSettingChanged` is idempotent when state matches.
@MainActor
final class ExpandedSearchUserScenarioTests: NTMSOrchestratorTestBase {

    // MARK: - Toggle ON — happy path

    func testToggleOn_withFolderOpen_spawnsCoordinator() async {
        await sut.openWorkFolder(tempDir)
        XCTAssertNil(sut.searchIndexCoordinator, "Feature off → no coordinator")

        sut.configuration.expandedSearchEnabled = true
        await sut.onExpandedSearchSettingChanged()

        XCTAssertNotNil(sut.searchIndexCoordinator, "Feature on → coordinator exists")
    }

    func testToggleOn_withFolderOpen_indexLandsOnDisk() async throws {
        // Drop a recognizable token in the folder so we can verify it got indexed.
        let file = tempDir.appendingPathComponent("ScrollView.swift")
        try "class ScrollView { func makeScrollView() {} }".write(
            to: file, atomically: true, encoding: .utf8
        )

        await sut.openWorkFolder(tempDir)
        sut.configuration.expandedSearchEnabled = true
        await sut.onExpandedSearchSettingChanged()

        // Give the initial ensure-fresh pass a moment.
        let index = await sut.searchIndexCoordinator?.awaitIndex()
        XCTAssertNotNil(index)
        XCTAssertTrue(index?.tokens.contains("scrollview") ?? false)

        let indexFile = tempDir
            .appendingPathComponent(".nanoteams/internal/search_index.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexFile.path),
                      "Index file must be persisted on disk after build.")
    }

    // MARK: - Toggle OFF — teardown

    func testToggleOff_deletesOnDiskIndex() async throws {
        let file = tempDir.appendingPathComponent("a.swift")
        try "alpha beta".write(to: file, atomically: true, encoding: .utf8)

        await sut.openWorkFolder(tempDir)
        sut.configuration.expandedSearchEnabled = true
        await sut.onExpandedSearchSettingChanged()
        _ = await sut.searchIndexCoordinator?.awaitIndex()

        let indexFile = tempDir
            .appendingPathComponent(".nanoteams/internal/search_index.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexFile.path))

        // Flip off.
        sut.configuration.expandedSearchEnabled = false
        await sut.onExpandedSearchSettingChanged()

        XCTAssertNil(sut.searchIndexCoordinator)
        XCTAssertFalse(FileManager.default.fileExists(atPath: indexFile.path),
                       "search_index.json must be removed after disable.")
    }

    // MARK: - Corner: No folder open

    func testToggleOn_noFolderOpen_coordinatorStaysNil() async {
        XCTAssertNil(sut.workFolderURL)
        sut.configuration.expandedSearchEnabled = true
        await sut.onExpandedSearchSettingChanged()
        XCTAssertNil(sut.searchIndexCoordinator,
                     "Without a folder we cannot index — coordinator must stay nil.")
    }

    func testToggleOn_noFolder_thenOpenFolder_spawnsCoordinatorOnOpen() async {
        // Pre-enable with no folder → no coordinator.
        sut.configuration.expandedSearchEnabled = true
        await sut.onExpandedSearchSettingChanged()
        XCTAssertNil(sut.searchIndexCoordinator)

        // Open a folder → coordinator should materialize.
        await sut.openWorkFolder(tempDir)
        XCTAssertNotNil(sut.searchIndexCoordinator,
                        "Opening a folder with the flag on must spawn the coordinator.")
    }

    // MARK: - Corner: Default storage

    /// Regression: enabling expanded search while on default internal storage
    /// silently did nothing (`setUpSearchIndexCoordinatorIfEnabled` guards on
    /// `hasRealWorkFolder`). The toggle would read ON, the status card
    /// would still read "disabled", and the user had no signal explaining
    /// the contradiction. The hook now surfaces an info message instead.
    func testToggleOn_defaultStorage_surfacesInfoMessage() async {
        // Simulate being on default internal storage without touching the
        // real Application Support folder: set `workFolderURL` directly to
        // the path that `hasRealWorkFolder` compares against.
        sut.workFolderURL = NTMSOrchestrator.defaultStorageURL

        sut.configuration.expandedSearchEnabled = true
        await sut.onExpandedSearchSettingChanged()

        XCTAssertNil(sut.searchIndexCoordinator,
                     "Default storage must not spawn a coordinator.")
        XCTAssertNotNil(sut.lastInfoMessage,
                        "User must get a signal that the toggle is a no-op here.")
        XCTAssertTrue(
            sut.lastInfoMessage?.contains("project folder") ?? false,
            "Info copy should reference the project-folder requirement."
        )
    }

    // MARK: - Corner: Rapid toggle

    func testRapidToggle_doesNotOrphanCoordinators() async {
        await sut.openWorkFolder(tempDir)
        for _ in 0..<3 {
            sut.configuration.expandedSearchEnabled = true
            await sut.onExpandedSearchSettingChanged()
            sut.configuration.expandedSearchEnabled = false
            await sut.onExpandedSearchSettingChanged()
        }
        XCTAssertNil(sut.searchIndexCoordinator,
                     "After N on/off cycles the coordinator must be nil.")
        let indexFile = tempDir
            .appendingPathComponent(".nanoteams/internal/search_index.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: indexFile.path))
    }

    func testToggleOn_whenAlreadyOn_isIdempotent() async {
        await sut.openWorkFolder(tempDir)
        sut.configuration.expandedSearchEnabled = true
        await sut.onExpandedSearchSettingChanged()
        let first = sut.searchIndexCoordinator

        // Calling the hook again without flipping state should not replace
        // the coordinator (avoids orphaned FS watchers).
        await sut.onExpandedSearchSettingChanged()
        XCTAssertTrue(sut.searchIndexCoordinator === first,
                      "Redundant enable must NOT replace the existing coordinator.")
    }

    func testToggleOff_whenAlreadyOff_isSafe() async {
        await sut.openWorkFolder(tempDir)
        // Double-off from initial state — should not crash or leak.
        await sut.onExpandedSearchSettingChanged()
        await sut.onExpandedSearchSettingChanged()
        XCTAssertNil(sut.searchIndexCoordinator)
    }

    // MARK: - B5: setUp is idempotent at the entry point

    // MARK: - I3: rapid-toggle via detached tasks respects click order

    /// Simulates the real UI path where `ExpandedSearchToggleCard.onChanged`
    /// wraps the orchestrator call in `Task { await ... }`. Three rapid
    /// clicks (on → off → on) without inline `await` can interleave inside
    /// `onExpandedSearchSettingChanged`. A serial task chain keeps the effects
    /// in click order so the final state matches the last toggle.
    func testRapidToggle_viaDetachedTasks_finalStateMatchesLastClick() async {
        await sut.openWorkFolder(tempDir)

        // Each mutation of `expandedSearchEnabled` + spawn mirrors one click.
        sut.configuration.expandedSearchEnabled = true
        let t1 = Task { await sut.onExpandedSearchSettingChanged() }
        sut.configuration.expandedSearchEnabled = false
        let t2 = Task { await sut.onExpandedSearchSettingChanged() }
        sut.configuration.expandedSearchEnabled = true
        let t3 = Task { await sut.onExpandedSearchSettingChanged() }

        await t1.value
        await t2.value
        await t3.value

        XCTAssertEqual(sut.configuration.expandedSearchEnabled, true)
        XCTAssertNotNil(sut.searchIndexCoordinator,
            "After on → off → on, the final state must be ON with a live coordinator.")
    }

    // MARK: - Regression: searchIndexCoordinator must be observable by views

    /// User bug: "пропали индикаторы индексирования" / "включил, он пишет что
    /// всё отключено". Views (`AdvancedSettingsView`, `SidebarWorkFolderCards`)
    /// read `store.searchIndexCoordinator` and `store.searchIndexCoordinator?.isBuilding`
    /// directly from the orchestrator's `@Observable` surface. Marking the
    /// property `@ObservationIgnored` freezes them at their initial nil
    /// snapshot so enabling the toggle can't refresh the cards.
    ///
    /// `withObservationTracking` fires `onChange` exactly once when any
    /// tracked property is mutated — so if we access `searchIndexCoordinator`
    /// inside the tracking closure and then mutate it, the hook must fire.
    /// `@ObservationIgnored` silences that hook.
    func testSearchIndexCoordinator_isObservableByViews() async {
        await sut.openWorkFolder(tempDir)

        let observationFired = UncheckedBox<Bool>(false)
        withObservationTracking {
            _ = sut.searchIndexCoordinator
        } onChange: {
            observationFired.value = true
        }

        // Mutate — this must notify the tracked observer. A test coordinator
        // construction here is fine; we only care that the assignment is
        // visible to Observation.
        sut.searchIndexCoordinator = SearchIndexCoordinator(
            workFolderRoot: tempDir,
            internalDir: tempDir.appendingPathComponent(".nanoteams/internal"),
            fileManager: FileManager.default
        )
        // `onChange` fires synchronously in willSet-like fashion, but yield
        // once so any Task-scheduled observer has a chance to run.
        await Task.yield()

        XCTAssertTrue(observationFired.value,
            "Views that read `store.searchIndexCoordinator` must be notified on assignment. "
            + "If this fails the property has been marked @ObservationIgnored — reverting that "
            + "would freeze the Advanced settings cards at their initial nil snapshot.")
    }

    /// Direct regression for the "install race / FSEventStream leak" class:
    /// even if callers bypass `onExpandedSearchSettingChanged` and call
    /// `setUpSearchIndexCoordinatorIfEnabled` repeatedly, no new coordinator
    /// is installed when one already exists. Without this guard, the first
    /// coordinator's FSEventStream would be orphaned (still retained via the
    /// underlying Unmanaged but never `stop`ped).
    func testSetUp_calledTwice_doesNotReplaceExistingCoordinator() async {
        await sut.openWorkFolder(tempDir)
        sut.configuration.expandedSearchEnabled = true
        await sut.setUpSearchIndexCoordinatorIfEnabled()
        let first = sut.searchIndexCoordinator
        XCTAssertNotNil(first)

        await sut.setUpSearchIndexCoordinatorIfEnabled()
        XCTAssertTrue(sut.searchIndexCoordinator === first,
            "Second setUp must not install a second coordinator.")
    }

    // MARK: - Folder lifecycle

    func testClosingProject_tearsDownCoordinator() async {
        await sut.openWorkFolder(tempDir)
        sut.configuration.expandedSearchEnabled = true
        await sut.onExpandedSearchSettingChanged()
        XCTAssertNotNil(sut.searchIndexCoordinator)

        await sut.closeProject()
        // After close, the coordinator is torn down but the on-disk index
        // stays in the previous folder (reopen reuses it).
        XCTAssertNil(sut.searchIndexCoordinator)
    }

    func testSwitchFolder_recreatesCoordinatorForNewFolder() async throws {
        let secondFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: secondFolder) }

        await sut.openWorkFolder(tempDir)
        sut.configuration.expandedSearchEnabled = true
        await sut.onExpandedSearchSettingChanged()
        let firstCoordinator = sut.searchIndexCoordinator
        XCTAssertNotNil(firstCoordinator)

        await sut.openWorkFolder(secondFolder)
        XCTAssertNotNil(sut.searchIndexCoordinator)
        XCTAssertFalse(sut.searchIndexCoordinator === firstCoordinator,
                       "Switching folders must install a fresh coordinator.")
        XCTAssertEqual(sut.searchIndexCoordinator?.workFolderRoot, secondFolder)
    }

    // MARK: - Rebuild + awaitIndex contract

    func testAwaitSearchIndex_returnsNilWhenDisabled() async {
        await sut.openWorkFolder(tempDir)
        XCTAssertFalse(sut.configuration.expandedSearchEnabled)
        let index = await sut.awaitSearchIndex()
        XCTAssertNil(index, "Disabled → awaitSearchIndex returns nil (signals fall back).")
    }

    func testRebuild_refreshesIndex() async throws {
        let first = tempDir.appendingPathComponent("A.swift")
        try "alpha".write(to: first, atomically: true, encoding: .utf8)

        await sut.openWorkFolder(tempDir)
        sut.configuration.expandedSearchEnabled = true
        await sut.onExpandedSearchSettingChanged()
        let firstIdx = await sut.searchIndexCoordinator?.awaitIndex()
        XCTAssertEqual(firstIdx?.files.count, 1)

        // Drop a second file and force rebuild.
        let second = tempDir.appendingPathComponent("B.swift")
        try "beta gamma".write(to: second, atomically: true, encoding: .utf8)
        await sut.searchIndexCoordinator?.rebuild()
        let secondIdx = await sut.searchIndexCoordinator?.awaitIndex()
        XCTAssertEqual(secondIdx?.files.count, 2)
        XCTAssertTrue(secondIdx?.tokens.contains("gamma") ?? false)
    }

    // MARK: - Schema stability

    func testSearchToolSchema_alwaysExposesExpand_regardlessOfToggle() {
        let schema = SearchTool.schema
        let names = Set(schema.parameters.properties?.keys ?? [:].keys)
        XCTAssertTrue(names.contains("expand"),
                      "Schema parameter list is compile-time; must not depend on runtime toggle.")
    }
}
