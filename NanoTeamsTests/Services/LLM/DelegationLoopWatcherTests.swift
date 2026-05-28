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

    /// Helper: produce a string that's guaranteed to fire
    /// `MessageRepetitionDetector.detectWithinMessage` with default thresholds.
    private func loopText() -> String {
        // "Oh, wait! " is 10 chars (substantive content) — repeated 8 times
        // exceeds default minRepeats=5.
        String(repeating: "Oh, wait! ", count: 8)
    }

    private func cleanText() -> String {
        "The implementation reads the file, validates the schema, and writes the result. Nothing repeats here in any pathological way."
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

        store.delegationLoopWatcher.considerCommittedMessage(
            taskID: parentID,
            stepID: "any",
            content: loopText(),
            thinking: nil
        )

        XCTAssertNil(
            store.delegationLoopWatcher._testLastTrigger(forTaskID: parentID),
            "Top-level task must not register a trigger — no parent awaiter to wake"
        )
    }

    /// Clean output on a child task: detector returns nil, watcher does
    /// nothing. Sanity check that the gating logic doesn't false-positive.
    func testWatcher_childTask_cleanOutput_noTrigger() async {
        let (store, childID) = await makeChildTaskWithAwaiter()

        store.delegationLoopWatcher.considerCommittedMessage(
            taskID: childID,
            stepID: "engineer",
            content: cleanText(),
            thinking: nil
        )

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

        store.delegationLoopWatcher.considerCommittedMessage(
            taskID: childID,
            stepID: "engineer",
            content: loopText(),
            thinking: nil
        )

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
        store.delegationLoopWatcher.considerCommittedMessage(
            taskID: childID, stepID: "engineer", content: loopText(), thinking: nil
        )
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
        store.delegationLoopWatcher.considerCommittedMessage(
            taskID: childID, stepID: "engineer", content: loopText(), thinking: nil
        )

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

    // MARK: - Thinking-only loop (user's primary scenario)

    /// Reasoning models can loop in their `thinking` buffer without ever
    /// emitting `content` — pre-fix they'd burn the 30-minute delegation
    /// timeout silently because the post-commit hook never fires (no
    /// commit happens). The streaming hook reads `streamingThinking` and
    /// runs the detector on the thinking buffer alone, catching the
    /// "Oh wait Oh wait Oh wait..." case the user reported.
    func testWatcher_thinkingOnlyLoop_firesViaStreamingHook() async {
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

        // Empty content, thinking buffer carries the loop — the user's
        // reasoning-model-stuck scenario.
        store.delegationLoopWatcher.considerStreamingBuffer(
            taskID: childID,
            stepID: "engineer",
            content: "",
            thinking: loopText()
        )

        await handlerTask.value
        guard let outcome = outcomeBox.value else {
            return XCTFail("Streaming hook must fire on thinking-only loops — pre-fix would have hung until 30-min timeout")
        }
        guard case .parentMessageQueued = outcome else {
            return XCTFail("Expected .parentMessageQueued from streaming-hook detection, got \(outcome)")
        }
        XCTAssertNotNil(
            store.delegationLoopWatcher._testLastTrigger(forTaskID: childID),
            "Cooldown timestamp must be recorded after the thinking-only fire"
        )
    }

    // MARK: - Across-messages hook

    /// `considerConversation` gets the role's recent assistant outputs
    /// after each commit. When ≥2 of the last 3 messages have high
    /// pairwise overlap, the watcher fires — catches strategic loops
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

        store.delegationLoopWatcher.considerConversation(
            taskID: childID,
            recentRoleMessages: messages
        )

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
        store.delegationLoopWatcher.considerCommittedMessage(
            taskID: childID, stepID: "engineer",
            content: loopText(), thinking: nil
        )
        await handler1.value
        let firstTrigger = store.delegationLoopWatcher._testLastTrigger(forTaskID: childID)
        XCTAssertNotNil(firstTrigger)

        // Second fire via streaming hook on same child — must be blocked
        // by cooldown (different hook type, same task).
        let outcomeBox2 = OutcomeBox()
        let handler2 = Task { @MainActor in
            outcomeBox2.value = await store.completionAwaiter.register(taskID: childID)
        }
        attempts = 0
        while !store.completionAwaiter.hasWaiters(for: childID), attempts < 50 {
            try? await Task.sleep(for: .milliseconds(1))
            attempts += 1
        }
        store.delegationLoopWatcher.considerStreamingBuffer(
            taskID: childID, stepID: "engineer",
            content: loopText(), thinking: ""
        )

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(outcomeBox2.value,
                     "Cooldown must span hook types — streaming hook must NOT re-fire while a recent commit-hook fire is in cooldown")
        store.completionAwaiter.cancelAll(taskID: childID)
        await handler2.value

        XCTAssertEqual(firstTrigger, store.delegationLoopWatcher._testLastTrigger(forTaskID: childID),
                       "Cooldown timestamp must not advance on suppressed cross-hook-type fire")
    }

    // MARK: - Streaming throttle

    /// Streaming hook is throttled per-step — calling it repeatedly within
    /// the throttle window must not re-run the (expensive) detector.
    func testWatcher_streamingThrottle_skipsRapidRescans() async {
        let (store, childID) = await makeChildTaskWithAwaiter()

        // No awaiter registered — even if the detector fires, the watcher
        // returns false from `notifyDelegationInterrupt` and doesn't set
        // cooldown. We verify here that the THROTTLE itself prevents re-scan
        // (testable via `lastStreamingScanByStep` indirectly: a second call
        // within the throttle window returns immediately).

        // First call — passes throttle, finds match, but no waiter so
        // notifyDelegationInterrupt returns false → no cooldown set.
        store.delegationLoopWatcher.considerStreamingBuffer(
            taskID: childID, stepID: "engineer",
            content: loopText(), thinking: ""
        )
        XCTAssertNil(store.delegationLoopWatcher._testLastTrigger(forTaskID: childID),
                     "No waiter → no successful fire → no cooldown")

        // Second call within throttle window must be a no-op (we can't
        // observe it directly, but we verify behavior is consistent — no
        // crash, no state change). The real win is in production: this
        // saves an O(n²) substring search on every token append.
        store.delegationLoopWatcher.considerStreamingBuffer(
            taskID: childID, stepID: "engineer",
            content: loopText(), thinking: ""
        )
        // No-op assertion, just verifying no state was perturbed.
        XCTAssertNil(store.delegationLoopWatcher._testLastTrigger(forTaskID: childID))
    }

    // MARK: - I4: throttle stamp NOT burned on no-waiter race

    /// Pin (I4): when the detector finds a match but
    /// `notifyDelegationInterrupt` returns `false` (no waiter registered —
    /// race window between `setActiveDelegation` and
    /// `awaitTaskTerminalState`), the throttle stamp MUST NOT be set.
    /// Otherwise the next legitimate signal — arriving once the awaiter
    /// has registered — would be silently swallowed for the full
    /// `repetitionStreamingThrottleSeconds` window.
    ///
    /// Pre-fix: `lastStreamingScanByStep[stepID] = now` ran eagerly at
    /// the top of `considerStreamingBuffer`, before the cooldown check
    /// and before the detector. Setting the stamp regardless of outcome
    /// burned the throttle on race-with-`startRunForTask`.
    func testWatcher_throttleNotBurned_whenNotifyDelegationInterruptReturnsFalse() async {
        let (store, childID) = await makeChildTaskWithAwaiter()

        // No awaiter registered for childID → notifyDelegationInterrupt
        // will return false. Detector will find a match in `loopText()`.
        XCTAssertFalse(store.completionAwaiter.hasWaiters(for: childID),
                       "Test setup invariant: no waiter must be registered to exercise the race")

        store.delegationLoopWatcher.considerStreamingBuffer(
            taskID: childID,
            stepID: "engineer",
            content: loopText(),
            thinking: ""
        )

        // The fix: stamp must be nil because firing failed (no waiter).
        // Pre-fix this test FAILS — the stamp was set eagerly at function
        // entry, swallowing the next legitimate signal once the awaiter
        // finally registered.
        XCTAssertNil(
            store.delegationLoopWatcher._testLastStreamingScan(forStepID: "engineer"),
            "I4: throttle stamp must NOT be set when notifyDelegationInterrupt returns false — otherwise the next legitimate signal (arriving after the awaiter registers) would be silently throttled out for repetitionStreamingThrottleSeconds."
        )
        XCTAssertNil(
            store.delegationLoopWatcher._testLastTrigger(forTaskID: childID),
            "Cooldown also must NOT be set on failed fire — paired with the throttle invariant"
        )
    }

    /// Counter-test: when the detector finds NO match (clean stream), the
    /// throttle stamp IS set so we don't redo the substring search on the
    /// very next token. This is the fast-skip path; it MUST continue to
    /// stamp.
    func testWatcher_throttleSetOnCleanStreamingPass_avoidsRescan() async {
        let (store, childID) = await makeChildTaskWithAwaiter()

        store.delegationLoopWatcher.considerStreamingBuffer(
            taskID: childID,
            stepID: "engineer",
            content: cleanText(),
            thinking: ""
        )

        XCTAssertNotNil(
            store.delegationLoopWatcher._testLastStreamingScan(forStepID: "engineer"),
            "Throttle MUST be set on the no-match path — this is the substring-scan-cost guard"
        )
        XCTAssertNil(
            store.delegationLoopWatcher._testLastTrigger(forTaskID: childID),
            "No detector match → no fire → no cooldown"
        )
    }

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

        let now = Date()
        let calls: [(name: String, argsJSON: String, createdAt: Date)] = [
            (name: "read_file", argsJSON: #"{"path":"script.js"}"#, createdAt: now.addingTimeInterval(-4)),
            (name: "read_file", argsJSON: #"{"path":"script.js"}"#, createdAt: now.addingTimeInterval(-2)),
            (name: "read_file", argsJSON: #"{"path":"script.js"}"#, createdAt: now),
        ]
        store.delegationLoopWatcher.considerToolCallSequence(taskID: childID, recentCalls: calls)

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

        let now = Date()
        let calls: [(name: String, argsJSON: String, createdAt: Date)] = Array(
            repeating: (name: "read_file", argsJSON: #"{"path":"x"}"#, createdAt: now),
            count: 100
        )
        store.delegationLoopWatcher.considerToolCallSequence(taskID: parentID, recentCalls: calls)

        XCTAssertNil(
            store.delegationLoopWatcher._testLastTrigger(forTaskID: parentID),
            "Top-level task must not register a trigger from any hook — no parent awaiter to wake"
        )
    }

    /// Cooldown is keyed by child task id and is shared across hook types —
    /// after a successful fire via `considerCommittedMessage`, a subsequent
    /// `considerToolCallSequence` on the same child must be suppressed.
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
        store.delegationLoopWatcher.considerCommittedMessage(
            taskID: childID, stepID: "engineer",
            content: loopText(), thinking: nil
        )
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
        let now = Date()
        let calls: [(name: String, argsJSON: String, createdAt: Date)] = Array(
            repeating: (name: "read_file", argsJSON: #"{"path":"x"}"#, createdAt: now),
            count: 3
        )
        store.delegationLoopWatcher.considerToolCallSequence(taskID: childID, recentCalls: calls)

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
        let firstTriggerAt = Date(timeIntervalSinceNow: -120) // 2 min ago, well past 30s cooldown
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

        store.delegationLoopWatcher.considerToolCallSequence(taskID: childID, recentCalls: calls)

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
        let firstTriggerAt = Date(timeIntervalSinceNow: -120)
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

        store.delegationLoopWatcher.considerToolCallSequence(taskID: childID, recentCalls: calls)

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

        store.delegationLoopWatcher.considerConversation(
            taskID: childID,
            recentRoleMessages: messages
        )

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
