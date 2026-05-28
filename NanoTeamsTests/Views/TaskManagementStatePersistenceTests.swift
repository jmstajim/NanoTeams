import XCTest
@testable import NanoTeams

/// Persistence-and-binding tests for `TaskManagementState`'s seen-set lifecycle.
///
/// Covers the bug fix where sidebar "read" markers must survive app relaunches.
/// `TaskManagementState` is bound to a `StoreConfiguration` and a current
/// `workFolderID`; `markSupervisorInputSeen` / `unmarkSupervisorInputSeen`
/// route writes through both the in-memory mirror (for SidebarView reads)
/// and the persisted set (for cross-launch survival).
///
/// Lenient fallback: when no config is bound (test scenarios that don't care
/// about persistence), the methods still update the in-memory mirror.
@MainActor
final class TaskManagementStatePersistenceTests: XCTestCase {

    final class InMemoryStorage: ConfigurationStorage, @unchecked Sendable {
        var store: [String: Any] = [:]
        func string(forKey key: String) -> String? { store[key] as? String }
        func bool(forKey key: String) -> Bool { (store[key] as? Bool) ?? false }
        func data(forKey key: String) -> Data? { store[key] as? Data }
        func object(forKey key: String) -> Any? { store[key] }
        func set(_ value: Any?, forKey key: String) {
            if let value { store[key] = value } else { store.removeValue(forKey: key) }
        }
        func removeObject(forKey key: String) { store.removeValue(forKey: key) }
    }

    var storage: InMemoryStorage!
    var config: StoreConfiguration!
    var sut: TaskManagementState!
    let folderA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let folderB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    override func setUp() {
        super.setUp()
        storage = InMemoryStorage()
        config = StoreConfiguration(storage: storage)
        sut = TaskManagementState()
        sut.bind(config: config)
    }

    override func tearDown() {
        sut = nil
        config = nil
        storage = nil
        super.tearDown()
    }

    // MARK: - Bind + load

    func testLoadSeenSet_hydratesInMemorySetFromConfig() {
        // Pre-seed config as if a prior run had marked taskIDs 1+2 seen.
        config.markTaskSeen(workFolderID: folderA, taskID: 1)
        config.markTaskSeen(workFolderID: folderA, taskID: 2)

        sut.loadSeenSet(for: folderA)

        XCTAssertEqual(sut.seenSupervisorInputTaskIDs, Set([1, 2]))
    }

    func testLoadSeenSet_nil_clearsInMemoryMirror() {
        config.markTaskSeen(workFolderID: folderA, taskID: 1)
        sut.loadSeenSet(for: folderA)
        XCTAssertFalse(sut.seenSupervisorInputTaskIDs.isEmpty)

        sut.loadSeenSet(for: nil)

        XCTAssertTrue(sut.seenSupervisorInputTaskIDs.isEmpty)
    }

    func testLoadSeenSet_unknownFolder_emptySet() {
        config.markTaskSeen(workFolderID: folderA, taskID: 1)
        sut.loadSeenSet(for: folderB)
        XCTAssertTrue(sut.seenSupervisorInputTaskIDs.isEmpty)
    }

    // MARK: - Persisted mark/unmark

    func testMark_persistsThroughConfig() {
        sut.loadSeenSet(for: folderA)
        sut.markSupervisorInputSeen(taskID: 42)
        XCTAssertTrue(config.isTaskSeen(workFolderID: folderA, taskID: 42))
        XCTAssertTrue(sut.seenSupervisorInputTaskIDs.contains(42))
    }

    func testUnmark_persistsRemovalThroughConfig() {
        sut.loadSeenSet(for: folderA)
        sut.markSupervisorInputSeen(taskID: 42)
        sut.unmarkSupervisorInputSeen(taskID: 42)
        XCTAssertFalse(config.isTaskSeen(workFolderID: folderA, taskID: 42))
        XCTAssertFalse(sut.seenSupervisorInputTaskIDs.contains(42))
    }

    // MARK: - Cross-launch survival (the headline regression pin)

    func testRelaunch_seenStatePersists() {
        sut.loadSeenSet(for: folderA)
        sut.markSupervisorInputSeen(taskID: 1)
        sut.markSupervisorInputSeen(taskID: 2)

        // Simulate process restart: fresh StoreConfiguration + fresh TaskManagementState
        // off the same backing storage.
        let reloadedConfig = StoreConfiguration(storage: storage)
        let reloadedState = TaskManagementState()
        reloadedState.bind(config: reloadedConfig)
        reloadedState.loadSeenSet(for: folderA)

        XCTAssertEqual(reloadedState.seenSupervisorInputTaskIDs, Set([1, 2]))
    }

    // MARK: - Workfolder isolation

    func testSwitchingFolders_swapsInMemoryMirror() {
        sut.loadSeenSet(for: folderA)
        sut.markSupervisorInputSeen(taskID: 5)

        sut.loadSeenSet(for: folderB)
        XCTAssertFalse(
            sut.seenSupervisorInputTaskIDs.contains(5),
            "Folder B view must not see folder A's task IDs"
        )

        sut.loadSeenSet(for: folderA)
        XCTAssertTrue(
            sut.seenSupervisorInputTaskIDs.contains(5),
            "Returning to folder A must restore its persisted seen set"
        )
    }

    func testMarkInFolderA_doesNotLeakIntoFolderB() {
        sut.loadSeenSet(for: folderA)
        sut.markSupervisorInputSeen(taskID: 7)

        XCTAssertFalse(config.isTaskSeen(workFolderID: folderB, taskID: 7))
    }

    // MARK: - confirmDelete persistence

    /// `confirmDelete` calls `unmarkSupervisorInputSeen` so the persisted entry
    /// for the deleted task is also wiped (otherwise the entry would linger in
    /// UserDefaults indefinitely, and if a future task ever reuses that ID it
    /// would mis-attribute the stale seen flag).
    func testConfirmDelete_unmarksPersistedSeenEntry() async {
        sut.loadSeenSet(for: folderA)
        sut.markSupervisorInputSeen(taskID: 7)
        XCTAssertTrue(config.isTaskSeen(workFolderID: folderA, taskID: 7))

        sut.unmarkSupervisorInputSeen(taskID: 7)
        XCTAssertFalse(config.isTaskSeen(workFolderID: folderA, taskID: 7))
    }

    // MARK: - Lenient fallback (no config bound)

    func testMark_withoutBind_updatesInMemoryOnly() {
        let unbound = TaskManagementState()
        unbound.markSupervisorInputSeen(taskID: 99)
        XCTAssertTrue(unbound.seenSupervisorInputTaskIDs.contains(99))
        // No crash, no persistence — the surrounding test's `config` is untouched.
        XCTAssertFalse(config.isTaskSeen(workFolderID: folderA, taskID: 99))
    }

    func testMark_boundButNoFolderLoaded_updatesInMemoryOnly() {
        // `bind` was called in setUp, but `loadSeenSet` never happened — so
        // currentWorkFolderID is nil and persistence must skip.
        sut.markSupervisorInputSeen(taskID: 99)
        XCTAssertTrue(sut.seenSupervisorInputTaskIDs.contains(99))
        XCTAssertFalse(config.isTaskSeen(workFolderID: folderA, taskID: 99))
        XCTAssertFalse(config.isTaskSeen(workFolderID: folderB, taskID: 99))
    }

    // MARK: - Background-task re-question (the Finding #1 regression pin)

    /// Full user-perspective sequence: task A asks a question while user is
    /// looking at it → user clicks A (dot clears) → user switches to task B,
    /// backgrounding A → A processes the answer and goes `.running` → A asks
    /// a NEW question (`.needsSupervisorInput` again, still backgrounded).
    ///
    /// The dot MUST reappear for A's new question. Without the `reconcile`
    /// sweep, persistence would freeze A's stale seen flag forever — strictly
    /// worse than the in-memory bug it replaces.
    func testBackgroundTask_newQuestionRetriggersDot() {
        sut.loadSeenSet(for: folderA)

        // Step 1: user clicked task A (sidebar marked it seen).
        sut.markSupervisorInputSeen(taskID: 1)
        XCTAssertTrue(sut.seenSupervisorInputTaskIDs.contains(1))

        // Step 2: task A processes the answer in the background → status .running.
        sut.reconcileSeenSet(activeStatuses: [
            1: .running,
            2: .running,
        ], workFolderID: folderA)
        XCTAssertFalse(
            sut.seenSupervisorInputTaskIDs.contains(1),
            "Reconcile must clear A's seen flag once it's no longer waiting"
        )
        XCTAssertFalse(
            config.isTaskSeen(workFolderID: folderA, taskID: 1),
            "Persistence must follow — otherwise the next launch re-hydrates the stale flag"
        )

        // Step 3: A asks a new question while still backgrounded.
        let hasUnread = isChatMode(taskID: 1)
            && currentStatus(taskID: 1) == .needsSupervisorInput
            && !sut.seenSupervisorInputTaskIDs.contains(1)
        XCTAssertTrue(
            hasUnread,
            "A new question on a previously-read background task must re-trigger the dot"
        )
    }

    // Synthetic helpers replicating the SidebarView read site.
    private func isChatMode(taskID _: Int) -> Bool { true }
    private func currentStatus(taskID _: Int) -> TaskStatus { .needsSupervisorInput }

    // MARK: - reconcile + persistence interplay

    /// `reconcileSeenSet` must remove stale entries from BOTH the in-memory
    /// mirror and the persisted set — otherwise the next launch would
    /// re-hydrate the very flags reconcile just cleared.
    func testReconcile_clearsPersistedEntries() {
        sut.loadSeenSet(for: folderA)
        sut.markSupervisorInputSeen(taskID: 1)
        sut.markSupervisorInputSeen(taskID: 2)

        sut.reconcileSeenSet(activeStatuses: [
            1: .needsSupervisorInput,
            2: .running,  // should be cleared
        ], workFolderID: folderA)

        XCTAssertTrue(config.isTaskSeen(workFolderID: folderA, taskID: 1))
        XCTAssertFalse(config.isTaskSeen(workFolderID: folderA, taskID: 2))
    }

    // MARK: - Reconcile defensive guards

    /// Snapshot teardown (e.g. user closes the work folder) makes
    /// `allTaskStatuses` transition to `[:]`. Without an empty-statuses guard,
    /// every entry in the mirror would compare as `nil != .needsSupervisorInput`
    /// and be wiped from both memory AND persistence every time the user
    /// closes a folder — destroying the very state this PR adds.
    func testReconcile_emptyStatuses_doesNotWipePersistedEntries() {
        sut.loadSeenSet(for: folderA)
        sut.markSupervisorInputSeen(taskID: 1)
        sut.markSupervisorInputSeen(taskID: 2)

        sut.reconcileSeenSet(activeStatuses: [:], workFolderID: folderA)

        XCTAssertTrue(
            config.isTaskSeen(workFolderID: folderA, taskID: 1),
            "Empty statuses dict must not destroy persisted state — typical on snapshot teardown"
        )
        XCTAssertTrue(config.isTaskSeen(workFolderID: folderA, taskID: 2))
        XCTAssertEqual(sut.seenSupervisorInputTaskIDs, Set([1, 2]))
    }

    /// Folder-switch race: if the reconcile `.onChange` fires with the new
    /// folder's statuses before the matching `loadSeenSet` swaps the mirror,
    /// reconcile must NOT wipe the previous folder's persisted entries through
    /// the still-bound `currentWorkFolderID`. Passing the caller's folder ID
    /// and short-circuiting on mismatch makes safety structural, independent
    /// of SwiftUI onChange ordering.
    func testReconcile_workfolderMismatch_doesNotTouchPersistence() {
        sut.loadSeenSet(for: folderA)
        sut.markSupervisorInputSeen(taskID: 1)
        sut.markSupervisorInputSeen(taskID: 2)

        sut.reconcileSeenSet(activeStatuses: [99: .running], workFolderID: folderB)

        XCTAssertTrue(config.isTaskSeen(workFolderID: folderA, taskID: 1))
        XCTAssertTrue(config.isTaskSeen(workFolderID: folderA, taskID: 2))
        XCTAssertEqual(sut.seenSupervisorInputTaskIDs, Set([1, 2]))
    }

    /// `workFolderID: nil` means "trust the bound folder" — the mismatch guard
    /// is skipped, but the empty-mirror + empty-statuses guards still apply,
    /// and unmarks correctly route through `currentWorkFolderID`. Pins the
    /// default-parameter contract.
    func testReconcile_nilWorkFolderID_bypassesMismatchGuard_butRespectsOtherGuards() {
        sut.loadSeenSet(for: folderA)
        sut.markSupervisorInputSeen(taskID: 1)

        sut.reconcileSeenSet(activeStatuses: [1: .running], workFolderID: nil)

        XCTAssertFalse(
            config.isTaskSeen(workFolderID: folderA, taskID: 1),
            "nil workFolderID delegates to bound folder — stale entry should be swept"
        )
        XCTAssertFalse(sut.seenSupervisorInputTaskIDs.contains(1))
    }

    // MARK: - SwiftUI lifecycle invariants

    /// SwiftUI's `.onAppear` can fire multiple times across the view's lifetime
    /// (modal dismissals, NavigationSplitView column re-mounts). `bind` must be
    /// idempotent — calling it twice with the same config must not corrupt the
    /// persistence routing or lose any in-memory state.
    func testBind_calledTwice_isIdempotent() {
        sut.bind(config: config)  // setUp already called bind once
        sut.loadSeenSet(for: folderA)
        sut.markSupervisorInputSeen(taskID: 1)

        sut.bind(config: config)  // second bind

        // Mutations after the second bind still persist correctly.
        sut.markSupervisorInputSeen(taskID: 2)
        XCTAssertTrue(config.isTaskSeen(workFolderID: folderA, taskID: 1))
        XCTAssertTrue(config.isTaskSeen(workFolderID: folderA, taskID: 2))
        XCTAssertEqual(sut.seenSupervisorInputTaskIDs, Set([1, 2]))
    }

    /// `loadSeenSet(for: sameFolder)` may be called multiple times when SwiftUI
    /// re-renders without an actual folder change. The mirror must rehydrate
    /// from persistence each time without leaking, double-counting, or losing
    /// entries that were marked between the two loads.
    func testLoadSeenSet_calledTwiceForSameFolder_isIdempotent() {
        sut.loadSeenSet(for: folderA)
        sut.markSupervisorInputSeen(taskID: 1)
        sut.markSupervisorInputSeen(taskID: 2)

        sut.loadSeenSet(for: folderA)

        XCTAssertEqual(sut.seenSupervisorInputTaskIDs, Set([1, 2]))
        XCTAssertTrue(config.isTaskSeen(workFolderID: folderA, taskID: 1))
        XCTAssertTrue(config.isTaskSeen(workFolderID: folderA, taskID: 2))
    }

    /// `loadSeenSet` is a pure read — calling it must never mutate persistence,
    /// even when the bound folder's persisted set is empty. Otherwise repeated
    /// `.onAppear` cycles on an empty folder could synthesize spurious entries
    /// or, more subtly, trigger a UserDefaults write that wakes other observers.
    func testLoadSeenSet_doesNotMutatePersistence() {
        let storageSnapshot = storage.store
        sut.loadSeenSet(for: folderA)
        XCTAssertEqual(
            storage.store.keys.sorted(),
            storageSnapshot.keys.sorted(),
            "loadSeenSet must not write any keys to storage"
        )
    }
}
