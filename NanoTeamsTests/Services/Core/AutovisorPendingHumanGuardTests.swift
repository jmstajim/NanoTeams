import XCTest

@testable import NanoTeams

/// Pins Part A of the "human messages to the Autovisor disappear" fix: while a
/// PARKED manager (`wait_for_events` → engine `.needsSupervisorInput`) has a
/// pending HUMAN continuation — a just-written answer OR a queued human message —
/// an event/recurrence supersede must NOT fire a fresh run (which would
/// `createNewRun` and orphan the answer on the old run). Control cases prove the
/// supersede still fires when there is no human input, and that an AUTOMATED
/// queued message (event notice / `message_task`) never blocks it.
///
/// Guard cases keep the manager parked (no real engine spawned). Control cases
/// let the real supersede run and immediately `stopEngineForTask` to tidy.
@MainActor
final class AutovisorPendingHumanGuardTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private var formState: QuickCaptureFormState!

    override func setUp() async throws {
        try await super.setUp()
        formState = QuickCaptureFormState()
        sut.quickCaptureFormState = formState   // orchestrator holds it weakly
    }

    override func tearDown() async throws {
        formState = nil
        try await super.tearDown()
    }

    /// Opens the folder, pins + enables a manager whose latest run holds one parked
    /// idle-park step, and forces engine state `.needsSupervisorInput`. When `answer`
    /// is supplied, the step carries it (human, unless `answerWasAuto`).
    @discardableResult
    private func parkedManager(answer: String? = nil, answerWasAuto: Bool = false) async -> Int {
        await sut.openWorkFolder(tempDir)
        let mgrID = await sut.createTask(title: "Manager", supervisorTask: "oversee", makeActive: false)!
        await sut.mutateWorkFolder {
            $0.state.autovisorTaskID = mgrID
            $0.settings.autovisorEnabled = true
        }
        await sut.ensureTaskLoaded(mgrID)
        await sut.mutateTask(taskID: mgrID) { task in
            let step = StepExecution(
                id: "r", role: .softwareEngineer, title: "Mgr",
                status: answer == nil ? .needsSupervisorInput : .pending,
                needsSupervisorInput: answer == nil,
                supervisorQuestion: AutovisorConstants.idleParkQuestion,
                supervisorAnswer: answer,
                supervisorAnswerWasAuto: answerWasAuto
            )
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["r": .working])]
        }
        sut.engineState[mgrID] = .needsSupervisorInput
        return mgrID
    }

    /// A failed Startup task → the (default-on) `onTaskFailed` trigger matches, so
    /// `wakeAutovisorForEvents` has an item that would otherwise drive a fresh pass.
    private func makeFailedStartupTask() async {
        guard let startupID = sut.snapshot?.workFolder.teams.first(where: { $0.templateID == "startup" })?.id else {
            XCTFail("Startup team must be bootstrapped"); return
        }
        guard let taskID = await sut.createTask(title: "Build X", supervisorTask: "do X",
                                                preferredTeamID: startupID, makeActive: false) else {
            XCTFail("createTask failed"); return
        }
        await sut.ensureTaskLoaded(taskID)
        await sut.mutateTask(taskID: taskID) { task in
            let step = StepExecution(id: "r", role: .softwareEngineer, title: "Engineer", status: .failed)
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["r": .failed])]
        }
    }

    private func runCount(_ taskID: Int) -> Int { sut.loadedTask(taskID)?.runs.count ?? -1 }

    // MARK: - Event-wake guard fires (no supersede)

    func testEventWake_pendingHumanAnswer_doesNotSupersede() async {
        let mgrID = await parkedManager(answer: "qwen3.5 default")
        await makeFailedStartupTask()
        let before = runCount(mgrID)

        await sut.wakeAutovisorForEvents()

        XCTAssertEqual(runCount(mgrID), before,
                       "must not create a fresh run while a human answer is pending on the parked step")
        XCTAssertEqual(sut.loadedTask(mgrID)?.runs.last?.steps.first?.supervisorAnswer, "qwen3.5 default",
                       "the human answer is preserved on the current run")
        XCTAssertNil(sut.autovisorLastWakeAt, "deferral must NOT stamp the wake debounce")
    }

    func testEventWake_queuedHumanMessage_doesNotSupersede() async {
        // Finding #1's window: the message is still QUEUED (flush not yet run, answer
        // nil). The answer-only guard would miss this; the queue check must catch it.
        let mgrID = await parkedManager()
        let msg = QuickCaptureFormState.QueuedChatMessage(
            text: "qwen3.5 default", attachments: [], clippedTexts: [], targetRoleID: nil)!
        formState.appendQueuedMessage(msg, for: mgrID)
        await makeFailedStartupTask()
        let before = runCount(mgrID)

        await sut.wakeAutovisorForEvents()

        XCTAssertEqual(runCount(mgrID), before,
                       "a queued (not-yet-flushed) human message must also block the supersede")
        XCTAssertEqual(formState.queuedMessages(for: mgrID).count, 1, "the queued message is preserved")
        XCTAssertNil(sut.autovisorLastWakeAt)
    }

    // MARK: - Event-wake guard does NOT fire (supersede still works)

    func testEventWake_noPendingHumanInput_supersedes() async {
        let mgrID = await parkedManager()   // genuine idle park, no human input
        await makeFailedStartupTask()
        let before = runCount(mgrID)

        await sut.wakeAutovisorForEvents()

        XCTAssertGreaterThan(runCount(mgrID), before,
                             "an idle park with no human input is superseded by the event")
        sut.stopEngineForTask(mgrID)   // tidy the spawned run
    }

    func testEventWake_automatedQueuedMessage_doesNotBlockSupersede() async {
        let mgrID = await parkedManager()
        let auto = QuickCaptureFormState.QueuedChatMessage(
            text: "Event update", attachments: [], clippedTexts: [],
            targetRoleID: nil, isFromAutomatedSupervisor: true,
            kind: .autovisorEventNotice)!
        formState.appendQueuedMessage(auto, for: mgrID)
        await makeFailedStartupTask()
        let before = runCount(mgrID)

        await sut.wakeAutovisorForEvents()

        XCTAssertGreaterThan(runCount(mgrID), before,
                             "an automated queue entry (event notice) must not block a fresh pass")
        sut.stopEngineForTask(mgrID)
    }

    // MARK: - Recurrence supersede guard

    func testFireRecurrence_pendingHumanAnswer_defers() async {
        let mgrID = await parkedManager(answer: "qwen3.5 default")
        await sut.setTaskRecurrence(
            taskID: mgrID, recurrence: TaskRecurrence(rule: .interval(seconds: 60), isEnabled: true))
        let before = runCount(mgrID)

        // A slot well past the seeded one is due.
        await sut.evaluateDueRecurrences(now: Date().addingTimeInterval(600))

        XCTAssertEqual(runCount(mgrID), before,
                       "recurrence must defer (reschedule only) while a human answer is pending")
        XCTAssertEqual(sut.loadedTask(mgrID)?.runs.last?.steps.first?.supervisorAnswer, "qwen3.5 default")
    }

    func testFireRecurrence_noPendingHumanInput_supersedes() async {
        let mgrID = await parkedManager()   // parked, no human input
        await sut.setTaskRecurrence(
            taskID: mgrID, recurrence: TaskRecurrence(rule: .interval(seconds: 60), isEnabled: true))
        let before = runCount(mgrID)

        await sut.evaluateDueRecurrences(now: Date().addingTimeInterval(600))

        XCTAssertGreaterThan(runCount(mgrID), before,
                             "a parked manager with no human input is superseded on its schedule")
        sut.stopEngineForTask(mgrID)
    }

    func testFireRecurrence_queuedHumanMessage_defers() async {
        let mgrID = await parkedManager()   // no written answer; message only queued
        let msg = QuickCaptureFormState.QueuedChatMessage(
            text: "qwen3.5 default", attachments: [], clippedTexts: [], targetRoleID: nil)!
        formState.appendQueuedMessage(msg, for: mgrID)
        await sut.setTaskRecurrence(
            taskID: mgrID, recurrence: TaskRecurrence(rule: .interval(seconds: 60), isEnabled: true))
        let before = runCount(mgrID)

        await sut.evaluateDueRecurrences(now: Date().addingTimeInterval(600))

        XCTAssertEqual(runCount(mgrID), before,
                       "a still-queued human message defers the recurrence (keeps session continuity)")
        XCTAssertEqual(formState.queuedMessages(for: mgrID).count, 1)
    }

    func testFireRecurrence_automatedQueuedMessage_supersedes() async {
        let mgrID = await parkedManager()
        let auto = QuickCaptureFormState.QueuedChatMessage(
            text: "Event update", attachments: [], clippedTexts: [],
            targetRoleID: nil, isFromAutomatedSupervisor: true,
            kind: .autovisorEventNotice)!
        formState.appendQueuedMessage(auto, for: mgrID)
        await sut.setTaskRecurrence(
            taskID: mgrID, recurrence: TaskRecurrence(rule: .interval(seconds: 60), isEnabled: true))
        let before = runCount(mgrID)

        await sut.evaluateDueRecurrences(now: Date().addingTimeInterval(600))

        XCTAssertGreaterThan(runCount(mgrID), before,
                             "an automated queued message must not defer the schedule")
        sut.stopEngineForTask(mgrID)
    }

    // MARK: - autovisorHasPendingHumanContinuation queue semantics (direct)

    func testHasPendingHumanContinuation_mixedHumanAndAutomatedQueue_true() async {
        // `.contains { !isFromAutomatedSupervisor }` — ANY human entry in a mixed
        // batch makes the whole queue a human continuation.
        let mgrID = await parkedManager()
        formState.appendQueuedMessage(
            .init(text: "auto", attachments: [], clippedTexts: [],
                  targetRoleID: nil, isFromAutomatedSupervisor: true)!, for: mgrID)
        formState.appendQueuedMessage(
            .init(text: "human", attachments: [], clippedTexts: [], targetRoleID: nil)!, for: mgrID)

        XCTAssertTrue(sut.autovisorHasPendingHumanContinuation(mgrID))
    }

    func testHasPendingHumanContinuation_onlyAutomatedQueue_false() async {
        let mgrID = await parkedManager()   // no written answer
        formState.appendQueuedMessage(
            .init(text: "auto", attachments: [], clippedTexts: [],
                  targetRoleID: nil, isFromAutomatedSupervisor: true)!, for: mgrID)

        XCTAssertFalse(sut.autovisorHasPendingHumanContinuation(mgrID))
    }

    // MARK: - Deferral leaves the event re-deliverable

    func testEventWake_deferral_leavesEventReDeliverable() async {
        // When the guard defers, it must NOT mark the triggering event notified or
        // stamp the wake debounce — otherwise the event would be silently dropped
        // instead of injected once the manager resumes to `.running`.
        _ = await parkedManager(answer: "qwen3.5 default")
        await makeFailedStartupTask()

        await sut.wakeAutovisorForEvents()

        XCTAssertTrue(sut.autovisorNotifiedAttentionKeys.isEmpty,
                      "deferral must not mark the event notified — it stays re-deliverable")
        XCTAssertNil(sut.autovisorLastWakeAt, "deferral must not stamp the wake debounce")
    }
}
