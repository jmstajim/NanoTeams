import XCTest

@testable import NanoTeams

/// End-to-end pins for the task-persistence stream split at the repository
/// boundary: `updateTaskOnly` strips + flushes, `loadTask` hydrates, legacy
/// blobs migrate on first mutation, and the raw-read guard refuses the one
/// shape that could truncate a log.
final class TaskStreamSplitTests: XCTestCase {

    var root: URL!
    var repository: NTMSRepository!
    var paths: NTMSPaths!
    let store = AtomicJSONStore()

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("split-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repository = NTMSRepository()
        paths = NTMSPaths(workFolderRoot: root)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        repository = nil
        paths = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeTask(withStep: Bool = true) throws -> Int {
        _ = try repository.openOrCreateWorkFolder(at: root)
        let id = try repository.createTask(at: root, title: "T", supervisorTask: "s").taskID
        if withStep {
            var task = try repository.loadTask(at: root, taskID: id)
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: "engineer", role: .softwareEngineer, title: "Work")
            ])]
            task.updatedAt = MonotonicClock.shared.now()
            try repository.updateTaskOnly(at: root, task: task)
        }
        return id
    }

    private func appendTurn(_ text: String, taskID: Int) throws {
        var task = try repository.loadTask(at: root, taskID: taskID)
        task.runs[0].steps[0].llmConversation.append(
            LLMMessage(role: .assistant, content: text))
        task.updatedAt = MonotonicClock.shared.now()
        try repository.updateTaskOnly(at: root, task: task)
    }

    private func rawTaskJSON(_ taskID: Int, ancestors: [Int] = []) throws -> String {
        String(data: try Data(contentsOf: paths.taskJSON(taskID: taskID, ancestors: ancestors)),
               encoding: .utf8) ?? ""
    }

    // MARK: - The headline: O(delta) appends

    /// Bytes written per append must not grow with the conversation — the old
    /// shape re-serialized every run's whole history per mutation (≈39 GB for
    /// an 18.3 MB task). Ratio pinned, not absolute bytes: 10× the appends must
    /// cost well under 10× the bytes-times-growth the quadratic shape paid.
    func testAppendCost_isFlatInConversationLength() throws {
        let id = try makeTask()
        let payload = String(repeating: "x", count: 4_096)

        func bytesFor(_ n: Int) throws -> Int {
            AtomicJSONStore._testResetBytesWritten()
            TaskStreamStore._testResetBytesWritten()
            for i in 0..<n { try appendTurn("\(payload) #\(i)", taskID: id) }
            return AtomicJSONStore._testBytesWritten() + TaskStreamStore._testBytesWritten()
        }

        let first = try bytesFor(20)
        let second = try bytesFor(200)
        XCTAssertLessThan(second, first * 15,
                          "10× the appends onto a 10×-longer history must stay ~10× the bytes "
                              + "(quadratic shape: ~100×); got \(first) → \(second)")
    }

    /// The frozen-history walk. `splittingStreams` visits every step of every run
    /// on EVERY `updateTaskOnly`, and `task.runs` is append-only with no cap
    /// (`RunService` is the only writer; a recurring task adds one run per
    /// firing). Appending one message to one step must not cost comparison work
    /// proportional to the whole task's history.
    ///
    /// Measured before the fix (`swiftc -O` model of the exact loop): 15.5 µs per
    /// frozen step, i.e. 4.65 ms per single mutation at 30 runs × 10 roles — all
    /// of it inside the process-global `tasksIndexLock`, where parallel roles
    /// (CLAUDE.md #45) queue behind it.
    ///
    /// Bytes cannot see this: an unchanged step emits no records and writes
    /// nothing. The bound is asserted on elements EXAMINED by the diff passes.
    func testFlushWork_isBoundedByTheChangedStep_notByFrozenHistory() throws {
        func diffWorkForAppend(frozenRuns: Int) throws -> Int {
            let id = try makeTask()
            var task = try repository.loadTask(at: root, taskID: id)
            task.runs = (0..<frozenRuns).map { runIndex in
                var run = Run(id: runIndex, steps: [
                    StepExecution(id: "engineer", role: .softwareEngineer, title: "Work")
                ])
                run.steps[0].llmConversation = (0..<20).map {
                    LLMMessage(role: .assistant, content: "run \(runIndex) turn \($0)")
                }
                return run
            }
            task.updatedAt = MonotonicClock.shared.now()
            try repository.updateTaskOnly(at: root, task: task)

            // Warm every step's diff baseline, then measure ONE append to the last run.
            task = try repository.loadTask(at: root, taskID: id)
            task.runs[frozenRuns - 1].steps[0].llmConversation.append(
                LLMMessage(role: .assistant, content: "the only change"))
            task.updatedAt = MonotonicClock.shared.now()
            TaskStreamStore._testResetDiffWork()
            try repository.updateTaskOnly(at: root, task: task)
            return TaskStreamStore._testDiffWork()
        }

        let shallow = try diffWorkForAppend(frozenRuns: 2)
        let deep = try diffWorkForAppend(frozenRuns: 20)
        XCTAssertGreaterThan(
            shallow, 0,
            "anti-vacuum: a counter that never increments satisfies any ceiling")
        XCTAssertLessThan(
            deep, shallow * 2,
            "10× the frozen history must not cost 10× the diff work — only the "
                + "changed step can have anything to diff; got \(shallow) → \(deep)")
    }

    /// THE test the O(1) gate exists to survive. `updateToolCallResult` edits a
    /// tool call IN PLACE — same element count, changed content — and so do
    /// `commitStreamingContent` and `applyRetryNotice`. DEBTS.md proposed gating
    /// the walk on `step.logCommit`, which carries only counts and a seq: that
    /// gate would skip exactly these three writers and silently drop every tool
    /// result from the log. The storage-identity gate cannot: the store retains
    /// the flushed buffer, so an in-place edit copies first and the addresses
    /// diverge.
    func testInPlaceToolResultEdit_reachesTheLog_despiteUnchangedCounts() throws {
        let id = try makeTask()
        var task = try repository.loadTask(at: root, taskID: id)
        let call = StepToolCall(name: ToolNames.readFile, argumentsJSON: #"{"path":"a.txt"}"#)
        task.runs[0].steps[0].toolCalls = [call]
        task.updatedAt = MonotonicClock.shared.now()
        try repository.updateTaskOnly(at: root, task: task)

        let flushed = try repository.loadTask(at: root, taskID: id)
        let countBefore = flushed.runs[0].steps[0].toolCalls.count
        XCTAssertNil(flushed.runs[0].steps[0].toolCalls[0].resultJSON)

        var edited = flushed
        TaskMutationService.updateToolCallResult(
            toolCallID: call.id, resultJSON: #"{"ok":true}"#, isError: false,
            stepID: "engineer", in: &edited)
        edited.updatedAt = MonotonicClock.shared.now()
        XCTAssertEqual(edited.runs[0].steps[0].toolCalls.count, countBefore,
                       "fixture must be the counts-unchanged shape the gate has to see through")
        try repository.updateTaskOnly(at: root, task: edited)

        let reread = try repository.loadTask(at: root, taskID: id)
        XCTAssertEqual(reread.runs[0].steps[0].toolCalls[0].resultJSON, #"{"ok":true}"#,
                       "an in-place edit that moves no count must still reach step_log.jsonl")
        XCTAssertEqual(reread.runs[0].steps[0].toolCalls[0].isError, false)
    }

    /// The other direction of the gate's one-sidedness: a whole-array REPLACEMENT
    /// with equal content (`saveLLMConversation` rebuilds the conversation from
    /// the wire) fails the identity test, falls through to the real diff, finds
    /// nothing, and returns the same stamp through `records.isEmpty` — no
    /// truncate, no duplicate records, no lost history.
    func testReplacedButEqualArray_fallsThroughAndChangesNothing() throws {
        let id = try makeTask()
        var task = try repository.loadTask(at: root, taskID: id)
        task.runs[0].steps[0].llmConversation = (0..<5).map {
            LLMMessage(role: .assistant, content: "turn \($0)")
        }
        task.updatedAt = MonotonicClock.shared.now()
        try repository.updateTaskOnly(at: root, task: task)

        let flushed = try repository.loadTask(at: root, taskID: id)
        var replaced = flushed
        // A genuinely FRESH buffer with identical elements. `Array(existingArray)`
        // is not enough — it can share storage, which sends this straight down the
        // fast path and makes the test vacuous. (It did: the "nothing changed"
        // branch this exists to reach showed up UNCOVERED in the coverage ratchet,
        // which is how the vacuity was found.) `map { $0 }` allocates.
        let original = flushed.runs[0].steps[0].llmConversation
        let rebuilt = original.map { $0 }
        XCTAssertFalse(
            rebuilt.withUnsafeBufferPointer({ $0.baseAddress })
                == original.withUnsafeBufferPointer({ $0.baseAddress }),
            "fixture must build a DIFFERENT buffer, or it never reaches the diff")
        XCTAssertEqual(rebuilt, original, "…carrying equal values")
        replaced.runs[0].steps[0].llmConversation = rebuilt
        replaced.updatedAt = MonotonicClock.shared.now()
        try repository.updateTaskOnly(at: root, task: replaced)

        let reread = try repository.loadTask(at: root, taskID: id)
        XCTAssertEqual(reread.runs[0].steps[0].llmConversation.map(\.content),
                       (0..<5).map { "turn \($0)" })
        XCTAssertEqual(reread.runs[0].steps[0].logCommit?.conversation, 5)
    }

    /// And the blob itself stops growing with the conversation.
    func testTaskJSON_sizeIsInvariantToConversationLength() throws {
        let id = try makeTask()
        try appendTurn(String(repeating: "a", count: 4_096), taskID: id)
        let small = try rawTaskJSON(id).count
        for i in 0..<50 { try appendTurn(String(repeating: "b", count: 4_096) + "#\(i)", taskID: id) }
        let large = try rawTaskJSON(id).count
        XCTAssertLessThan(large, small + 2_000,
                          "task.json carries metadata + the logCommit stamp, never the streams")
    }

    // MARK: - Round trip

    func testRoundTrip_allFourStreams_twice() throws {
        let id = try makeTask()
        var task = try repository.loadTask(at: root, taskID: id)
        task.runs[0].steps[0].llmConversation = [
            LLMMessage(role: .assistant, content: "turn", thinking: "thought")
        ]
        task.runs[0].steps[0].wireTranscript = [
            ChatMessage(role: .system, content: "sys"),
            ChatMessage(role: .user, content: "u"),
        ]
        task.runs[0].steps[0].toolCalls = [
            StepToolCall(name: "read_file", argumentsJSON: #"{"path":"a"}"#)
        ]
        task.runs[0].steps[0].messages = [StepMessage(role: .supervisor, content: "note")]
        task.runs[0].steps[0].scratchpad = "scratch survives in the blob"
        task.updatedAt = MonotonicClock.shared.now()
        try repository.updateTaskOnly(at: root, task: task)

        var back = try repository.loadTask(at: root, taskID: id)
        XCTAssertEqual(back.runs[0].steps[0].llmConversation.map(\.content), ["turn"])
        XCTAssertEqual(back.runs[0].steps[0].llmConversation.first?.thinking, "thought")
        XCTAssertEqual(back.runs[0].steps[0].wireTranscript.map(\.content), ["sys", "u"])
        XCTAssertEqual(back.runs[0].steps[0].toolCalls.map(\.name), ["read_file"])
        XCTAssertEqual(back.runs[0].steps[0].messages.map(\.content), ["note"])
        XCTAssertEqual(back.runs[0].steps[0].scratchpad, "scratch survives in the blob")
        XCTAssertTrue(back.streamsHydrated)

        // Second mutation + reload — catches baseline drift a single trip misses.
        back.runs[0].steps[0].llmConversation.append(LLMMessage(role: .assistant, content: "more"))
        back.updatedAt = MonotonicClock.shared.now()
        try repository.updateTaskOnly(at: root, task: back)
        let final = try repository.loadTask(at: root, taskID: id)
        XCTAssertEqual(final.runs[0].steps[0].llmConversation.map(\.content), ["turn", "more"])
    }

    // MARK: - Replacement paths

    func testToolResultFill_survivesReload() throws {
        let id = try makeTask()
        var task = try repository.loadTask(at: root, taskID: id)
        task.runs[0].steps[0].toolCalls = [
            StepToolCall(name: "read_file", argumentsJSON: #"{"path":"a"}"#)
        ]
        task.updatedAt = MonotonicClock.shared.now()
        try repository.updateTaskOnly(at: root, task: task)

        task.runs[0].steps[0].toolCalls[0].resultJSON = #"{"ok":true}"#
        task.updatedAt = MonotonicClock.shared.now()
        try repository.updateTaskOnly(at: root, task: task)

        let back = try repository.loadTask(at: root, taskID: id)
        XCTAssertEqual(back.runs[0].steps[0].toolCalls[0].resultJSON, #"{"ok":true}"#)
    }

    /// The repair shape: the wire transcript is replaced wholesale with a
    /// shorter-then-extended array — reload must match the replacement exactly.
    func testWireRepair_wholeArrayReplace_survivesReload() throws {
        let id = try makeTask()
        var task = try repository.loadTask(at: root, taskID: id)
        task.runs[0].steps[0].wireTranscript = [
            ChatMessage(role: .system, content: "sys"),
            ChatMessage(role: .assistant, content: "poisoned tail"),
        ]
        task.updatedAt = MonotonicClock.shared.now()
        try repository.updateTaskOnly(at: root, task: task)

        task.runs[0].steps[0].wireTranscript = [
            ChatMessage(role: .system, content: "sys"),
            ChatMessage(role: .assistant, content: "repaired"),
        ]
        task.updatedAt = MonotonicClock.shared.now()
        try repository.updateTaskOnly(at: root, task: task)

        let back = try repository.loadTask(at: root, taskID: id)
        XCTAssertEqual(back.runs[0].steps[0].wireTranscript.map(\.content), ["sys", "repaired"])
    }

    func testStepReset_clearsTheLogOnReload_siblingUntouched() throws {
        let id = try makeTask()
        var task = try repository.loadTask(at: root, taskID: id)
        task.runs[0].steps.append(
            StepExecution(id: "reviewer", role: .codeReviewer, title: "Review"))
        task.runs[0].steps[0].llmConversation = [LLMMessage(role: .assistant, content: "gone")]
        task.runs[0].steps[1].llmConversation = [LLMMessage(role: .assistant, content: "kept")]
        task.updatedAt = MonotonicClock.shared.now()
        try repository.updateTaskOnly(at: root, task: task)

        task.runs[0].steps[0].reset()
        task.updatedAt = MonotonicClock.shared.now()
        try repository.updateTaskOnly(at: root, task: task)

        let back = try repository.loadTask(at: root, taskID: id)
        XCTAssertTrue(back.runs[0].steps[0].llmConversation.isEmpty)
        XCTAssertEqual(back.runs[0].steps[1].llmConversation.map(\.content), ["kept"])
    }

    // MARK: - Migration (legacy embedded arrays)

    func testLegacyTask_readsIntact_migratesOnFirstMutation() throws {
        let id = try makeTask(withStep: false)
        // Legacy bytes BY HAND: embedded arrays, no logCommit — the shape every
        // pre-split task.json on disk has.
        var legacy = try store.read(NTMSTask.self, from: paths.taskJSON(taskID: id))
        var step = StepExecution(id: "engineer", role: .softwareEngineer, title: "Work")
        step.llmConversation = [LLMMessage(role: .assistant, content: "embedded turn")]
        step.toolCalls = [StepToolCall(name: "bash", argumentsJSON: #"{"cmd":"ls"}"#)]
        legacy.runs = [Run(id: 0, steps: [step])]
        try store.write(legacy, to: paths.taskJSON(taskID: id))
        XCTAssertTrue(try rawTaskJSON(id).contains("embedded turn"), "precondition: legacy bytes")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.stepLogJSONL(taskID: id, runID: 0, roleID: "engineer").path))

        // Reads intact through the legacy branch.
        var loaded = try repository.loadTask(at: root, taskID: id)
        XCTAssertEqual(loaded.runs[0].steps[0].llmConversation.map(\.content), ["embedded turn"])

        // First mutation converts: blob loses the arrays, the log gains them.
        loaded.runs[0].steps[0].llmConversation.append(LLMMessage(role: .assistant, content: "fresh"))
        loaded.updatedAt = MonotonicClock.shared.now()
        try repository.updateTaskOnly(at: root, task: loaded)

        XCTAssertFalse(try rawTaskJSON(id).contains("embedded turn"),
                       "the blob must not carry the conversation after conversion")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: paths.stepLogJSONL(taskID: id, runID: 0, roleID: "engineer").path))
        let back = try repository.loadTask(at: root, taskID: id)
        XCTAssertEqual(back.runs[0].steps[0].llmConversation.map(\.content),
                       ["embedded turn", "fresh"])
        XCTAssertEqual(back.runs[0].steps[0].toolCalls.map(\.name), ["bash"])
    }

    // MARK: - Delegation child layout

    func testDelegatedChild_logNestsUnderSubtasks() throws {
        _ = try repository.openOrCreateWorkFolder(at: root)
        let parent = try repository.createTask(at: root, title: "P", supervisorTask: "p").taskID
        let child = try repository.createTask(
            at: root, title: "C", supervisorTask: "c",
            parentTaskID: parent, parentRoleID: "engineer", delegationDepth: 1).taskID

        var task = try repository.loadTask(at: root, taskID: child)
        task.runs = [Run(id: 0, steps: [
            StepExecution(id: "engineer", role: .softwareEngineer, title: "Child work")
        ])]
        task.runs[0].steps[0].llmConversation = [LLMMessage(role: .assistant, content: "child turn")]
        task.updatedAt = MonotonicClock.shared.now()
        try repository.updateTaskOnly(at: root, task: task)

        let nested = paths.stepLogJSONL(
            taskID: child, runID: 0, roleID: "engineer", ancestors: [parent])
        XCTAssertTrue(nested.path.contains("subtasks"), "fixture sanity: the nested shape")
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.stepLogJSONL(taskID: child, runID: 0, roleID: "engineer").path),
        "never at the flat path")

        let back = try repository.loadTask(at: root, taskID: child)
        XCTAssertEqual(back.runs[0].steps[0].llmConversation.map(\.content), ["child turn"])
    }

    // MARK: - The unhydrated guard

    /// A RAW `store.read` of a split task carries empty arrays; feeding it to
    /// `updateTaskOnly` must throw, and the log must be byte-identical after.
    ///
    /// RED: drop the `streamsHydrated` guard → the diff reads the empties as a
    /// rollback, truncates the log, and the byte comparison fails.
    func testRawReadOfSplitTask_isRefused_andTheLogIsUntouched() throws {
        let id = try makeTask()
        try appendTurn("precious", taskID: id)
        let logURL = paths.stepLogJSONL(taskID: id, runID: 0, roleID: "engineer")
        let logBefore = try Data(contentsOf: logURL)

        var raw = try store.read(NTMSTask.self, from: paths.taskJSON(taskID: id))
        XCTAssertFalse(raw.streamsHydrated, "precondition: a raw read is unhydrated")
        raw.title = "Patched"
        raw.updatedAt = MonotonicClock.shared.now()

        XCTAssertThrowsError(try repository.updateTaskOnly(at: root, task: raw)) { error in
            guard case NTMSRepositoryError.unhydratedTask(let tid) = error else {
                return XCTFail("expected .unhydratedTask, got \(error)")
            }
            XCTAssertEqual(tid, id)
        }
        XCTAssertEqual(try Data(contentsOf: logURL), logBefore,
                       "the refusal must leave the log byte-identical")
    }

    /// Which mirrored `TaskSummary` facts a RAW read can still recompute.
    ///
    /// The heal in `NTMSRepository+Reconcile` patches `hasPendingSupervisorInput` back from
    /// the row for an unhydrated task, because that fact walks `step.toolCalls` — which the
    /// split STRIPS — so recomputing it would write a false `false` over a true row and wipe
    /// persisted seen-state. `hasRolesAwaitingAcceptance` is deliberately NOT in that patch
    /// list: it reads `run.roleStatuses` and `step.effectiveRoleID`, which the split does not
    /// touch.
    ///
    /// That exclusion rests on a claim about WHICH FIELDS `splittingStreams` strips, and the
    /// strip list can change — so the claim is pinned rather than trusted to a comment.
    /// RED: add `roleStatuses` to `splittingStreams`' strip list → the raw read recomputes the
    /// gate as `false` and the equality against the hydrated answer fails.
    ///
    /// What this does NOT pin, measured rather than assumed: adding the acceptance fact to
    /// the heal's `!streamsHydrated` patch list leaves this GREEN, because the fixture reads
    /// `toSummary()` directly and never traverses the heal (CLAUDE.md #56, reading 3). The
    /// residual defect there is mild and self-correcting — a split task's row would keep its
    /// stale value until the task's next `mutateTask` re-summarizes it — which is why the
    /// load-bearing property, and the one whose breakage would be silent, is pinned here
    /// instead of the patch list itself.
    func testRawReadOfSplitTask_recomputesTheAcceptanceGate_butNotTheSupervisorWait() throws {
        let id = try makeTask()
        var task = try repository.loadTask(at: root, taskID: id)
        task.runs[0].roleStatuses["engineer"] = .needsAcceptance
        task.runs[0].steps[0].status = .done
        // A pending `ask_supervisor` lives in `toolCalls` — a stream the split strips.
        task.runs[0].steps[0].needsSupervisorInput = true
        task.runs[0].steps[0].supervisorQuestion = "Which database?"
        task.runs[0].steps[0].llmConversation = [LLMMessage(role: .assistant, content: "turn")]
        task.updatedAt = MonotonicClock.shared.now()
        try repository.updateTaskOnly(at: root, task: task)

        let hydrated = try repository.loadTask(at: root, taskID: id)
        XCTAssertTrue(hydrated.streamsHydrated, "fixture sanity")
        XCTAssertEqual(hydrated.toSummary().hasRolesAwaitingAcceptance, true)

        let raw = try store.read(NTMSTask.self, from: paths.taskJSON(taskID: id))
        XCTAssertFalse(raw.streamsHydrated, "premise: this read is the unhydrated one")
        XCTAssertEqual(raw.toSummary().hasRolesAwaitingAcceptance, true,
                       "the acceptance gate survives a raw read — roleStatuses and step ids "
                           + "are not stream arrays, so the heal must NOT patch this field")
        XCTAssertEqual(raw.toSummary().hasRolesAwaitingAcceptance,
                       hydrated.toSummary().hasRolesAwaitingAcceptance,
                       "…and it agrees with the hydrated answer")
    }

    /// A step log that cannot be written must FAIL the mutation loudly —
    /// stripping the arrays from the blob after a silent flush failure would
    /// lose the delta with no trace. And the failure must be clean: the next
    /// mutation on a writable disk succeeds with nothing half-landed.
    func testUpdateTaskOnly_unwritableLog_throwsStepLogWriteFailed() throws {
        let id = try makeTask()
        try appendTurn("seed", taskID: id)  // materializes the log file
        let logURL = paths.stepLogJSONL(taskID: id, runID: 0, roleID: "engineer")

        // The log path becomes a directory: the delta append cannot open it.
        try FileManager.default.removeItem(at: logURL)
        try FileManager.default.createDirectory(at: logURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try {
            var task = try repository.loadTask(at: root, taskID: id)
            task.runs[0].steps[0].llmConversation.append(
                LLMMessage(role: .assistant, content: "one"))
            task.updatedAt = MonotonicClock.shared.now()
            try repository.updateTaskOnly(at: root, task: task)
        }()) { error in
            guard case NTMSRepositoryError.stepLogWriteFailed(let tid, let sid) = error else {
                return XCTFail("expected .stepLogWriteFailed, got \(error)")
            }
            XCTAssertEqual(tid, id)
            XCTAssertEqual(sid, "engineer")
        }

        try FileManager.default.removeItem(at: logURL)
        try appendTurn("two", taskID: id)
        let back = try repository.loadTask(at: root, taskID: id)
        XCTAssertEqual(back.runs[0].steps[0].llmConversation.map(\.content), ["two"],
                       "the failed mutation left nothing behind; the retry lands whole")
    }

    /// A split blob whose log FILE is gone (user deleted it, disk recovery):
    /// the load fails OPEN — empty streams, hydrated flag set — instead of
    /// refusing the whole task.
    func testLoadTask_splitBlobWithMissingLog_failsOpenEmpty() throws {
        let id = try makeTask()
        try appendTurn("gone", taskID: id)
        try FileManager.default.removeItem(
            at: paths.stepLogJSONL(taskID: id, runID: 0, roleID: "engineer"))

        let task = try repository.loadTask(at: root, taskID: id)

        XCTAssertTrue(task.streamsHydrated,
                      "fail-open hydration still counts as hydration — the task stays mutable")
        XCTAssertEqual(task.runs[0].steps[0].llmConversation, [],
                       "the lost log reads as empty, not as a crash")
        XCTAssertNotNil(task.runs[0].steps[0].logCommit,
                        "the stamp survives — the loss is observable, not laundered")
    }
}
