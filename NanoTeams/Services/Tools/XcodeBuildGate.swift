import Foundation

/// Process-wide exclusive access to `xcodebuild`.
///
/// **Why a gate exists at all.** `XcodeBuildRunner` never passes `-derivedDataPath`, so every
/// role in every task builds into the SAME DerivedData, and nothing above serialises the
/// calls: `ToolRuntime` runs a batch through a `withTaskGroup`, `TeamEngine.startRoles`
/// dispatches every ready role at once (CLAUDE.md #45), the default `RoleConcurrencyMode` is
/// `.providerLimited` on purpose, and even `.single` is a PER-TASK cap while several tasks run
/// at once. Until 2026-09-11 the defect merely slept: exactly three bundled roles held
/// `run_xcodebuild`, and each was the only such role in its team.
///
/// The symptom is measured in this repository three times over
/// (`.claude/skills/engineering-lessons`): `unable to attach DB: database is locked —
/// Possibly there are two concurrent builds running`; `0 passed, 0 failed` under a
/// `TEST FAILED` banner, which is the signature of a build that lost its `build.db`, not of a
/// killed test; and a `build` started during a `test-without-building` killing both.
///
/// **Why that is worse than a failure.** A red build caused by a locked database is
/// indistinguishable from a red build caused by the code. An Ultra Team verifier that loses the
/// race reports a failure the change did not cause, and the engineer is sent to repair code that
/// was never broken — the tool issued to settle a question would start manufacturing them.
///
/// The gate covers the RUNNERS and nothing else. A build launched through `bash` — which every
/// Ultra role can do since 2026-09-12, because that is the only build channel a non-Xcode
/// repository has — takes no token and stands outside this exclusion (`KNOWN_ISSUES`).
///
/// **Shape.** The actor owns a TOKEN, never the build. The build itself is synchronous
/// (`XcodebuildRunning.run` blocks on a poll loop), so running it inside an actor would make
/// the actor a blocking lock: a ten-minute build on the actor's executor turns a waiter's
/// `await` into a mailbox hop rather than a suspension point, and cancellation would never
/// land. Callers acquire, run OUTSIDE, release.
///
/// Scope is the PROCESS, not the task or the work folder. One folder is open at a time
/// (`NTMSOrchestrator.workFolderURL`) and `openWorkFolder` cancels every in-flight tool batch
/// before assigning a new URL, so two folder-keyed gates could never coexist — while a URL key
/// WOULD split `/var` and `/private/var` into two gates over one DerivedData, a difference the
/// runner itself has had to paper over elsewhere.
///
/// Honest scope limit: this covers `run_xcodebuild` / `run_xcodetests`. An `xcodebuild`
/// launched through `bash` by another team on the same folder is outside it (DEBTS).
actor XcodeBuildGate {

    static let shared = XcodeBuildGate()

    /// Who is waiting right now, so the UI can say WHY a tool call is taking minutes. The
    /// alternative — a placeholder in `resultJSON` — is forbidden here: `AutovisorStatus`
    /// reads `resultJSON == nil` to mean "a tool is in flight", and filling it would stop the
    /// stuck evaluator suppressing its "hung" verdict. Past `stuckHangSeconds` (180) — which
    /// any real build queue exceeds — the queued role would be answered with
    /// `manage_role restart` and lose its conversation.
    private(set) var waiting: Set<TaskStepKey> = []

    private struct Waiter {
        let id: UUID
        let key: TaskStepKey?
        let continuation: CheckedContinuation<Void, Error>
    }

    private var held = false
    private var queue: [Waiter] = []
    /// Ids whose `acquire` is between its cancellation handler being installed and its
    /// return — the only window in which a cancel can mean anything.
    private var live: Set<UUID> = []
    /// Ids cancelled in the window between `onCancel` firing and the continuation being
    /// enqueued. Without this the cancel finds an empty queue and the waiter hangs forever.
    /// Guarded by `live`: a cancel that lands AFTER the token was handed over (release
    /// resumed the waiter, its task has not left the handler scope yet) used to leave the
    /// id here for the life of the process — `cancelWaiter` runs in its own actor Task and
    /// may execute after `acquire`'s own cleanup, so a `defer { remove }` alone closed only
    /// one of the two orders.
    private var cancelledBeforeEnqueue: Set<UUID> = []
    private var observer: (@Sendable (Set<TaskStepKey>, UInt64) -> Void)?
    /// Monotonic per notification. The observer forwards each set to the main actor through
    /// an unstructured `Task`, and two such hops carry no ordering guarantee — a hand-off
    /// emits up to three sets in a row, and a stale `[k]` landing after the `[]` that
    /// superseded it would pin a caption on a step that stopped waiting. The consumer
    /// rejects anything older than what it last applied.
    private var notifySeq: UInt64 = 0

    /// Registered once at app wiring by whoever owns the UI state. Not an array: there is
    /// exactly one renderer of this fact, and a list would invite a second opinion about it.
    func setObserver(_ observer: (@Sendable (Set<TaskStepKey>, UInt64) -> Void)?) {
        self.observer = observer
        notify()
    }

    private func notify() {
        notifySeq += 1
        observer?(waiting, notifySeq)
    }

    /// Drops `key` from the published set only when no queued waiter still carries it: one
    /// step can queue both runners in one batch (`ToolRuntime` runs a batch through a task
    /// group), and the first hand-off must not clear the caption while the second waiter is
    /// still in line. The one rule for all three removal sites.
    private func syncWaiting(_ key: TaskStepKey?) {
        guard let key, !queue.contains(where: { $0.key == key }) else { return }
        if waiting.remove(key) != nil { notify() }
    }

    /// Waits for exclusive access. Returns how long the wait took, so the caller can log it
    /// separately from the build's own duration — `durationMS` in `tool_calls.jsonl` is
    /// suspend-inclusive, so without a separate `queuedMS` an audit of
    /// `select(.durationMS > 500)` would bill the queue to the compiler.
    ///
    /// **Cancellation contract.** A waiter throws `ProcessRunnerError.cancelled`, never
    /// `CancellationError`: `ToolErrorHandler.execute` has an arm for the former that emits
    /// the unified cancel envelope (code `cancelled`). That envelope IS written to
    /// `tool_calls.jsonl` by `ToolRuntime.executeOne`, like any other result of a handler
    /// that ran — which is why it must carry `queuedMS` (`withExclusiveAccess`): for a
    /// cancelled waiter the whole `durationMS` is queue time, and the two fields say so. A
    /// `CancellationError` would fall into the generic `classify` instead and be recorded
    /// as `COMMAND_FAILED` — an "executed failure" in every log-based audit, and a repair
    /// direction, for a build that never started.
    func acquire(key: TaskStepKey?) async throws -> Duration {
        try Task.checkCancellation()
        guard held else {
            held = true
            return .zero
        }

        let id = UUID()
        let started = ContinuousClock.now
        if let key { waiting.insert(key); notify() }
        live.insert(id)
        defer {
            live.remove(id)
            cancelledBeforeEnqueue.remove(id)
            syncWaiting(key)
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if cancelledBeforeEnqueue.remove(id) != nil {
                    continuation.resume(throwing: ProcessRunnerError.cancelled)
                } else {
                    queue.append(Waiter(id: id, key: key, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        return ContinuousClock.now - started
    }

    /// Hands the token to the next waiter, or puts it down. `held` stays `true` across a
    /// hand-off: the token is transferred, never released and re-taken, so a build that
    /// starts between the two would jump the queue.
    func release() {
        guard !queue.isEmpty else {
            held = false
            return
        }
        let next = queue.removeFirst()
        syncWaiting(next.key)
        next.continuation.resume()
    }

    private func cancelWaiter(_ id: UUID) {
        guard live.contains(id) else { return }
        guard let index = queue.firstIndex(where: { $0.id == id }) else {
            cancelledBeforeEnqueue.insert(id)
            return
        }
        let waiter = queue.remove(at: index)
        syncWaiting(waiter.key)
        waiter.continuation.resume(throwing: ProcessRunnerError.cancelled)
    }

    /// Acquire → run → release, with the release on every path including a throw — and
    /// the queue duration on every path too, which is why this returns a `Result` rather
    /// than throwing: a cancelled wait, a cancelled or timed-out build and a launch failure
    /// all become envelopes in `ToolErrorHandler`, and an envelope built from a thrown
    /// error had no way to learn how long the call had queued. Until the evening of
    /// 2026-09-11 every one of those was logged with a wait-inclusive `durationMS` and no
    /// `queuedMS` — the exact misreading `queuedMS` was added to prevent.
    ///
    /// `body` is synchronous BY SIGNATURE, which is the contract that keeps the token out of
    /// the actor: it runs on the batch task's own thread, exactly where `sweep` ran before
    /// the gate existed. The timeout inside it therefore still starts when the PROCESS
    /// spawns (`ProcessRunner` computes its deadline after the spawn), not when the call was
    /// queued — a ten-minute wait cannot consume a ten-minute build's budget.
    static func withExclusiveAccess<T>(
        key: TaskStepKey?, _ body: () throws -> T
    ) async -> (result: Result<T, Error>, queued: Duration) {
        let started = ContinuousClock.now
        let queued: Duration
        do {
            queued = try await shared.acquire(key: key)
        } catch {
            return (.failure(error), ContinuousClock.now - started)
        }
        let result = Result { try body() }
        await shared.release()
        return (result, queued)
    }

    #if DEBUG
    /// Test-only reset: the gate is a process-global and XCTest reuses the process. The
    /// notification sequence is NOT reset — a consumer created before the reset remembers
    /// the last number it applied, and a restart would make every later set look stale.
    func _testReset() {
        for waiter in queue { waiter.continuation.resume(throwing: ProcessRunnerError.cancelled) }
        queue.removeAll()
        live.removeAll()
        cancelledBeforeEnqueue.removeAll()
        waiting.removeAll()
        held = false
        observer = nil
    }

    /// Test-only: the tombstones no path has cleaned up yet.
    var _testCancelledBeforeEnqueueCount: Int { cancelledBeforeEnqueue.count }
    #endif
}
