import XCTest
@testable import NanoTeams

/// Pins the `DelegationLoopWatcher` orchestration: child-task gating,
/// throttling, cooldown, and the auto-trigger handoff to
/// `notifyDelegationInterrupt`. The detector itself is exercised by
/// `MessageRepetitionDetectorTests`; these tests focus on the watcher's
/// glue logic.
@MainActor
final class DelegationLoopWatcherTests: XCTestCase {

    private func makeOrchestrator() -> NTMSOrchestrator {
        NTMSOrchestrator(
            repository: NTMSRepository(),
            searchEmbeddingClient: StubSearchEmbeddingClient()
        )
    }

    private func makeWorkFolderRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeams-loop-watcher-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Helper: produce a string that's guaranteed to fire the within-message
    /// detector (`MessageRepetitionDetector.detectTailLoop`).
    private func loopText() -> String {
        // "Oh, wait! " is 10 chars (substantive content) — repeated 8 times
        // exceeds default minRepeats=5.
        String(repeating: "Oh, wait! ", count: 8)
    }

    private func cleanText() -> String {
        "The implementation reads the file, validates the schema, and writes the result. Nothing repeats here in any pathological way."
    }

    // MARK: - considerCommitted helpers (post-commit hooks unified into one entry)

    /// Drives the within-message path: one finalized assistant turn.
    private func commitWithin(
        _ w: DelegationLoopWatcher, _ taskID: Int, content: String, thinking: String? = nil
    ) {
        w.considerCommitted(
            taskID: taskID,
            recentAssistant: [(thinking: thinking, content: content, createdAt: MonotonicClock.shared.now())],
            toolCalls: []
        )
    }

    /// Drives the across-messages path: N finalized assistant turns (content-only).
    private func commitAcross(_ w: DelegationLoopWatcher, _ taskID: Int, messages: [String]) {
        let tuples: [(thinking: String?, content: String, createdAt: Date)] =
            messages.map { (thinking: nil, content: $0, createdAt: MonotonicClock.shared.now()) }
        w.considerCommitted(taskID: taskID, recentAssistant: tuples, toolCalls: [])
    }

    /// Drives the tool-call-sequence path.
    private func commitTools(
        _ w: DelegationLoopWatcher, _ taskID: Int,
        calls: [(name: String, argsJSON: String, createdAt: Date)]
    ) {
        w.considerCommitted(taskID: taskID, recentAssistant: [], toolCalls: calls)
    }

    // MARK: - Child-task gating

    /// Top-level tasks (no `parentTaskID`) must NOT trigger interrupts —
    /// they have no parent role's awaiter to wake. The watcher silently
    /// skips them.
    func testWatcher_topLevelTask_noTrigger() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        await store.openWorkFolder(root)
        let parentID = await store.createTask(title: "Parent", supervisorTask: "...")
        guard let parentID else { return XCTFail("task creation failed") }

        commitWithin(store.delegationLoopWatcher, parentID, content: loopText())

        XCTAssertNil(
            store.delegationLoopWatcher._testLastTrigger(forTaskID: parentID),
            "Top-level task must not register a trigger — no parent awaiter to wake"
        )
    }

    /// Clean output on a child task: detector returns nil, watcher does
    /// nothing. Sanity check that the gating logic doesn't false-positive.
    func testWatcher_childTask_cleanOutput_noTrigger() async {
        let (store, childID) = await makeChildTaskWithAwaiter()

        commitWithin(store.delegationLoopWatcher, childID, content: cleanText())

        XCTAssertNil(store.delegationLoopWatcher._testLastTrigger(forTaskID: childID),
                     "Clean child output must not trigger interrupt")
    }

    // MARK: - Trigger happy path

    /// Child task with looping output AND a parent awaiter: watcher fires
    /// `notifyDelegationInterrupt` and records the trigger time for cooldown.
    /// The awaiter resumes with `.parentMessageQueued(text:)` — exactly the
    /// same shape as a Supervisor-driven interrupt.
    func testWatcher_childTask_loopOutput_firesInterrupt_andRecordsCooldown() async {
        let (store, childID) = await makeChildTaskWithAwaiter()

        // Spawn a stand-in handler that registers a waiter on the awaiter
        // — the watcher's wake call needs SOMETHING to wake.
        let outcomeBox = OutcomeBox()
        let handlerTask = Task { @MainActor in
            outcomeBox.value = await store.completionAwaiter.register(taskID: childID)
        }
        var attempts = 0
        while !store.completionAwaiter.hasWaiters(for: childID), attempts < 50 {
            try? await Task.sleep(for: .milliseconds(1))
            attempts += 1
        }
        XCTAssertTrue(store.completionAwaiter.hasWaiters(for: childID),
                      "Test setup invariant: awaiter must have a waiter before we fire")

        commitWithin(store.delegationLoopWatcher, childID, content: loopText())

        // The handler task must resume with a parentMessageQueued outcome.
        await handlerTask.value
        guard let outcome = outcomeBox.value else {
            return XCTFail("Handler did not resume after watcher fired")
        }
        guard case .parentMessageQueued(let text) = outcome else {
            return XCTFail("Expected .parentMessageQueued outcome, got \(outcome)")
        }
        XCTAssertTrue(text.contains("Auto-detected loop"),
                      "Diagnostic text must mark this as auto-detection so the role's LLM disambiguates from a human-queued message; got: \(text)")

        XCTAssertNotNil(
            store.delegationLoopWatcher._testLastTrigger(forTaskID: childID),
            "Cooldown timestamp must be recorded after a successful fire"
        )
    }

    /// After firing once, the same child task can't fire again until the
    /// cooldown window passes. Without this, a `resume_delegation` on a
    /// genuinely-stuck team would re-fire on the next token, trapping the
    /// role in a loop of paused envelopes.
    func testWatcher_cooldown_blocksSecondFire() async {
        let (store, childID) = await makeChildTaskWithAwaiter()

        // First fire — record cooldown.
        let outcomeBox = OutcomeBox()
        let handler1 = Task { @MainActor in
            outcomeBox.value = await store.completionAwaiter.register(taskID: childID)
        }
        var attempts = 0
        while !store.completionAwaiter.hasWaiters(for: childID), attempts < 50 {
            try? await Task.sleep(for: .milliseconds(1))
            attempts += 1
        }
        commitWithin(store.delegationLoopWatcher, childID, content: loopText())
        await handler1.value
        let firstTrigger = store.delegationLoopWatcher._testLastTrigger(forTaskID: childID)
        XCTAssertNotNil(firstTrigger)

        // Second fire on the same child: register a fresh waiter, fire
        // again — must NOT wake.
        let outcomeBox2 = OutcomeBox()
        let handler2 = Task { @MainActor in
            outcomeBox2.value = await store.completionAwaiter.register(taskID: childID)
        }
        attempts = 0
        while !store.completionAwaiter.hasWaiters(for: childID), attempts < 50 {
            try? await Task.sleep(for: .milliseconds(1))
            attempts += 1
        }
        commitWithin(store.delegationLoopWatcher, childID, content: loopText())

        // Give the (non-)wake a moment, then cancel the awaiter and verify
        // it never resumed via the watcher path.
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(outcomeBox2.value,
                     "Watcher must NOT fire while in cooldown — second handler must still be suspended")
        store.completionAwaiter.cancelAll(taskID: childID)
        await handler2.value

        // Cooldown timestamp must not have advanced (no successful re-fire).
        XCTAssertEqual(
            firstTrigger,
            store.delegationLoopWatcher._testLastTrigger(forTaskID: childID),
            "Cooldown timestamp must not advance on suppressed second fire"
        )
    }

    // MARK: - noteStreamLoop (in-stream signal → parent interrupt)

    /// Detection now runs in `performStreamingCall`; the watcher's streaming entry
    /// is `noteStreamLoop`, which fires the parent interrupt given a `LoopSignal`.
    /// A successful fire records cooldown and returns `true` (advance the in-stream
    /// throttle baseline). The user's reasoning-model-stuck (thinking-only) case is
    /// detected by `LoopScanner.scanStreaming` (see `LoopScannerTests`); here we pin
    /// the fire/cooldown/advance contract.
    func testWatcher_noteStreamLoop_firesInterrupt_andRecordsCooldown() async {
        let (store, childID) = await makeChildTaskWithAwaiter()

        let outcomeBox = OutcomeBox()
        let handlerTask = Task { @MainActor in
            outcomeBox.value = await store.completionAwaiter.register(taskID: childID)
        }
        var attempts = 0
        while !store.completionAwaiter.hasWaiters(for: childID), attempts < 50 {
            try? await Task.sleep(for: .milliseconds(1))
            attempts += 1
        }

        let advance = store.delegationLoopWatcher.noteStreamLoop(
            taskID: childID, stepID: "engineer",
            signal: .withinMessage(diagnostic: "Oh wait Oh wait Oh wait"))

        await handlerTask.value
        guard let outcome = outcomeBox.value else {
            return XCTFail("noteStreamLoop must fire the parent interrupt on a signal")
        }
        guard case .parentMessageQueued = outcome else {
            return XCTFail("Expected .parentMessageQueued from noteStreamLoop, got \(outcome)")
        }
        XCTAssertTrue(advance, "A successful fire advances the in-stream throttle baseline (returns true)")
        XCTAssertNotNil(
            store.delegationLoopWatcher._testLastTrigger(forTaskID: childID),
            "Cooldown timestamp must be recorded after the fire"
        )
    }

    /// I4: when `notifyDelegationInterrupt` returns false (no waiter — the race
    /// between `setActiveDelegation` and `awaitTaskTerminalState`), `noteStreamLoop`
    /// returns `false` so the in-stream scanner does NOT advance its throttle
    /// baseline — it keeps re-scanning until the awaiter registers. Cooldown is also
    /// not set. This is the I4 invariant relocated from the old throttle-stamp logic.
    func testWatcher_noteStreamLoop_noWaiter_returnsFalse_andNoCooldown() async {
        let (store, childID) = await makeChildTaskWithAwaiter()
        XCTAssertFalse(store.completionAwaiter.hasWaiters(for: childID),
                       "Test setup invariant: no waiter must be registered to exercise the race")

        let advance = store.delegationLoopWatcher.noteStreamLoop(
            taskID: childID, stepID: "engineer", signal: .withinMessage(diagnostic: "loop"))

        XCTAssertFalse(advance,
                       "I4: no-waiter race must return false so the in-stream throttle holds and re-scans")
        XCTAssertNil(store.delegationLoopWatcher._testLastTrigger(forTaskID: childID),
                     "Cooldown must NOT be set on a failed fire")
    }

    /// In cooldown, `noteStreamLoop` returns `true` (advance the throttle — no point
    /// re-scanning while the parent role's reaction plays out) without firing again.
    func testWatcher_noteStreamLoop_inCooldown_returnsTrue_doesNotRefire() async {
        let (store, childID) = await makeChildTaskWithAwaiter()
        // MUST be a MonotonicClock stamp: `isInCooldown` compares it against
        // `MonotonicClock.shared.now()`, which drifts arbitrarily far ahead of wall
        // clock over a test worker's lifetime. A `Date()` here reads as expired once
        // that drift exceeds the cooldown window — the old parallel-run flake.
        // See `testWatcher_cooldown_holdsUnderMonotonicClockDrift`.
        store.delegationLoopWatcher._testForceTrigger(
            forTaskID: childID, at: MonotonicClock.shared.now())
        let trigger = store.delegationLoopWatcher._testLastTrigger(forTaskID: childID)

        let advance = store.delegationLoopWatcher.noteStreamLoop(
            taskID: childID, stepID: "engineer", signal: .withinMessage(diagnostic: "loop"))

        XCTAssertTrue(advance, "In cooldown → advance the in-stream throttle (returns true)")
        XCTAssertEqual(store.delegationLoopWatcher._testLastTrigger(forTaskID: childID), trigger,
                       "Cooldown must suppress a re-fire (trigger timestamp unchanged)")
    }

    /// The shared `MonotonicClock` returns `max(Date(), last + 1ms)` and only
    /// `reset()` heals it, so it runs ahead of wall clock by
    /// (rapid calls × 1ms − elapsed wall time) — roughly 20,000× faster than real
    /// time. By the time a long-running test worker reaches this class the shared
    /// clock can be tens of seconds ahead of `Date()`. A cooldown stamp planted on
    /// the WRONG clock then reads as already-expired, `isInCooldown` returns false,
    /// the watcher fires, finds no waiter, and `noteStreamLoop` returns false.
    ///
    /// That was the mechanism behind the long-standing parallel-run flake in
    /// `testWatcher_noteStreamLoop_inCooldown_returnsTrue_doesNotRefire` (green in
    /// isolation and serially, ~3/10 in parallel — purely a function of how much
    /// drift the worker accumulated before scheduling this class). This test forces
    /// the condition instead of leaving it to scheduling luck.
    func testWatcher_cooldown_holdsUnderMonotonicClockDrift() async {
        // Never leak drift into whatever class runs next in this worker process.
        defer { MonotonicClock.shared.reset() }

        // Simulate a worker that already pushed the shared clock past the cooldown
        // window. Each saturated call advances it 1ms; the burst costs ~ms of wall time.
        let burst = Int(DelegationConstants.repetitionCooldownSeconds / 0.001) + 10_000
        for _ in 0..<burst { _ = MonotonicClock.shared.now() }
        XCTAssertGreaterThan(
            MonotonicClock.shared.now().timeIntervalSince(Date()),
            DelegationConstants.repetitionCooldownSeconds,
            "Setup invariant: drift must exceed the cooldown window to exercise the regression")

        let (store, childID) = await makeChildTaskWithAwaiter()
        store.delegationLoopWatcher._testForceTrigger(
            forTaskID: childID, at: MonotonicClock.shared.now())

        let advance = store.delegationLoopWatcher.noteStreamLoop(
            taskID: childID, stepID: "engineer", signal: .withinMessage(diagnostic: "loop"))

        XCTAssertTrue(
            advance,
            "Cooldown must hold under monotonic drift — the planted stamp and the comparison must come from the same clock")
    }

    /// Top-level (non-delegated) task must NOT fire from `noteStreamLoop` — same
    /// child-task gating as every other hook. Returns true (advance) since there's
    /// nothing to re-scan for.
    func testWatcher_noteStreamLoop_topLevelTask_noFire() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)
        guard let parentID = await store.createTask(title: "Parent", supervisorTask: "...") else {
            return XCTFail("task creation failed")
        }

        let advance = store.delegationLoopWatcher.noteStreamLoop(
            taskID: parentID, stepID: "any", signal: .withinMessage(diagnostic: "loop"))

        XCTAssertTrue(advance, "Top-level isn't watched here → advance, don't re-scan")
        XCTAssertNil(store.delegationLoopWatcher._testLastTrigger(forTaskID: parentID),
                     "Top-level task must not register a trigger — no parent awaiter to wake")
    }

    // MARK: - Across-messages hook

    /// `considerCommitted`'s across-messages branch gets the role's recent
    /// assistant outputs after each commit. When ≥2 of the last 3 messages have
    /// high pairwise overlap, the watcher fires — catches strategic loops
    /// where each iteration regenerates similar content.
    func testWatcher_acrossMessagesHook_firesOnConversationOverlap() async {
        let (store, childID) = await makeChildTaskWithAwaiter()

        let outcomeBox = OutcomeBox()
        let handlerTask = Task { @MainActor in
            outcomeBox.value = await store.completionAwaiter.register(taskID: childID)
        }
        var attempts = 0
        while !store.completionAwaiter.hasWaiters(for: childID), attempts < 50 {
            try? await Task.sleep(for: .milliseconds(1))
            attempts += 1
        }

        let nearly = """
            I'll read js/calculator.js and js/app.js to understand the buttons \
            logic, then propose a fix for the broken handlers in the keypad \
            event listener.
            """
        let messages = [
            "First, let me list the project files to ground myself.",
            nearly,
            nearly + " (Trying again with a slightly different approach.)",
            nearly + " (One more time — same general direction.)",
        ]

        commitAcross(store.delegationLoopWatcher, childID, messages: messages)

        await handlerTask.value
        guard let outcome = outcomeBox.value else {
            return XCTFail("Across-messages hook must fire on high-overlap recent outputs")
        }
        guard case .parentMessageQueued(let text) = outcome else {
            return XCTFail("Expected .parentMessageQueued from across-messages hook")
        }
        XCTAssertTrue(text.contains("across messages"),
                      "Diagnostic must mention scope so the role's LLM understands which detector fired; got: \(text)")
    }

    // MARK: - Cooldown spans hook types

    /// Cooldown is keyed by child task id, not by hook type — once a fire
    /// records the timestamp, BOTH the streaming hook AND the post-commit
    /// hook must respect it. Without this guarantee a streaming-detected
    /// loop could be re-fired by the commit hook moments later, trapping
    /// the role in back-to-back paused envelopes.
    func testWatcher_cooldown_spansHookTypes() async {
        let (store, childID) = await makeChildTaskWithAwaiter()

        // First fire via post-commit hook (records cooldown).
        let outcomeBox1 = OutcomeBox()
        let handler1 = Task { @MainActor in
            outcomeBox1.value = await store.completionAwaiter.register(taskID: childID)
        }
        var attempts = 0
        while !store.completionAwaiter.hasWaiters(for: childID), attempts < 50 {
            try? await Task.sleep(for: .milliseconds(1))
            attempts += 1
        }
        commitWithin(store.delegationLoopWatcher, childID, content: loopText())
        await handler1.value
        let firstTrigger = store.delegationLoopWatcher._testLastTrigger(forTaskID: childID)
        XCTAssertNotNil(firstTrigger)

        // Second fire via the streaming entry (noteStreamLoop) on same child —
        // must be blocked by cooldown (different hook type, same task).
        let outcomeBox2 = OutcomeBox()
        let handler2 = Task { @MainActor in
            outcomeBox2.value = await store.completionAwaiter.register(taskID: childID)
        }
        attempts = 0
        while !store.completionAwaiter.hasWaiters(for: childID), attempts < 50 {
            try? await Task.sleep(for: .milliseconds(1))
            attempts += 1
        }
        _ = store.delegationLoopWatcher.noteStreamLoop(
            taskID: childID, stepID: "engineer", signal: .withinMessage(diagnostic: "loop"))

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(outcomeBox2.value,
                     "Cooldown must span hook types — noteStreamLoop must NOT re-fire while a recent commit-hook fire is in cooldown")
        store.completionAwaiter.cancelAll(taskID: childID)
        await handler2.value

        XCTAssertEqual(firstTrigger, store.delegationLoopWatcher._testLastTrigger(forTaskID: childID),
                       "Cooldown timestamp must not advance on suppressed cross-hook-type fire")
    }

    // The per-step streaming THROTTLE and its I4 stamp logic moved into
    // `performStreamingCall`'s in-stream growth-counter (the watcher no longer owns
    // `lastStreamingScanByStep`). The I4 invariant is now pinned at the watcher
    // boundary by `testWatcher_noteStreamLoop_noWaiter_returnsFalse_andNoCooldown`
    // (the scanner honors that bool to hold/advance its baseline), and the cadence
    // throttle itself is exercised by the in-stream tests.

    // MARK: - Tool-call sequence hook

    /// Three identical `(name, argsJSON)` triples on a child task with a
    /// registered awaiter must wake the parent with a `.parentMessageQueued`
    /// outcome whose text marks the scope as "tool-call repetition". Pins
    /// the tool-spam loop case where every assistant turn has empty
    /// `content` (Harmony tool-call markers stripped) — the across-messages
    /// hook can't see these structurally.
    func testWatcher_toolCallSequenceHook_firesOnIdenticalCalls() async {
        let (store, childID) = await makeChildTaskWithAwaiter()

        let outcomeBox = OutcomeBox()
        let handlerTask = Task { @MainActor in
            outcomeBox.value = await store.completionAwaiter.register(taskID: childID)
        }
        var attempts = 0
        while !store.completionAwaiter.hasWaiters(for: childID), attempts < 50 {
            try? await Task.sleep(for: .milliseconds(1))
            attempts += 1
        }
        XCTAssertTrue(store.completionAwaiter.hasWaiters(for: childID),
                      "Test setup invariant: awaiter must be registered before we fire")

        let now = MonotonicClock.shared.now()
        let calls: [(name: String, argsJSON: String, createdAt: Date)] = [
            (name: "read_file", argsJSON: #"{"path":"script.js"}"#, createdAt: now.addingTimeInterval(-4)),
            (name: "read_file", argsJSON: #"{"path":"script.js"}"#, createdAt: now.addingTimeInterval(-2)),
            (name: "read_file", argsJSON: #"{"path":"script.js"}"#, createdAt: now),
        ]
        commitTools(store.delegationLoopWatcher, childID, calls: calls)

        await handlerTask.value
        guard let outcome = outcomeBox.value else {
            return XCTFail("Tool-call sequence hook must fire on three identical calls")
        }
        guard case .parentMessageQueued(let text) = outcome else {
            return XCTFail("Expected .parentMessageQueued, got \(outcome)")
        }
        XCTAssertTrue(text.contains("tool-call repetition"),
                      "Diagnostic must mark scope so the parent role's LLM understands which detector fired; got: \(text)")
        XCTAssertTrue(text.contains("read_file"),
                      "Diagnostic must surface the spammed tool name; got: \(text)")
        XCTAssertNotNil(store.delegationLoopWatcher._testLastTrigger(forTaskID: childID),
                        "Successful fire must record cooldown timestamp")
    }

    /// Top-level (non-delegated) task must NOT trigger — child-task gating
    /// regression. Same contract as the other hooks.
    func testWatcher_toolCallSequenceHook_topLevelTask_noTrigger() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        await store.openWorkFolder(root)
        let parentID = await store.createTask(title: "Parent", supervisorTask: "...")
        guard let parentID else { return XCTFail("task creation failed") }

        let now = MonotonicClock.shared.now()
        let calls: [(name: String, argsJSON: String, createdAt: Date)] = Array(
            repeating: (name: "read_file", argsJSON: #"{"path":"x"}"#, createdAt: now),
            count: 100
        )
        commitTools(store.delegationLoopWatcher, parentID, calls: calls)

        XCTAssertNil(
            store.delegationLoopWatcher._testLastTrigger(forTaskID: parentID),
            "Top-level task must not register a trigger from any hook — no parent awaiter to wake"
        )
    }

    /// Cooldown is keyed by child task id and is shared across detection modes —
    /// after a successful within-message fire via `considerCommitted`, a subsequent
    /// tool-call-sequence `considerCommitted` on the same child must be suppressed.
    /// Without this, a long thinking-loop fire followed by a tool-spam loop
    /// in the same conversation would trap the role in back-to-back paused
    /// envelopes.
    func testWatcher_toolCallSequenceHook_cooldown_blocksAfterCommittedFire() async {
        let (store, childID) = await makeChildTaskWithAwaiter()

        // First fire via post-commit hook.
        let outcomeBox1 = OutcomeBox()
        let handler1 = Task { @MainActor in
            outcomeBox1.value = await store.completionAwaiter.register(taskID: childID)
        }
        var attempts = 0
        while !store.completionAwaiter.hasWaiters(for: childID), attempts < 50 {
            try? await Task.sleep(for: .milliseconds(1))
            attempts += 1
        }
        commitWithin(store.delegationLoopWatcher, childID, content: loopText())
        await handler1.value
        let firstTrigger = store.delegationLoopWatcher._testLastTrigger(forTaskID: childID)
        XCTAssertNotNil(firstTrigger, "First fire must record cooldown")

        // Second fire via tool-call-sequence hook on the same child — must be
        // blocked by cooldown.
        let outcomeBox2 = OutcomeBox()
        let handler2 = Task { @MainActor in
            outcomeBox2.value = await store.completionAwaiter.register(taskID: childID)
        }
        attempts = 0
        while !store.completionAwaiter.hasWaiters(for: childID), attempts < 50 {
            try? await Task.sleep(for: .milliseconds(1))
            attempts += 1
        }
        let now = MonotonicClock.shared.now()
        let calls: [(name: String, argsJSON: String, createdAt: Date)] = Array(
            repeating: (name: "read_file", argsJSON: #"{"path":"x"}"#, createdAt: now),
            count: 3
        )
        commitTools(store.delegationLoopWatcher, childID, calls: calls)

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(outcomeBox2.value,
                     "Cooldown must span hook types — tool-call hook must NOT re-fire while a recent commit-hook fire is in cooldown")
        store.completionAwaiter.cancelAll(taskID: childID)
        await handler2.value
        XCTAssertEqual(firstTrigger, store.delegationLoopWatcher._testLastTrigger(forTaskID: childID),
                       "Cooldown timestamp must not advance on suppressed cross-hook-type fire")
    }

    /// `createdAt` filter regression: after a successful fire, `step.toolCalls`
    /// from a revision restart can still hold the previous round's identical
    /// tail (`resetStepForRevision` retains tool history for audit). Once the
    /// 30s cooldown expires (which often happens during a single revision
    /// turn), the very first new call would land on a suffix where most
    /// entries are old-and-already-counted. The watcher must filter
    /// `recentCalls` by `createdAt > lastTriggerByChildTask[taskID]` BEFORE
    /// invoking the (stateless) detector — otherwise we'd punish the role
    /// for behavior we already paused on.
    func testWatcher_toolCallSequenceHook_revisionRetainedHistory_doesNotFalsePositive() async {
        let (store, childID) = await makeChildTaskWithAwaiter()

        // Manually plant a `lastTrigger` to simulate "we already fired once
        // on this child a moment ago, cooldown has since expired".
        let firstTriggerAt = MonotonicClock.shared.now().addingTimeInterval(-120) // 2 min ago, well past 30s cooldown
        store.delegationLoopWatcher._testForceTrigger(forTaskID: childID, at: firstTriggerAt)

        // Simulate revision-retained history: 5 identical calls all from
        // BEFORE the first trigger (i.e. round-1 history that
        // resetStepForRevision left in `step.toolCalls`), plus 1 fresh
        // identical call from the current round.
        let beforeTrigger = firstTriggerAt.addingTimeInterval(-10)
        let afterTrigger = firstTriggerAt.addingTimeInterval(60)
        let calls: [(name: String, argsJSON: String, createdAt: Date)] = [
            (name: "read_file", argsJSON: #"{"path":"x"}"#, createdAt: beforeTrigger),
            (name: "read_file", argsJSON: #"{"path":"x"}"#, createdAt: beforeTrigger),
            (name: "read_file", argsJSON: #"{"path":"x"}"#, createdAt: beforeTrigger),
            (name: "read_file", argsJSON: #"{"path":"x"}"#, createdAt: beforeTrigger),
            (name: "read_file", argsJSON: #"{"path":"x"}"#, createdAt: beforeTrigger),
            (name: "read_file", argsJSON: #"{"path":"x"}"#, createdAt: afterTrigger),
        ]

        // Register an awaiter so a fire WOULD wake it — if the hook ignored
        // the cutoff it would deliver outcome here.
        let outcomeBox = OutcomeBox()
        let handlerTask = Task { @MainActor in
            outcomeBox.value = await store.completionAwaiter.register(taskID: childID)
        }
        var attempts = 0
        while !store.completionAwaiter.hasWaiters(for: childID), attempts < 50 {
            try? await Task.sleep(for: .milliseconds(1))
            attempts += 1
        }

        commitTools(store.delegationLoopWatcher, childID, calls: calls)

        // Filter must reduce the visible suffix to just 1 fresh call → below
        // minRepeats=3 → no fire. Awaiter stays suspended.
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(
            outcomeBox.value,
            "createdAt filter must drop pre-trigger history; visible suffix is below minRepeats so no fire"
        )
        store.completionAwaiter.cancelAll(taskID: childID)
        await handlerTask.value

        // lastTrigger must not have advanced — the original timestamp stays
        // (we manually planted it via _testForceTrigger).
        XCTAssertEqual(
            store.delegationLoopWatcher._testLastTrigger(forTaskID: childID),
            firstTriggerAt,
            "Suppressed fire must not advance the trigger timestamp"
        )
    }

    /// Counter-test for the previous one: 3 identical calls all NEWER than
    /// the last trigger DO fire. Confirms the cutoff is `>` (strict), not
    /// `>=` or off-by-N.
    func testWatcher_toolCallSequenceHook_freshCallsAfterTrigger_doFire() async {
        let (store, childID) = await makeChildTaskWithAwaiter()

        // Plant lastTrigger in the past, well past the 30s cooldown.
        let firstTriggerAt = MonotonicClock.shared.now().addingTimeInterval(-120)
        store.delegationLoopWatcher._testForceTrigger(forTaskID: childID, at: firstTriggerAt)

        // 3 fresh calls after the trigger.
        let after = firstTriggerAt.addingTimeInterval(60)
        let calls: [(name: String, argsJSON: String, createdAt: Date)] = [
            (name: "read_file", argsJSON: #"{"path":"x"}"#, createdAt: after),
            (name: "read_file", argsJSON: #"{"path":"x"}"#, createdAt: after.addingTimeInterval(2)),
            (name: "read_file", argsJSON: #"{"path":"x"}"#, createdAt: after.addingTimeInterval(4)),
        ]

        let outcomeBox = OutcomeBox()
        let handlerTask = Task { @MainActor in
            outcomeBox.value = await store.completionAwaiter.register(taskID: childID)
        }
        var attempts = 0
        while !store.completionAwaiter.hasWaiters(for: childID), attempts < 50 {
            try? await Task.sleep(for: .milliseconds(1))
            attempts += 1
        }

        commitTools(store.delegationLoopWatcher, childID, calls: calls)

        await handlerTask.value
        guard let outcome = outcomeBox.value else {
            return XCTFail("3 calls newer than lastTrigger must fire — hook must not silently swallow legitimate post-cooldown loops")
        }
        guard case .parentMessageQueued = outcome else {
            return XCTFail("Expected .parentMessageQueued from tool-call hook, got \(outcome)")
        }
        XCTAssertNotEqual(
            store.delegationLoopWatcher._testLastTrigger(forTaskID: childID),
            firstTriggerAt,
            "Successful re-fire must advance the trigger timestamp"
        )
    }

    // MARK: - createdAt cutoff applies to within/across (not just tool-call)

    /// The unified `considerCommitted` applies the `lastTrigger` cutoff to ALL three
    /// modes — including within-message. A looping message from BEFORE the last fire
    /// (e.g. revision-retained `llmConversation`) must NOT re-fire after cooldown.
    /// (Pre-collapse, `considerCommittedMessage`/`considerConversation` had no cutoff;
    /// this pins the new, stricter — and correct — behavior.)
    func testWatcher_considerCommitted_withinMessage_preTriggerLoop_filteredOut() async {
        let (store, childID) = await makeChildTaskWithAwaiter()
        let firstTriggerAt = MonotonicClock.shared.now().addingTimeInterval(-120)  // past 30s cooldown
        store.delegationLoopWatcher._testForceTrigger(forTaskID: childID, at: firstTriggerAt)

        let outcomeBox = OutcomeBox()
        let handlerTask = Task { @MainActor in
            outcomeBox.value = await store.completionAwaiter.register(taskID: childID)
        }
        var attempts = 0
        while !store.completionAwaiter.hasWaiters(for: childID), attempts < 50 {
            try? await Task.sleep(for: .milliseconds(1)); attempts += 1
        }

        // A within-message loop in a message created BEFORE the last trigger.
        store.delegationLoopWatcher.considerCommitted(
            taskID: childID,
            recentAssistant: [(thinking: nil, content: loopText(), createdAt: firstTriggerAt.addingTimeInterval(-10))],
            toolCalls: [])

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(outcomeBox.value,
                     "A within-message loop in a pre-trigger message must be filtered by the cutoff — no re-fire")
        store.completionAwaiter.cancelAll(taskID: childID)
        await handlerTask.value
        XCTAssertEqual(store.delegationLoopWatcher._testLastTrigger(forTaskID: childID), firstTriggerAt)
    }

    /// Counter-test: a FRESH within-message loop (created after the last trigger,
    /// cooldown expired) DOES fire via `considerCommitted`.
    func testWatcher_considerCommitted_withinMessage_freshLoop_fires() async {
        let (store, childID) = await makeChildTaskWithAwaiter()
        let firstTriggerAt = MonotonicClock.shared.now().addingTimeInterval(-120)
        store.delegationLoopWatcher._testForceTrigger(forTaskID: childID, at: firstTriggerAt)

        let outcomeBox = OutcomeBox()
        let handlerTask = Task { @MainActor in
            outcomeBox.value = await store.completionAwaiter.register(taskID: childID)
        }
        var attempts = 0
        while !store.completionAwaiter.hasWaiters(for: childID), attempts < 50 {
            try? await Task.sleep(for: .milliseconds(1)); attempts += 1
        }

        store.delegationLoopWatcher.considerCommitted(
            taskID: childID,
            recentAssistant: [(thinking: nil, content: loopText(), createdAt: firstTriggerAt.addingTimeInterval(60))],
            toolCalls: [])

        await handlerTask.value
        guard case .parentMessageQueued(let text)? = outcomeBox.value else {
            return XCTFail("A fresh within-message loop must fire via considerCommitted")
        }
        XCTAssertTrue(text.contains("within-message"), "scope must be within-message; got: \(text)")
    }

    // MARK: - Across-messages with thinking (caller-side join contract)

    /// Tool-only assistant turns have empty `content` — Harmony tool-call
    /// markers get stripped before the message is committed. The caller in
    /// `NTMSOrchestrator+Streaming.commitStreaming` joins each message as
    /// `(thinking ?? "") + "\n" + content` so the across-messages mode
    /// still has signal to compare. Pins the contract: the watcher fires
    /// when callers feed pre-joined thinking strings even with empty
    /// content tails. Plain `\.content` mapping would collapse every entry
    /// below `minMessageChars` and silently no-op.
    func testWatcher_acrossMessagesHook_firesOnPreJoinedThinking_emptyContent() async {
        let (store, childID) = await makeChildTaskWithAwaiter()

        let outcomeBox = OutcomeBox()
        let handlerTask = Task { @MainActor in
            outcomeBox.value = await store.completionAwaiter.register(taskID: childID)
        }
        var attempts = 0
        while !store.completionAwaiter.hasWaiters(for: childID), attempts < 50 {
            try? await Task.sleep(for: .milliseconds(1))
            attempts += 1
        }

        // Caller joins thinking + content per message (production behavior).
        // Each thinking is the user-observed pattern: model reasoning about
        // re-reading the file after an edit, with mild per-iteration variation.
        let thinking = """
            I need to read the script.js file again to see its current state \
            after my last edit. The file should now have the backspace() method \
            added, but I need to verify this and then fix the formatNumber function.
            """
        let messages = [
            thinking + "\n",                                   // empty content suffix
            thinking + " Let me try again.\n",
            thinking + " One more time.\n",
            thinking + " Same approach.\n",
        ]

        commitAcross(store.delegationLoopWatcher, childID, messages: messages)

        await handlerTask.value
        guard let outcome = outcomeBox.value else {
            return XCTFail("Across-messages must fire on pre-joined thinking even with empty content tails — caller-side join contract")
        }
        guard case .parentMessageQueued(let text) = outcome else {
            return XCTFail("Expected .parentMessageQueued, got \(outcome)")
        }
        XCTAssertTrue(text.contains("across messages"),
                      "Diagnostic must mark scope; got: \(text)")
    }

    // MARK: - Helpers

    /// Creates a parent + child task pair where the child has the
    /// parentTaskID/parentRoleID metadata set so the watcher can resolve
    /// the parent role for `notifyDelegationInterrupt`.
    private func makeChildTaskWithAwaiter() async -> (NTMSOrchestrator, Int) {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        // Note: we intentionally don't `defer { try? FileManager.default.removeItem(at: root) }`
        // here — caller's defer in the test wraps it. Keeping creation
        // path self-contained but cleanup at the test boundary.
        await store.openWorkFolder(root)
        let parentID = await store.createTask(title: "Parent", supervisorTask: "x")!
        let childID = await store.createDelegatedTask(
            parentTaskID: parentID,
            parentRoleID: "coding_agent",
            title: "Child",
            supervisorTask: "y",
            preferredTeamID: nil,
            depth: 1
        )!
        // Stamp `activeDelegationChildID` on the parent step so any
        // hypothetical awaiter walking the metadata can find the link
        // (this also matches the production sequence inside
        // `handleDelegateToTeam`).
        await store.mutateTask(taskID: parentID) { task in
            var run = Run(id: 0, steps: [])
            run.steps.append(StepExecution(
                id: "coding_agent",
                role: .codingAgent,
                title: "Step",
                activeDelegationChildID: childID
            ))
            task.runs.append(run)
        }
        return (store, childID)
    }

    @MainActor
    private final class OutcomeBox {
        var value: TaskCompletionAwaiter.WaitOutcome?
    }
}
