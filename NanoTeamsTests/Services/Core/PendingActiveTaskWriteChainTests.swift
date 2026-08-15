import XCTest

@testable import NanoTeams

/// Pins the `pendingActiveTaskWrite` chain invariants that other writers of
/// `activeTaskID` must respect. The original `ceadc0f` commit serialized only
/// fast-path-to-fast-path writes; this suite pins that:
///
///  - `createTask` (top-level branch), `removeTask` (active-task fallback
///    branch), and slow-path `switchTask` all flush the chain BEFORE their
///    synchronous repository write (C6/C7/C8). Without the flush their sync
///    write races the chain's still-in-flight detached body.
///  - `flushPendingActiveTaskWrite` swallows predecessor failures so the
///    flow continues even if a prior chain link threw (C5 — protects the
///    `try?` invariant in the fast-path Task itself).
///  - `closeProject` / `resetAllData` cancel any pending chain Task so it
///    doesn't fire against a torn-down workfolder (I2).
@MainActor
final class PendingActiveTaskWriteChainTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    // MARK: - C5 / I2 building block: flush awaits pending Task

    func testFlushPendingActiveTaskWrite_awaitsInFlightTaskBeforeReturning() async {
        let gate = AsyncGate()
        let didComplete = AtomicFlag()
        sut.pendingActiveTaskWrite = Task<Void, Error> {
            await gate.wait()
            didComplete.set()
        }
        // Schedule the unblock concurrently with the flush — if `flush`
        // returned without awaiting, `didComplete` would still be false.
        Task { await gate.open() }
        await sut.flushPendingActiveTaskWrite()
        XCTAssertTrue(didComplete.value,
                      "flushPendingActiveTaskWrite must await the in-flight Task before returning")
    }

    // MARK: - C5: predecessor-throws → flush still returns

    func testFlushPendingActiveTaskWrite_swallowsThrownPredecessor() async {
        struct Boom: Error {}
        sut.pendingActiveTaskWrite = Task<Void, Error> { throw Boom() }
        // Must not propagate the thrown error; `flushPendingActiveTaskWrite`
        // is marked non-throwing precisely so callers don't have to care.
        await sut.flushPendingActiveTaskWrite()
        // Reaching this line is the assertion — if the implementation
        // changed to `try await`, the test would fail to compile or hang.
        XCTAssertTrue(true)
    }

    /// Fast-path switchTask uses the same `try? await previous?.value`
    /// pattern as `flushPendingActiveTaskWrite`. Pins that a thrown
    /// predecessor doesn't leak through into a user-facing banner on the
    /// subsequent switch — the predecessor's own switchTask already
    /// surfaced its banner; reporting it again on the NEXT user-initiated
    /// switch would be doubly confusing.
    func testFastPathSwitch_predecessorThrows_completesWithoutBanner() async {
        await sut.openWorkFolder(tempDir)
        let aID = await sut.createTask(title: "A", supervisorTask: "1")!
        let bID = await sut.createTask(title: "B", supervisorTask: "2")!
        // Make A active so B sits in `loadedTasks` (fast-path target).
        await sut.switchTask(to: aID)
        // Clear any previous banner that test setup may have left.
        sut.lastErrorMessage = nil

        struct Boom: Error {}
        sut.pendingActiveTaskWrite = Task<Void, Error> { throw Boom() }

        await sut.switchTask(to: bID)

        XCTAssertEqual(sut.activeTaskID, bID,
                       "Switch must complete to B despite a throwing predecessor")
        XCTAssertNil(sut.lastErrorMessage,
                     "Thrown predecessor must be absorbed by `try?` and not surface as a banner")
    }

    // MARK: - C7: createTask flushes the chain before its sync write

    func testCreateTask_flushesPendingActiveTaskWriteBeforeRepositoryCall() async {
        await sut.openWorkFolder(tempDir)

        let gate = AsyncGate()
        let chainSawCreate = AtomicFlag()

        // Stand-in for an in-flight fast-path chain Task. If `createTask`
        // skips the flush, it will write `activeTaskID = newTaskID` BEFORE
        // this Task gets to run — and the assertion at the bottom fires.
        sut.pendingActiveTaskWrite = Task<Void, Error> {
            await gate.wait()
            chainSawCreate.set()
        }

        // Open the gate AFTER scheduling createTask so the chain Task is
        // forced to complete (and signal `chainSawCreate`) before
        // `createTask` returns. Without flushing inside `createTask` the
        // assertion below would observe the create-returned-first ordering.
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            await gate.open()
        }

        _ = await sut.createTask(title: "T", supervisorTask: "Goal")

        XCTAssertTrue(chainSawCreate.value,
                      "createTask must `await flushPendingActiveTaskWrite()` before invoking repository.createTask")
    }

    // MARK: - C8: removeTask flushes the chain before its sync write

    func testRemoveTask_flushesPendingActiveTaskWriteBeforeRepositoryCall() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "T", supervisorTask: "G")!

        let gate = AsyncGate()
        let chainSawRemove = AtomicFlag()
        sut.pendingActiveTaskWrite = Task<Void, Error> {
            await gate.wait()
            chainSawRemove.set()
        }
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            await gate.open()
        }

        await sut.removeTask(id)

        XCTAssertTrue(chainSawRemove.value,
                      "removeTask must `await flushPendingActiveTaskWrite()` before invoking repository.deleteTask")
    }

    // MARK: - C6: slow-path switchTask flushes the chain before its sync write

    func testSwitchTask_slowPath_flushesPendingActiveTaskWriteBeforeRepositoryCall() async {
        await sut.openWorkFolder(tempDir)
        let aID = await sut.createTask(title: "A", supervisorTask: "1")!
        let bID = await sut.createTask(title: "B", supervisorTask: "2")!

        // Switch to A so B is no longer the active task — it now lives in
        // `loadedTasks`. Evict it so the next `switchTask(to: bID)` falls
        // through to the cold-cache slow path.
        await sut.switchTask(to: aID)
        sut.evictLoadedTask(bID)

        let gate = AsyncGate()
        let chainSawSwitch = AtomicFlag()
        sut.pendingActiveTaskWrite = Task<Void, Error> {
            await gate.wait()
            chainSawSwitch.set()
        }
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            await gate.open()
        }

        await sut.switchTask(to: bID)

        XCTAssertTrue(chainSawSwitch.value,
                      "Slow-path switchTask must `await flushPendingActiveTaskWrite()` before invoking repository.setActiveTask")
    }

    // NB: I2 (`closeProject` / `resetAllData` cancel the pending chain) is
    // verified by inspection of the diff at
    // `NTMSOrchestrator+WorkFolderManagement.swift`. Behavioral pinning would
    // require calling `closeProject`, which falls through to
    // `openWorkFolder(defaultStorageURL)` and writes to user Application
    // Support — outside the test sandbox per the project workspace rule.
    // Cancel-and-nil is a 2-line sync sequence happening before any `await`
    // in both methods, low rot risk.

}

// MARK: - Test helpers

/// One-shot async gate — `wait()` suspends until `open()` is called once.
/// Cancellation-aware via the `withTaskCancellationHandler` wrapper so a
/// cancelled awaiter unblocks immediately.
private actor AsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if isOpen {
                    continuation.resume()
                } else {
                    continuations.append(continuation)
                }
            }
        } onCancel: {
            Task { await self.openIfNotOpen() }
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for c in pending { c.resume() }
    }

    private func openIfNotOpen() {
        guard !isOpen else { return }
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for c in pending { c.resume() }
    }
}

/// Tiny thread-safe boolean flag for assertions across Tasks.
private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool = false
    var value: Bool {
        lock.withLock { _value }
    }
    func set() {
        lock.withLock { _value = true }
    }
}
