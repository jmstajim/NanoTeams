import XCTest

@testable import NanoTeams

/// Compacting a step that is NOT in its tool loop — parked on a Supervisor question, paused,
/// or failed.
///
/// This is the path the composer's indicator takes most of the time, because a chat-mode role
/// spends most of its life parked waiting for the human. It is also the only path where the
/// world can move while the epoch runs: the summary takes seconds, and the Supervisor may
/// answer, restart the role, or re-enter the step during them. Every such case must leave the
/// stored transcript exactly as it was — a compacted wire built before an answer existed would
/// deliver that answer to nobody.
@MainActor
final class CompactSuspendedStepTests: XCTestCase {

    var sut: LLMExecutionService!
    var delegate: MockLLMExecutionDelegate!

    private let stepID = "engineer"
    private let taskID = 11

    override func setUp() async throws {
        try await super.setUp()
        sut = LLMExecutionService(
            repository: NTMSRepository(),
            clientFactory: { ScriptedSuspendedClient.shared },
            prefixLedger: PromptPrefixLedger())
        delegate = MockLLMExecutionDelegate()
        delegate.workFolderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nt-compaction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: delegate.workFolderURL!, withIntermediateDirectories: true)
        sut.attach(delegate: delegate)
        ScriptedSuspendedClient.shared.reset()
    }

    override func tearDown() async throws {
        if let url = delegate?.workFolderURL { try? FileManager.default.removeItem(at: url) }
        sut = nil
        delegate = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func parkedWire() -> [ChatMessage] {
        [
            ChatMessage(role: .system, content: "You are an engineer."),
            ChatMessage(role: .user, content: "## Supervisor Task\nBuild it."),
            ChatMessage(role: .assistant, content: "Reading."),
            ChatMessage(role: .tool, content: #"{"ok":true}"#),
            ChatMessage(
                role: .assistant, content: "",
                toolCalls: [ChatToolCall(
                    id: "c1", name: ToolNames.askSupervisor,
                    argumentsJSON: #"{"question":"Which parser?"}"#)]),
            ChatMessage(role: .tool, content: #"{"status":"pending"}"#, toolCallID: "c1"),
        ]
    }

    @discardableResult
    private func seedTask(
        status: StepStatus = .needsSupervisorInput,
        wire: [ChatMessage]? = nil,
        pendingAnswer: Bool = false
    ) -> NTMSTask {
        var step = StepExecution(id: stepID, role: .softwareEngineer, title: "work")
        step.status = status
        step.wireTranscript = wire ?? parkedWire()
        step.supervisorAnswerPendingDelivery = pendingAnswer
        step.contextFill = ContextFill(
            promptTokens: 6000, window: 8192, budget: 2048, isEstimate: false)
        var run = Run(id: 0, teamID: NTMSID.from(name: "Team"))
        run.steps = [step]
        var task = NTMSTask(id: taskID, title: "T", supervisorTask: "brief")
        task.runs = [run]
        delegate.taskToMutate = task
        return task
    }

    private var storedStep: StepExecution? {
        delegate.taskToMutate?.runs.last?.steps.first
    }

    // MARK: - Happy path

    func testParkedStep_isCompactedAndTheParkIsRetained() async {
        seedTask()
        let did = await sut.compactSuspendedStep(stepID: stepID, taskID: taskID)

        XCTAssertTrue(did)
        let wire = storedStep?.wireTranscript ?? []
        XCTAssertEqual(wire.count, 5, "head(2) + seed + the retained park(2)")
        XCTAssertEqual(Array(wire[..<2]), Array(parkedWire()[..<2]))
        XCTAssertTrue(CompactionPolicy.isCompactionSeed(wire[2]))
        XCTAssertEqual(Array(wire[3...]), Array(parkedWire()[4...]),
                       "the open ask_supervisor call and its pending result must survive, or "
                           + "the answer has nothing to attach to on re-entry")
    }

    func testParkedStep_recordsANoticeAndAFill() async {
        seedTask()
        _ = await sut.compactSuspendedStep(stepID: stepID, taskID: taskID)

        let notices = storedStep?.llmConversation.filter { $0.sourceContext == .compaction } ?? []
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(storedStep?.contextFill?.compactions, 1)
        XCTAssertEqual(storedStep?.contextFill?.isEstimate, true,
                       "nothing was sent after the fold, so the new size is an estimate")
        XCTAssertFalse(delegate.contextFillUpdates.isEmpty)
    }

    /// The composer indicator must be raised for the whole epoch and lowered on the way out,
    /// or a click leaves a permanently disabled control.
    func testParkedStep_raisesAndLowersTheCompactingMark() async {
        seedTask()
        _ = await sut.compactSuspendedStep(stepID: stepID, taskID: taskID)
        XCTAssertEqual(delegate.contextCompactingMarks.map(\.isCompacting), [true, false])
        XCTAssertFalse(sut.isCompacting(stepID: stepID, taskID: taskID))
    }

    /// Residency reconciliation must not unload the model out from under a live summary
    /// request — the same pin a running step gets.
    func testParkedStep_pinsTheModelWhileTheEpochRuns() async {
        seedTask()
        ScriptedSuspendedClient.shared.onRequest = { [weak sut] in
            XCTAssertFalse(
                sut?.activeModelKeys().isEmpty ?? true,
                "the model must be pinned while the summary is in flight")
        }
        _ = await sut.compactSuspendedStep(stepID: stepID, taskID: taskID)
    }

    /// A paused or failed step has no open call, so the whole body folds and the seed is the
    /// last turn.
    func testPausedStep_foldsEverythingAfterTheHead() async {
        seedTask(status: .paused, wire: Array(parkedWire()[..<4]))
        let did = await sut.compactSuspendedStep(stepID: stepID, taskID: taskID)
        XCTAssertTrue(did)
        XCTAssertEqual(storedStep?.wireTranscript.count, 3)
        XCTAssertEqual(storedStep?.wireTranscript.last?.role, .user)
    }

    // MARK: - Gates

    /// A running step owns its wire inside the tool loop. Compacting it from outside would
    /// race the loop's own `persistWireTranscript` and lose whichever wrote first.
    func testRunningStep_isRefused() async {
        seedTask(status: .running)
        sut._testInjectRunningTask(
            stepID: stepID, taskID: taskID,
            runningTask: Task { try? await Task.sleep(for: .seconds(60)) })
        let did = await sut.compactSuspendedStep(stepID: stepID, taskID: taskID)
        XCTAssertFalse(did)
        XCTAssertEqual(storedStep?.wireTranscript, parkedWire())
        sut.cancelExecutions(forTaskID: taskID)
    }

    func testDoneStep_isRefused() async {
        seedTask(status: .done)
        let did = await sut.compactSuspendedStep(stepID: stepID, taskID: taskID)
        XCTAssertFalse(did)
        XCTAssertEqual(storedStep?.wireTranscript, parkedWire())
    }

    /// An answer already waiting means the step is about to re-enter and replay it. Compacting
    /// now would write a wire built without it.
    func testPendingSupervisorAnswer_isRefusedUpFront() async {
        seedTask(pendingAnswer: true)
        let did = await sut.compactSuspendedStep(stepID: stepID, taskID: taskID)
        XCTAssertFalse(did)
        XCTAssertEqual(storedStep?.wireTranscript, parkedWire())
    }

    /// A step persisted before `wireTranscript` existed has nothing faithful to compact.
    func testEmptyTranscript_isRefused() async {
        seedTask(wire: [])
        let did = await sut.compactSuspendedStep(stepID: stepID, taskID: taskID)
        XCTAssertFalse(did)
    }

    /// Head-only: the conversation IS its pinned prefix. Refused with a banner rather than
    /// silently, because a click that does nothing is what the indicator exists to prevent.
    func testHeadOnlyTranscript_isRefusedWithABanner() async {
        seedTask(wire: Array(parkedWire()[..<2]))
        let did = await sut.compactSuspendedStep(stepID: stepID, taskID: taskID)
        XCTAssertFalse(did)
        XCTAssertFalse(delegate.lastInfoMessages.isEmpty)
    }

    /// The model came back with nothing usable, the step has no notes, and the folded range
    /// held no Supervisor turn — so the seed would carry nothing at all. A conversation whose
    /// head is followed by an empty summary has simply forgotten its work, so the epoch is
    /// refused with a banner and the transcript is left exactly as it was.
    ///
    /// RED: build the seed anyway → the parked step resumes against a wire that says nothing
    /// happened, and the model starts over.
    func testEmptySummaryWithNoNotesOrRecord_isRefusedWithABanner() async {
        seedTask()
        ScriptedSuspendedClient.shared.summary = "   "

        let did = await sut.compactSuspendedStep(stepID: stepID, taskID: taskID)

        XCTAssertFalse(did)
        XCTAssertFalse(delegate.lastInfoMessages.isEmpty, "a refusal the user can read")
        XCTAssertEqual(
            delegate.taskToMutate?.runs[0].steps[0].wireTranscript, parkedWire(),
            "and nothing written")
    }

    // MARK: - The compare-and-swap

    /// The race this whole mechanism is shaped around: the Supervisor answers while the
    /// summary is being written. The answer's delivery flag is set on the stored step, and the
    /// wire this epoch built knows nothing about it.
    ///
    /// RED: route the write through `persistWireTranscript` instead → that one clears
    /// `supervisorAnswerPendingDelivery` unconditionally, so the answer is marked delivered
    /// against a transcript that does not contain it, and the model never sees it.
    func testAnswerArrivingDuringTheSummary_losesTheSwap_andTheAnswerSurvives() async {
        seedTask()
        ScriptedSuspendedClient.shared.onRequest = { [weak self] in
            guard var task = self?.delegate.taskToMutate else { return }
            task.runs[0].steps[0].supervisorAnswer = "Use the recursive-descent one."
            task.runs[0].steps[0].supervisorAnswerPendingDelivery = true
            self?.delegate.taskToMutate = task
        }

        let did = await sut.compactSuspendedStep(stepID: stepID, taskID: taskID)

        XCTAssertFalse(did)
        XCTAssertEqual(storedStep?.wireTranscript, parkedWire(),
                       "the transcript must be exactly what the answer will be appended to")
        XCTAssertEqual(storedStep?.supervisorAnswerPendingDelivery, true,
                       "the answer must still be waiting for delivery")
        XCTAssertFalse(delegate.lastInfoMessages.isEmpty)
    }

    /// The other half of the same race: the transcript itself moved (a restart, a re-entry
    /// that appended). The epoch's `expected` no longer matches, so it stands down.
    func testTranscriptMovingDuringTheSummary_losesTheSwap() async {
        seedTask()
        ScriptedSuspendedClient.shared.onRequest = { [weak self] in
            guard var task = self?.delegate.taskToMutate else { return }
            task.runs[0].steps[0].wireTranscript.append(
                ChatMessage(role: .user, content: "something new"))
            self?.delegate.taskToMutate = task
        }

        let did = await sut.compactSuspendedStep(stepID: stepID, taskID: taskID)
        XCTAssertFalse(did)
        XCTAssertEqual(storedStep?.wireTranscript.count, parkedWire().count + 1)
    }

    /// And the status half: a step that left the suspended set during the summary (finished,
    /// restarted into `.running`) is no longer a step an out-of-loop epoch is defined for.
    func testStatusChangingDuringTheSummary_losesTheSwap() async {
        seedTask()
        ScriptedSuspendedClient.shared.onRequest = { [weak self] in
            guard var task = self?.delegate.taskToMutate else { return }
            task.runs[0].steps[0].status = .running
            self?.delegate.taskToMutate = task
        }
        let did = await sut.compactSuspendedStep(stepID: stepID, taskID: taskID)
        XCTAssertFalse(did)
        XCTAssertEqual(storedStep?.wireTranscript, parkedWire())
    }

    /// `persistCompactedWire` on its own, so the predicate is pinned independently of the
    /// epoch that calls it.
    func testPersistCompactedWire_refusesEveryMismatch() async {
        seedTask()
        let compacted = [ChatMessage(role: .system, content: "compacted")]

        var wrote = await sut.persistCompactedWire(
            stepID: stepID, taskID: taskID,
            expected: [ChatMessage(role: .user, content: "not the stored wire")],
            compacted: compacted, fill: nil)
        XCTAssertFalse(wrote, "a stale `expected` must lose")

        wrote = await sut.persistCompactedWire(
            stepID: stepID, taskID: taskID, expected: parkedWire(),
            compacted: [], fill: nil)
        XCTAssertFalse(wrote, "an empty replacement is never a compaction")

        wrote = await sut.persistCompactedWire(
            stepID: stepID, taskID: taskID, expected: parkedWire(),
            compacted: compacted, fill: nil)
        XCTAssertTrue(wrote, "the matching case must still succeed")
        XCTAssertEqual(storedStep?.wireTranscript, compacted)
    }

    // MARK: - Re-entry cancels the epoch

    /// Every door back into a step goes through `startStepExecution`, which cancels the entry's
    /// `runningTask` and replaces the entry. The epoch borrows that same slot precisely so it
    /// is cancelled for free — and a cancelled epoch writes nothing.
    func testEntryReplacementDuringTheSummary_writesNothing() async {
        seedTask()
        ScriptedSuspendedClient.shared.onRequest = { [weak self] in
            // Exactly what `startStepExecution` does on re-entry.
            self?.sut._testRegisterStepTaskReplacingEntry(stepID: self!.stepID, taskID: self!.taskID)
        }
        let did = await sut.compactSuspendedStep(stepID: stepID, taskID: taskID)
        XCTAssertFalse(did)
        XCTAssertEqual(storedStep?.wireTranscript, parkedWire())
    }

    /// A second click while the first epoch is running must not open a second summary against
    /// the same wire.
    func testASecondEpochIsRefusedWhileOneIsRunning() async {
        seedTask()
        var reentrantVerdict: Bool?
        ScriptedSuspendedClient.shared.onRequest = { [weak self] in
            guard let self else { return }
            reentrantVerdict = self.sut.isCompacting(stepID: self.stepID, taskID: self.taskID)
        }
        _ = await sut.compactSuspendedStep(stepID: stepID, taskID: taskID)
        XCTAssertEqual(reentrantVerdict, true)
    }

    // MARK: - Prefix ledger

    /// The next request after a fold must read as this owner's FIRST, not as a rewrite of a
    /// chain that described the conversation just replaced — otherwise the detector reports a
    /// cache defect for a reset the app performed on purpose.
    func testCompaction_dropsTheOwnersPrefixChain() async {
        seedTask()
        let owner = LLMCallOwner.step(taskID: taskID, stepID: stepID)
        _ = await sut.prefixLedger.record(
            baseURL: "http://127.0.0.1:1234", model: "m", owner: owner,
            messages: parkedWire(), toolSchemaText: "")

        _ = await sut.compactSuspendedStep(stepID: stepID, taskID: taskID)

        let observation = await sut.prefixLedger.record(
            baseURL: "http://127.0.0.1:1234", model: "m", owner: owner,
            messages: [ChatMessage(role: .system, content: "different")], toolSchemaText: "")
        guard case .firstRequestForOwner = observation.structural else {
            return XCTFail(
                "the chain must be forgotten at the epoch. Got \(observation.structural)")
        }
    }
}

// MARK: - Scripted client

/// A process-wide singleton because `LLMExecutionService.clientFactory` mints a client per
/// step and the test needs to reach the one the service will use.
private final class ScriptedSuspendedClient: LLMClient, @unchecked Sendable {
    static let shared = ScriptedSuspendedClient()

    /// Runs on the main actor inside `streamChat`, i.e. after the epoch captured the
    /// transcript it will compare against and before it writes — the exact window every race
    /// in this suite needs.
    var onRequest: (@MainActor () -> Void)?

    /// What the model answers. Blank stands for the model that produced nothing usable —
    /// an empty turn, or one the resolver reads as pure reasoning.
    var summary = "Read the parser; nothing written."

    func reset() {
        onRequest = nil
        summary = "Read the parser; nothing written."
    }

    func streamChat(
        config _: LLMConfig, messages _: [ChatMessage], tools _: [ToolSchema],
        logger _: NetworkLogger?, stepID _: String?, roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        // The service is `@MainActor` and awaits this stream inline, so the producer runs on
        // the main actor. `assumeIsolated` makes that explicit and traps loudly if it ever
        // stops being true, rather than racing silently.
        MainActor.assumeIsolated { onRequest?() }
        return AsyncThrowingStream { continuation in
            continuation.yield(StreamEvent(contentDelta: summary))
            continuation.finish()
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }

    func modelContextLength(config _: LLMConfig) async -> Int? { 8192 }
}
