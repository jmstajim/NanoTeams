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
    /// всё отключено". Views (`ExpandedSearchSettingsView`, `SidebarWorkFolderCards`)
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

    // MARK: - Embedding model lifecycle (auto load/unload)

    func testToggleOn_inRealFolder_loadsEmbeddingModel() async {
        await sut.openWorkFolder(tempDir)
        XCTAssertTrue(embeddingClient.loadUnloadCalls.isEmpty,
                      "Folder open with toggle OFF must not load anything.")

        sut.configuration.expandedSearchEnabled = true
        await sut.onExpandedSearchSettingChanged()

        let modelName = sut.configuration.effectiveEmbeddingConfig.modelName
        let baseURL = sut.configuration.effectiveEmbeddingConfig.baseURLString
        XCTAssertEqual(embeddingClient.loadUnloadCalls,
                       [.load(model: modelName, baseURL: baseURL)])
    }

    func testToggleOff_unloadsEmbeddingModel() async {
        await sut.openWorkFolder(tempDir)
        sut.configuration.expandedSearchEnabled = true
        await sut.onExpandedSearchSettingChanged()
        let baseURL = sut.configuration.effectiveEmbeddingConfig.baseURLString
        embeddingClient.calls.removeAll()

        sut.configuration.expandedSearchEnabled = false
        await sut.onExpandedSearchSettingChanged()

        XCTAssertEqual(embeddingClient.loadUnloadCalls.count, 1)
        guard case .unload(_, let url)? = embeddingClient.loadUnloadCalls.first else {
            return XCTFail("Expected unload call; got \(embeddingClient.loadUnloadCalls)")
        }
        XCTAssertEqual(url, baseURL)
    }

    func testToggleOn_onDefaultStorage_doesNotLoadEmbeddingModel() async {
        sut.workFolderURL = NTMSOrchestrator.defaultStorageURL
        sut.configuration.expandedSearchEnabled = true
        await sut.onExpandedSearchSettingChanged()

        XCTAssertTrue(embeddingClient.loadUnloadCalls.isEmpty,
                      "Default storage → no coordinator → no load.")
    }

    func testFolderSwitch_sameConfig_doesNotReloadEmbeddingModel() async throws {
        let secondFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: secondFolder) }

        await sut.openWorkFolder(tempDir)
        sut.configuration.expandedSearchEnabled = true
        await sut.onExpandedSearchSettingChanged()
        XCTAssertEqual(embeddingClient.loadUnloadCalls.count, 1, "First load on toggle ON.")
        embeddingClient.calls.removeAll()

        await sut.openWorkFolder(secondFolder)

        XCTAssertTrue(embeddingClient.loadUnloadCalls.isEmpty,
                      "Folder-to-folder switch with same embed config must NOT reload.")
    }

    func testCloseProject_unloadsEmbeddingModel() async {
        await sut.openWorkFolder(tempDir)
        sut.configuration.expandedSearchEnabled = true
        await sut.onExpandedSearchSettingChanged()
        embeddingClient.calls.removeAll()

        await sut.closeProject()

        // closeProject → openWorkFolder(defaultURL) → setUp returns early
        // (no real folder) → reconcile sees nil coordinator → unload.
        XCTAssertEqual(embeddingClient.loadUnloadCalls.count, 1)
        if case .unload = embeddingClient.loadUnloadCalls.first { /* ok */ } else {
            XCTFail("Expected unload, got \(embeddingClient.loadUnloadCalls)")
        }
    }

    func testEmbeddingConfigChange_whileEnabled_unloadsOldThenLoadsNew() async {
        await sut.openWorkFolder(tempDir)
        sut.configuration.expandedSearchEnabled = true
        await sut.onExpandedSearchSettingChanged()
        embeddingClient.calls.removeAll()

        sut.configuration.expandedSearchEmbeddingConfig = EmbeddingConfig(
            baseURLString: "http://127.0.0.1:1234",
            modelName: "different-embed-model"
        )
        await sut.onExpandedSearchEmbeddingConfigChanged()

        XCTAssertEqual(embeddingClient.loadUnloadCalls.count, 2,
                       "Config change must produce one unload + one load.")
        if case .unload = embeddingClient.loadUnloadCalls.first {} else {
            return XCTFail("First call must be unload; got \(embeddingClient.loadUnloadCalls)")
        }
        if case .load(let model, _) = embeddingClient.loadUnloadCalls.last {
            XCTAssertEqual(model, "different-embed-model")
        } else {
            XCTFail("Second call must be load; got \(embeddingClient.loadUnloadCalls)")
        }
    }

    func testEmbeddingConfigChange_whileDisabled_isNoOp() async {
        await sut.openWorkFolder(tempDir)
        // Toggle is OFF.

        sut.configuration.expandedSearchEmbeddingConfig = EmbeddingConfig(
            baseURLString: "http://127.0.0.1:1234",
            modelName: "different-model"
        )
        await sut.onExpandedSearchEmbeddingConfigChanged()

        XCTAssertTrue(embeddingClient.loadUnloadCalls.isEmpty,
                      "Embed config change while disabled must not touch the lifecycle.")
    }

    // MARK: - Embedding lifecycle: error surfaces & user feedback

    /// User enables Expanded Search while LM Studio is unreachable. The toggle
    /// should still flip ON (coordinator is created and the on-disk index can
    /// build without embeddings — vector index just lands in `modelUnavailable`),
    /// but the user must see WHY the embed model isn't ready via the
    /// red error banner. I3: the feature is now broken; info-severity is wrong.
    func testToggleOn_whenLoadFails_surfacesErrorBanner() async {
        await sut.openWorkFolder(tempDir)
        embeddingClient.loadError = TestError.boom

        sut.configuration.expandedSearchEnabled = true
        await sut.onExpandedSearchSettingChanged()

        XCTAssertNotNil(sut.searchIndexCoordinator,
                        "Coordinator must still be created — Expanded Search degrades gracefully without embeddings.")
        XCTAssertNotNil(sut.lastErrorMessage,
                        "Load failure means the feature is broken — must use red error banner, not neutral info.")
        XCTAssertTrue(
            sut.lastErrorMessage?.contains("Couldn't load embedding model") ?? false,
            "Error banner should explain the load failure (was: \(sut.lastErrorMessage ?? "<nil>"))."
        )
        XCTAssertTrue(
            sut.lastErrorMessage?.contains("keyword-only") ?? false,
            "Error banner should tell the user search degrades gracefully so they don't think the app is broken."
        )
    }

    /// I8: an unload error MUST surface as info — pre-fix it was silent,
    /// which left users wondering why VRAM stayed pinned. The native client
    /// already swallows the common `instance not found` / 404 cases, so
    /// anything reaching the orchestrator's catch is rare and worth a note.
    func testToggleOff_whenUnloadFails_surfacesInfoBanner() async {
        await sut.openWorkFolder(tempDir)
        sut.configuration.expandedSearchEnabled = true
        await sut.onExpandedSearchSettingChanged()
        sut.lastInfoMessage = nil
        sut.lastErrorMessage = nil
        embeddingClient.unloadError = TestError.boom

        sut.configuration.expandedSearchEnabled = false
        await sut.onExpandedSearchSettingChanged()

        XCTAssertNotNil(sut.lastInfoMessage,
                        "Unload error should surface as info so the user knows VRAM may not have been reclaimed.")
        XCTAssertTrue(
            sut.lastInfoMessage?.contains("unload") ?? false,
            "Banner text must mention unload (was: \(sut.lastInfoMessage ?? "<nil>"))."
        )
        XCTAssertNil(sut.lastErrorMessage,
                     "Unload failures should not raise the red error banner — they're recoverable on next reconcile.")
    }

    // MARK: - Embedding lifecycle: app-restart user path

    /// User had Expanded Search ON, quit the app, relaunched, and re-opened
    /// the same project. `bootstrapDefaultStorageIfNeeded` reads
    /// `lastOpenedWorkFolderPath` and calls `openWorkFolder` with the saved
    /// path — and our reconcile-after-openWorkFolder must auto-load the model
    /// without the user touching the toggle.
    func testAppRestart_simulatedByPreEnabledToggle_loadsOnFolderOpen() async {
        // Pre-condition: toggle persisted as ON in UserDefaults from prior session.
        sut.configuration.expandedSearchEnabled = true
        XCTAssertTrue(embeddingClient.loadUnloadCalls.isEmpty,
                      "Setting the bool alone must not touch the lifecycle — open is the trigger.")

        await sut.openWorkFolder(tempDir)

        XCTAssertEqual(embeddingClient.loadUnloadCalls.count, 1)
        if case .load = embeddingClient.loadUnloadCalls.first { /* ok */ } else {
            XCTFail("Re-opening with toggle pre-enabled must auto-load. Got \(embeddingClient.loadUnloadCalls)")
        }
    }

    // MARK: - Embedding lifecycle: full re-enable cycle

    /// User disables, then re-enables. After ensureUnloaded clears local
    /// state, re-enable must re-issue load (the lifecycle service is no
    /// longer holding an instance_id to short-circuit on).
    func testReEnable_afterDisable_loadsAgain() async {
        await sut.openWorkFolder(tempDir)
        sut.configuration.expandedSearchEnabled = true
        await sut.onExpandedSearchSettingChanged()
        sut.configuration.expandedSearchEnabled = false
        await sut.onExpandedSearchSettingChanged()
        embeddingClient.calls.removeAll()

        sut.configuration.expandedSearchEnabled = true
        await sut.onExpandedSearchSettingChanged()

        XCTAssertEqual(embeddingClient.loadUnloadCalls.count, 1)
        if case .load = embeddingClient.loadUnloadCalls.first {} else {
            XCTFail("Re-enable must re-issue load. Got \(embeddingClient.loadUnloadCalls)")
        }
    }

    // MARK: - Embedding lifecycle: baseURL-only change

    /// User keeps the same model name but points to a different LM Studio
    /// host (e.g. switched from 127.0.0.1 to a remote box). EmbeddingConfig
    /// equality covers all fields, so this must trigger unload+load too.
    func testBaseURLChange_whileEnabled_unloadsOldThenLoadsNew() async {
        await sut.openWorkFolder(tempDir)
        sut.configuration.expandedSearchEnabled = true
        await sut.onExpandedSearchSettingChanged()
        let originalModel = sut.configuration.effectiveEmbeddingConfig.modelName
        embeddingClient.calls.removeAll()

        sut.configuration.expandedSearchEmbeddingConfig = EmbeddingConfig(
            baseURLString: "http://192.168.1.50:1234",
            modelName: originalModel
        )
        await sut.onExpandedSearchEmbeddingConfigChanged()

        XCTAssertEqual(embeddingClient.loadUnloadCalls.count, 2,
                       "URL change with same model name must still cycle the model.")
        if case .unload(_, let oldURL) = embeddingClient.loadUnloadCalls.first {
            XCTAssertEqual(oldURL, "http://127.0.0.1:1234")
        } else {
            return XCTFail("First call must be unload at old URL; got \(embeddingClient.loadUnloadCalls)")
        }
        if case .load(_, let newURL) = embeddingClient.loadUnloadCalls.last {
            XCTAssertEqual(newURL, "http://192.168.1.50:1234")
        } else {
            XCTFail("Second call must be load at new URL; got \(embeddingClient.loadUnloadCalls)")
        }
    }

    // MARK: - Embedding lifecycle: resetAllData

    func testResetAllData_unloadsEmbeddingModel() async {
        await sut.openWorkFolder(tempDir)
        sut.configuration.expandedSearchEnabled = true
        await sut.onExpandedSearchSettingChanged()
        embeddingClient.calls.removeAll()

        await sut.resetAllData()

        // resetAllData → tearDownSearchIndexCoordinator → openWorkFolder(defaultURL).
        // setUp inside openWorkFolder is a no-op (default storage), reconcile
        // sees nil coordinator → unload.
        XCTAssertGreaterThanOrEqual(embeddingClient.loadUnloadCalls.count, 1,
                                    "Reset must unload the previously loaded model.")
        let hasUnload = embeddingClient.loadUnloadCalls.contains { call in
            if case .unload = call { return true }
            return false
        }
        XCTAssertTrue(hasUnload, "Reset path must include an unload. Got \(embeddingClient.loadUnloadCalls)")
    }

    // MARK: - Embedding lifecycle: rapid toggle via detached tasks

    /// Mirrors the real UI path where each toggle click spawns its own
    /// `Task { await ... }`. The FIFO `pendingExpandedSearchToggle` chain
    /// must serialize the lifecycle effects so the final state matches the
    /// last click — for ON→OFF→ON, that's "loaded".
    func testRapidToggle_viaDetachedTasks_finalLifecycleStateMatchesLastClick() async {
        await sut.openWorkFolder(tempDir)

        sut.configuration.expandedSearchEnabled = true
        let t1 = Task { await sut.onExpandedSearchSettingChanged() }
        sut.configuration.expandedSearchEnabled = false
        let t2 = Task { await sut.onExpandedSearchSettingChanged() }
        sut.configuration.expandedSearchEnabled = true
        let t3 = Task { await sut.onExpandedSearchSettingChanged() }

        await t1.value
        await t2.value
        await t3.value

        XCTAssertNotNil(sut.searchIndexCoordinator,
                        "Final state ON → coordinator must be live.")
        // Last call must be a load — anything else means the FIFO chain
        // ran out of order.
        if case .load = embeddingClient.loadUnloadCalls.last {} else {
            XCTFail("Final lifecycle action must be load. Trace: \(embeddingClient.loadUnloadCalls)")
        }
    }

    // MARK: - Embedding lifecycle: redundant toggle ON

    /// `onExpandedSearchSettingChanged` is called whenever the user clicks
    /// the toggle, including on a no-op click that doesn't actually change
    /// the value (rare but possible via direct binding writes). The
    /// lifecycle service's idempotency guard must short-circuit so the
    /// coordinator's existing model isn't needlessly reloaded.
    func testRedundantToggleOn_doesNotReissueLoad() async {
        await sut.openWorkFolder(tempDir)
        sut.configuration.expandedSearchEnabled = true
        await sut.onExpandedSearchSettingChanged()
        XCTAssertEqual(embeddingClient.loadUnloadCalls.count, 1)

        // Hook fires again with no state change.
        await sut.onExpandedSearchSettingChanged()

        XCTAssertEqual(embeddingClient.loadUnloadCalls.count, 1,
                       "ensureLoaded with same config must short-circuit; no extra calls.")
    }

    // MARK: - Embedding lifecycle: config change while disabled, then enable

    /// User changes the embed model in settings while Expanded Search is OFF
    /// (preview/setup before flipping the feature on). The change itself is
    /// a no-op for the lifecycle. Then they flip ON — the FIRST load must
    /// use the NEW config, not the original default.
    func testConfigChange_whileDisabled_thenEnable_loadsWithNewConfig() async {
        await sut.openWorkFolder(tempDir)
        // Toggle still OFF.
        sut.configuration.expandedSearchEmbeddingConfig = EmbeddingConfig(
            baseURLString: "http://127.0.0.1:1234",
            modelName: "preconfigured-model"
        )
        await sut.onExpandedSearchEmbeddingConfigChanged()
        XCTAssertTrue(embeddingClient.loadUnloadCalls.isEmpty,
                      "Disabled state — config change must be inert.")

        sut.configuration.expandedSearchEnabled = true
        await sut.onExpandedSearchSettingChanged()

        XCTAssertEqual(embeddingClient.loadUnloadCalls.count, 1)
        if case .load(let model, _) = embeddingClient.loadUnloadCalls.first {
            XCTAssertEqual(model, "preconfigured-model",
                           "First load on enable must honor the previously-configured model.")
        } else {
            XCTFail("Expected load call; got \(embeddingClient.loadUnloadCalls)")
        }
    }

    // MARK: - User-path E2E (Phase C)

    /// User path: app restart with the embed model already loaded server-side.
    /// LM Studio survives our process, so re-opening the project after a quit
    /// must NOT spawn a duplicate `:N` instance. Pre-fix every restart leaked
    /// a fresh instance; post-fix the lifecycle service queries
    /// `listLoadedInstances` first and adopts the existing one.
    func testUserPath_appRestart_modelAlreadyLoaded_doesNotCreateSecondInstance() async {
        // Pre-condition: server already has the canonical instance loaded.
        let modelName = sut.configuration.effectiveEmbeddingConfig.modelName
        embeddingClient.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: modelName, instanceID: modelName),
        ]

        // App "restart": fresh orchestrator state (no in-memory `loaded`),
        // user re-opens a project with toggle pre-enabled.
        sut.configuration.expandedSearchEnabled = true
        await sut.openWorkFolder(tempDir)

        // The lifecycle service must adopt without calling load.
        let loadCalls = embeddingClient.loadUnloadCalls.filter { call in
            if case .load = call { return true }
            return false
        }
        XCTAssertTrue(loadCalls.isEmpty,
                      "App restart must adopt existing server-side instance — no load. Trace: \(embeddingClient.loadUnloadCalls)")
        XCTAssertEqual(sut.embeddingLifecycle.loaded?.instanceID, modelName,
                       "Adopted instance id must match the server's existing one")
    }

    /// User path: app restart with a STALE model loaded server-side (user
    /// changed embed config since last session). The lifecycle service
    /// must NOT adopt the stale model — it should not appear in the
    /// loaded-instances list when the canonical name doesn't match config.
    func testUserPath_appRestart_serverHasDifferentModel_doesNotAdopt() async {
        // Server has a different model loaded.
        embeddingClient.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: "stale-model", instanceID: "stale-model"),
        ]
        embeddingClient.loadResults = ["fresh-instance"]

        sut.configuration.expandedSearchEnabled = true
        await sut.openWorkFolder(tempDir)

        // The list call happened, no match for current modelName, so loadModel
        // was called for the right model.
        let loaded = embeddingClient.loadUnloadCalls.first { call in
            if case .load = call { return true }
            return false
        }
        if case .load(let model, _) = loaded {
            XCTAssertEqual(model, sut.configuration.effectiveEmbeddingConfig.modelName,
                           "Must load the model the user actually configured, not adopt the stale one")
        } else {
            XCTFail("Expected load call after non-matching list. Trace: \(embeddingClient.loadUnloadCalls)")
        }
        XCTAssertEqual(sut.embeddingLifecycle.loaded?.instanceID, "fresh-instance")
    }

    /// User path: load fails (server down) — the user must see a RED error
    /// banner explaining the feature is degraded, NOT a neutral info banner.
    /// Coordinator stays installed so keyword-only search still works.
    func testUserPath_loadFails_userSeesErrorBanner_keywordSearchStillWorks() async {
        await sut.openWorkFolder(tempDir)
        embeddingClient.loadError = TestError.boom

        sut.configuration.expandedSearchEnabled = true
        await sut.onExpandedSearchSettingChanged()

        XCTAssertNotNil(sut.lastErrorMessage,
                        "Load failure means feature broken — must use red banner, not neutral info.")
        XCTAssertTrue(sut.lastErrorMessage?.contains("keyword-only") ?? false,
                      "Banner must reassure the user keyword search still works.")
        XCTAssertNotNil(sut.searchIndexCoordinator,
                        "Coordinator must remain installed — vector index degrades gracefully")
        XCTAssertNil(sut.embeddingLifecycle.loaded,
                     "Lifecycle service's belief reflects reality — nothing loaded after load failure.")
    }

    /// User path: unload fails (LM Studio in a bad state). Pre-fix this was
    /// silent; post-fix the user sees an info banner so they know VRAM may
    /// not have been reclaimed and can retry.
    func testUserPath_unloadFails_surfacesInfoForUser() async {
        await sut.openWorkFolder(tempDir)
        sut.configuration.expandedSearchEnabled = true
        await sut.onExpandedSearchSettingChanged()
        sut.lastInfoMessage = nil
        sut.lastErrorMessage = nil

        // Toggle OFF, but unload fails.
        embeddingClient.unloadError = TestError.boom
        sut.configuration.expandedSearchEnabled = false
        await sut.onExpandedSearchSettingChanged()

        XCTAssertNotNil(sut.lastInfoMessage,
                        "Unload failure must not be silent — user needs to know VRAM may be pinned")
        XCTAssertTrue(sut.lastInfoMessage?.contains("unload") ?? false)
        XCTAssertNil(sut.lastErrorMessage,
                     "Unload errors aren't 'feature broken' — info severity, not error")
    }

    /// User path: chat-mode advisory role under autonomous supervisor mode
    /// completes its work, the auto-supervisor service answers any
    /// `ask_supervisor` calls, and after 3 consecutive non-productive turns
    /// the role auto-finishes. End-to-end version of C2 + I6.
    func testUserPath_advisoryRole_chatMode_autonomous_finishesAfterThreeNonProductiveTurns() async {
        // This test exercises the LLM execution path directly via the public
        // attemptAdvisoryAutoFinish helper, avoiding the streaming pipeline
        // (which would need an LM Studio server).
        let svc = LLMExecutionService(repository: NTMSRepository())
        let mock = MockLLMExecutionDelegate()
        svc.attach(delegate: mock)

        let role = TeamRoleDefinition(
            id: "coding_assistant",
            name: "Coding Assistant",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Supervisor Task"],
                producesArtifacts: []
            ),
            isSystemRole: true,
            systemRoleID: "codingAssistant"
        )
        let supervisor = TeamRoleDefinition(
            id: "sup", name: "Supervisor", prompt: "",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: [],
                producesArtifacts: ["Supervisor Task"]
            ),
            isSystemRole: true, systemRoleID: "supervisor"
        )
        var settings = TeamSettings()
        settings.supervisorMode = .autonomous
        let team = Team(id: "t", name: "T", roles: [supervisor, role], artifacts: [],
                        settings: settings, graphLayout: TeamGraphLayout())
        XCTAssertTrue(team.isChatMode, "Sanity check — team is chat-mode")

        let step = StepExecution(id: "coding_assistant", role: .softwareEngineer,
                                  title: "Chat", status: .running)
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "do work",
                            runs: [Run(id: 0, steps: [step])])
        task.adoptGeneratedTeam(team)
        task.runs[0].roleStatuses[role.id] = .working
        mock.taskToMutate = task
        svc._testRegisterStepTask(stepID: step.id, taskID: task.id)

        // 3 non-productive turns:
        //   Turns 1, 2: counter advances, no completion.
        //   Turn 3: threshold trips, step + role both .done.
        for i in 1...2 {
            let stop = await svc.attemptAdvisoryAutoFinish(stepID: step.id, roleDefinition: role)
            XCTAssertNil(stop, "Turn \(i) below threshold — expected nil, got \(String(describing: stop))")
        }
        let finalStop = await svc.attemptAdvisoryAutoFinish(stepID: step.id, roleDefinition: role)
        if case .completed? = finalStop { /* ok */ } else {
            XCTFail("3rd turn should auto-finish chat-mode advisory role, got \(String(describing: finalStop))")
        }

        // End-state: step .done, role .done — this is what allows the engine's
        // chat-mode arm to drain cleanly without deadlocking on .needsAcceptance.
        XCTAssertEqual(mock.taskToMutate?.runs[0].steps[0].status, .done)
        XCTAssertEqual(mock.taskToMutate?.runs[0].roleStatuses[role.id], .done)
    }

    // MARK: - I7 regression: FIFO guard reads post-FIFO state

    /// I7: pre-fix `onExpandedSearchEmbeddingConfigChanged`'s
    /// `guard configuration.expandedSearchEnabled else { return }` ran
    /// SYNCHRONOUSLY before enqueueing on the FIFO chain. If a toggle-OFF
    /// was already queued ahead of this config change, the guard read the
    /// stale (still-true) value and scheduled a reconcile that fired
    /// pointlessly after the toggle-OFF tore down the coordinator.
    /// Post-fix: the guard runs INSIDE the queued task body, so it sees
    /// the post-FIFO state and the reconcile is skipped correctly.
    func testOnEmbeddingConfigChanged_afterToggleOff_observesPostFIFOState() async {
        await sut.openWorkFolder(tempDir)
        sut.configuration.expandedSearchEnabled = true
        await sut.onExpandedSearchSettingChanged()
        embeddingClient.calls.removeAll()

        // Stage two events back-to-back via detached tasks: toggle-OFF first,
        // then a config change. The config change captures `expandedSearchEnabled
        // == true` at scheduling time (before toggle-OFF has applied) but must
        // observe `false` when its turn in the FIFO chain runs.
        sut.configuration.expandedSearchEnabled = false
        let togglePromise = Task { await sut.onExpandedSearchSettingChanged() }
        sut.configuration.expandedSearchEmbeddingConfig = EmbeddingConfig(
            baseURLString: "http://127.0.0.1:1234",
            modelName: "different-model"
        )
        let configPromise = Task { await sut.onExpandedSearchEmbeddingConfigChanged() }

        await togglePromise.value
        await configPromise.value

        // Final state: feature OFF, no extra load fired by the deferred
        // config-change handler. Pre-fix the trace would have been
        // [unload, load(different-model), unload-or-orphan…].
        XCTAssertNil(sut.searchIndexCoordinator, "Final state OFF — coordinator should be torn down.")
        let loadCallsAfterToggleOff = embeddingClient.loadUnloadCalls.filter { call in
            if case .load = call { return true }
            return false
        }
        XCTAssertTrue(loadCallsAfterToggleOff.isEmpty,
                      "Config change must NOT trigger a load when post-FIFO state is OFF. Trace: \(embeddingClient.loadUnloadCalls)")
    }
}
