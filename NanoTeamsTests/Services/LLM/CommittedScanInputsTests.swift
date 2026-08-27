import XCTest
@testable import NanoTeams

/// Pins for `CommittedScanInputs` — the Domain→tuple boundary the committed loop scan
/// takes its arguments from — and for the WIRING that decides whether those arguments
/// get built at all.
///
/// Two separable properties, pinned separately (CLAUDE.md #60):
///
///  - **Equivalence.** The tail walk must return exactly what the eager
///    `filter { $0.role == .assistant }.suffix(limit)` returned. A regression here is
///    invisible in behaviour on the happy path and shows up as a loop detector that
///    scans the wrong turns.
///  - **Work.** It must EXAMINE only the tail. That is the whole point of the change,
///    it is invisible in the returned value, and the probe therefore lives inside the
///    walk rather than beside a call site (CLAUDE.md #62).
///
/// The call-site guard gets a source pin rather than a behavioural one: the change is a
/// condition AROUND a call, and a test that invokes the callee is vacuous by
/// construction (CLAUDE.md #57).
@MainActor
final class CommittedScanInputsTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private var base: Date!

    override func setUp() async throws {
        try await super.setUp()
        base = Date(timeIntervalSince1970: 1_000_000)
        CommittedScanInputProbe.reset()
    }

    override func tearDown() async throws {
        base = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func msg(_ role: LLMRole, _ content: String, _ offset: Int) -> LLMMessage {
        LLMMessage(createdAt: base.addingTimeInterval(Double(offset)),
                   role: role, content: content, thinking: role == .assistant ? "t\(offset)" : nil)
    }

    /// The spelling this replaced, transcribed verbatim so equivalence is checked
    /// against the ORIGINAL rather than against a restatement of it.
    private func eager(
        _ conversation: [LLMMessage], _ limit: Int
    ) -> [(thinking: String?, content: String, createdAt: Date)] {
        Array(conversation
            .filter { $0.role == .assistant }
            .suffix(limit)
            .map { (thinking: $0.thinking, content: $0.content, createdAt: $0.createdAt) })
    }

    private func assertSame(
        _ a: [(thinking: String?, content: String, createdAt: Date)],
        _ b: [(thinking: String?, content: String, createdAt: Date)],
        _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(a.count, b.count, message, file: file, line: line)
        for (x, y) in zip(a, b) {
            XCTAssertEqual(x.content, y.content, message, file: file, line: line)
            XCTAssertEqual(x.thinking, y.thinking, message, file: file, line: line)
            XCTAssertEqual(x.createdAt, y.createdAt, message, file: file, line: line)
        }
    }

    // MARK: - Equivalence

    /// Randomised, because hand-picked vectors are exactly what failed to separate a
    /// rejected windowing variant from the shipped one in an earlier wave: the
    /// discriminating input had to be searched for, not imagined.
    func testTailWalk_agreesWithTheEagerSpelling_onRandomisedConversations() {
        var rng = SystemRandomNumberGenerator()
        for trial in 0..<400 {
            let n = Int.random(in: 0...40, using: &rng)
            var conversation: [LLMMessage] = []
            for i in 0..<n {
                let roles: [LLMRole] = [.assistant, .user, .system, .tool]
                conversation.append(msg(roles[Int.random(in: 0..<roles.count, using: &rng)],
                                        "c\(i)", i))
            }
            for limit in [1, 2, 5, 9] {
                assertSame(
                    CommittedScanInputs.recentAssistantTurns(in: conversation, limit: limit),
                    eager(conversation, limit),
                    "trial \(trial), n=\(n), limit=\(limit): the tail walk must return exactly "
                        + "what `filter{}.suffix(limit)` returned")
            }
        }
    }

    /// Order is ARRAY order, not `createdAt` order — same as the spelling it replaces.
    /// Neither looks at timestamps, so an out-of-order conversation must not diverge.
    func testTailWalk_matchesArrayOrder_onAnOutOfOrderConversation() {
        let conversation = [
            msg(.assistant, "a", 9),
            msg(.user, "u", 1),
            msg(.assistant, "b", 3),
            msg(.assistant, "c", 2)
        ]
        assertSame(CommittedScanInputs.recentAssistantTurns(in: conversation, limit: 2),
                   eager(conversation, 2),
                   "out-of-order input must not make the two spellings disagree")
        XCTAssertEqual(
            CommittedScanInputs.recentAssistantTurns(in: conversation, limit: 2).map(\.content),
            ["b", "c"],
            "the last two ASSISTANT turns in array order")
    }

    // MARK: - Corner cases

    func testTailWalk_degenerateInputs() {
        XCTAssertTrue(CommittedScanInputs.recentAssistantTurns(in: [], limit: 5).isEmpty,
                      "empty conversation")
        XCTAssertTrue(
            CommittedScanInputs.recentAssistantTurns(in: [msg(.assistant, "a", 0)], limit: 0).isEmpty,
            "limit 0 must return nothing rather than everything — the guard is what stops "
                + "`tail.count == limit` from never matching")
        XCTAssertTrue(
            CommittedScanInputs.recentAssistantTurns(in: [msg(.user, "u", 0)], limit: 5).isEmpty,
            "no assistant turns at all")
        XCTAssertEqual(
            CommittedScanInputs.recentAssistantTurns(
                in: [msg(.assistant, "a", 0), msg(.assistant, "b", 1)], limit: 5).map(\.content),
            ["a", "b"],
            "fewer assistant turns than the limit must return all of them, oldest-first")
    }

    func testRecentToolCalls_lastKOldestFirst_andDegenerateInputs() {
        let calls = (0..<7).map { StepToolCall(name: "t\($0)", argumentsJSON: "{}") }
        XCTAssertEqual(CommittedScanInputs.recentToolCalls(in: calls, limit: 3).map(\.name),
                       ["t4", "t5", "t6"], "the LAST three, oldest-first")
        XCTAssertTrue(CommittedScanInputs.recentToolCalls(in: calls, limit: 0).isEmpty)
        XCTAssertTrue(CommittedScanInputs.recentToolCalls(in: [], limit: 3).isEmpty)
        XCTAssertEqual(CommittedScanInputs.recentToolCalls(in: calls, limit: 99).count, 7,
                       "a limit past the end returns everything, not a crash")
    }

    // MARK: - Work bound

    /// The property the change exists for. `examined` counts messages the walk LOOKED
    /// at; the eager spelling looked at all of them.
    func testTailWalk_examinesOnlyTheTail_notTheWholeConversation() {
        var conversation: [LLMMessage] = []
        for i in 0..<1_000 {
            conversation.append(msg(i % 2 == 0 ? .assistant : .user, "c\(i)", i))
        }
        CommittedScanInputProbe.reset()
        _ = CommittedScanInputs.recentAssistantTurns(in: conversation, limit: 5)
        let examined = CommittedScanInputProbe.examined()

        XCTAssertLessThanOrEqual(
            examined, 20,
            "the walk must stop once it has `limit` assistant turns. Examined \(examined) of "
                + "1000 — a whole-conversation pass here is Θ(N) per committed turn, i.e. Θ(N²) "
                + "across a chat session, on the MainActor")
        XCTAssertGreaterThan(
            examined, 0,
            "anti-vacuum: the probe must actually be reached, or the bound above is green "
                + "because nothing ran")
    }

    /// Anti-vacuum twin for the bound above: a conversation whose assistant turns are
    /// all at the FRONT genuinely costs a full walk, and the walk must not pretend
    /// otherwise by stopping early and returning the wrong turns.
    func testTailWalk_walksTheWholeConversationWhenItMust_andIsStillCorrect() {
        var conversation: [LLMMessage] = (0..<3).map { msg(.assistant, "a\($0)", $0) }
        conversation += (3..<500).map { msg(.user, "u\($0)", $0) }
        CommittedScanInputProbe.reset()
        let out = CommittedScanInputs.recentAssistantTurns(in: conversation, limit: 5)
        XCTAssertEqual(out.map(\.content), ["a0", "a1", "a2"],
                       "all three assistant turns, oldest-first")
        XCTAssertGreaterThan(CommittedScanInputProbe.examined(), 400,
                             "with fewer than `limit` assistant turns there is no tail to stop "
                                 + "at, and the walk is honestly Θ(N) — the bound in the sibling "
                                 + "test is a property of the DATA, not a promise the walk breaks")
    }

    // MARK: - Call-site wiring (CLAUDE.md #57 — pin the condition, not the callee)

    /// `commitStreaming` must ask the watcher BEFORE building the arguments. Building
    /// them first is the defect: on a task with no delegation every one of those tuples
    /// is discarded by `considerCommitted`'s own first guard.
    ///
    /// RED: move the `watchesCommitted` clause below the argument construction, or drop
    /// it → this fails on the ORDER, which is the only thing that distinguishes the fix
    /// from the defect (both compile, both behave identically).
    func testCommitSite_asksTheWatcherBeforeBuildingTheArguments() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LLM
            .deletingLastPathComponent()   // Services
            .deletingLastPathComponent()   // NanoTeamsTests
            .deletingLastPathComponent()   // repo root
        let path = "NanoTeams/Services/Core/NTMSOrchestrator+Streaming.swift"
        let url = repoRoot.appendingPathComponent(path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "\(path) not found — the #filePath derivation is broken and every "
                          + "assertion below would pass vacuously")
        // Strip line comments so this can only be satisfied by CODE: without it the pin
        // passes on a file where the guard was deleted and only its explanation remains.
        let src = try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .map { line -> String in
                guard let c = line.range(of: "//") else { return line }
                return String(line[line.startIndex..<c.lowerBound])
            }
            .joined(separator: "\n")

        guard let commit = src.range(of: "func commitStreaming") else {
            return XCTFail("commitStreaming not found — did the file move?")
        }
        let body = String(src[commit.upperBound...])
        guard let guardIdx = body.range(of: "watchesCommitted(taskID:") else {
            return XCTFail("commitStreaming no longer asks the watcher whether a committed "
                + "scan applies — every non-delegated task is back to walking "
                + "its conversation once per turn to build discarded tuples")
        }
        guard let buildIdx = body.range(of: "recentAssistantTurns(") else {
            return XCTFail("commitStreaming no longer builds the assistant tail — if the "
                + "committed scan was removed, remove this pin too; if it was "
                + "renamed, re-aim it (CLAUDE.md #104)")
        }
        XCTAssertLessThan(
            guardIdx.lowerBound, buildIdx.lowerBound,
            "the watcher must be asked BEFORE the arguments are built. Below it, the guard "
                + "still returns the right answer and still pays the whole cost")
    }

    // MARK: - The guard, through a real caller (CLAUDE.md #58)

    /// The structural pin above asserts the guard is spelled BEFORE the arguments; these
    /// two assert what it does. Both arms matter and neither is reachable from the other:
    ///
    ///  - a delegation CHILD must still get its committed scan, or the loop watcher that
    ///    the whole seam exists for goes deaf;
    ///  - a TOP-LEVEL task must build NOTHING, which is the saving.
    ///
    /// The child arm is also the one the coverage ratchet demanded: hoisting the guard
    /// made the whole argument-construction block unreachable for every existing test, and
    /// `NTMSOrchestrator+Streaming.swift` fell 99.3% -> 88.4% in one wave. A guard whose
    /// guarded side no test enters is a guard nobody has run.
    private func seedRunningStep(taskID: Int, stepID: String) async {
        await sut.mutateTask(taskID: taskID) { task in
            var step = StepExecution(id: stepID, role: .softwareEngineer,
                                     title: "Step", status: .running)
            step.llmConversation = [
                LLMMessage(role: .user, content: "go"),
                LLMMessage(role: .assistant, content: "working")
            ]
            step.toolCalls = [StepToolCall(name: "read_file", argumentsJSON: "{}")]
            task.runs = [Run(id: 0, steps: [step])]
        }
    }

    func testCommitStreaming_onADelegationChild_stillBuildsTheScanInputs() async throws {
        await sut.openWorkFolder(tempDir)
        guard let parentID = await sut.createTask(title: "Parent", supervisorTask: "x") else {
            return XCTFail("could not create the parent task")
        }
        guard let childID = await sut.createDelegatedTask(
            parentTaskID: parentID, parentRoleID: "coding_agent", title: "Child",
            supervisorTask: "y", preferredTeamID: nil, depth: 1) else {
            return XCTFail("could not create the delegated child")
        }
        await seedRunningStep(taskID: childID, stepID: "engineer")

        CommittedScanInputProbe.reset()
        await sut.commitStreaming(stepID: "engineer", taskID: childID,
                                  content: "hello", thinking: nil)

        XCTAssertGreaterThan(
            CommittedScanInputProbe.examined(), 0,
            "a delegation child must still build the committed-scan inputs — the guard "
                + "selects WHICH tasks pay, and skipping the children too would make "
                + "`DelegationLoopWatcher` deaf without any test noticing")
    }

    func testCommitStreaming_onATopLevelTask_buildsNothing() async throws {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "Top level", supervisorTask: "x") else {
            return XCTFail("could not create the task")
        }
        await seedRunningStep(taskID: taskID, stepID: "engineer")

        CommittedScanInputProbe.reset()
        await sut.commitStreaming(stepID: "engineer", taskID: taskID,
                                  content: "hello", thinking: nil)

        XCTAssertEqual(
            CommittedScanInputProbe.examined(), 0,
            "a task with no delegation must examine ZERO messages: `considerCommitted` "
                + "discards everything it would be handed, and paying Θ(messages) per "
                + "committed turn for that is Θ(N²) across a chat session on the MainActor")
    }

}
