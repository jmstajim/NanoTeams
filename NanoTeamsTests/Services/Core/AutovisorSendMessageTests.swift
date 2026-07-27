import XCTest

@testable import NanoTeams

/// Pins the wiring for `NTMSOrchestrator.sendMessageToAutovisor(_:attachments:)` —
/// the Watchtower Autovisor card's message composer calls through here. Asserts the
/// queued message actually carries the staged attachments (the consume path finalizes
/// + delivers them), and that the empty / no-manager guards return `false` without
/// queueing so the card keeps the draft intact. Engine state is forced to `.running`
/// so the success path never spawns a real `startRun` (no LM Studio needed).
@MainActor
final class AutovisorSendMessageTests: NTMSOrchestratorTestBase {

    private var formState: QuickCaptureFormState!
    private var externalSourceDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = tempDir.resolvingSymlinksInPath()
        formState = QuickCaptureFormState()
        sut.quickCaptureFormState = formState   // orchestrator holds it weakly
    }

    override func tearDown() {
        if let externalSourceDir {
            try? FileManager.default.removeItem(at: externalSourceDir)
        }
        externalSourceDir = nil
        formState = nil
        super.tearDown()
    }

    /// Opens the work folder (which seeds the Autovisor team) and pins a non-running
    /// manager task. Forces the engine to `.running` so `sendMessageToAutovisor`'s
    /// idle-wake branch is skipped (no real run is started).
    private func pinRunningManager() async -> Int {
        await sut.openWorkFolder(tempDir)
        let mgrID = await sut.createTask(title: "Manager", supervisorTask: "oversee", makeActive: false)!
        await sut.mutateWorkFolder {
            $0.state.autovisorTaskID = mgrID
            // Enabled, because a pinned-but-disabled manager is not a state
            // production reaches: `startAutovisorPass`'s zombie guard refuses a pass
            // while the feature is off (mirroring `fireRecurrence`'s), and both
            // non-button callers pre-check the flag themselves.
            $0.settings.autovisorEnabled = true
        }
        sut.engineState[mgrID] = .running
        return mgrID
    }

    /// Creates a real file OUTSIDE the work folder and stages it, so `stageAttachment`
    /// copies it (not a project reference) into `.nanoteams/staged/{draftID}/`.
    private func stageRealAttachment(fileName: String = "note.txt") -> StagedAttachment? {
        if externalSourceDir == nil {
            externalSourceDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("avsm_\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: externalSourceDir, withIntermediateDirectories: true)
        }
        let sourceURL = externalSourceDir.appendingPathComponent(fileName)
        try? "payload".data(using: .utf8)?.write(to: sourceURL)
        return sut.stageAttachment(url: sourceURL, draftID: UUID())
    }

    func testSend_withAttachments_queuesMessageCarryingThem() async {
        let mgrID = await pinRunningManager()
        guard let staged = stageRealAttachment() else {
            XCTFail("Staging must succeed")
            return
        }

        let ok = sut.sendMessageToAutovisor("see attached", attachments: [staged])

        XCTAssertTrue(ok, "Queueing to an existing manager with a real payload must succeed")
        let queued = formState.queuedMessages(for: mgrID)
        XCTAssertEqual(queued.count, 1, "Exactly one message should be queued")
        XCTAssertEqual(queued.first?.attachments.count, 1, "The staged attachment must ride along")
        XCTAssertEqual(queued.first?.text, "see attached")
        XCTAssertEqual(
            queued.first?.targetRoleID, sut.autovisorRole?.id,
            "Message must be targeted at the manager role so it's delivered to it"
        )
    }

    func testSend_emptyPayload_returnsFalse_doesNotQueue() async {
        let mgrID = await pinRunningManager()

        let ok = sut.sendMessageToAutovisor("   ", attachments: [])

        XCTAssertFalse(ok, "An all-empty payload must be rejected (QueuedChatMessage.init? fails)")
        XCTAssertTrue(formState.queuedMessages(for: mgrID).isEmpty, "Nothing should be queued")
    }

    func testSend_noManager_returnsFalse() async {
        await sut.openWorkFolder(tempDir)   // no manager pinned → autovisorTaskID is nil

        let ok = sut.sendMessageToAutovisor("hello", attachments: [])

        XCTAssertFalse(ok, "Without a manager task there's nowhere to deliver the message")
    }

    /// An unwired queue (`quickCaptureFormState` nil) must report failure — the
    /// pre-fix optional-chained append silently destroyed the message while the
    /// `true` return made the composer clear the user's draft.
    func testSend_unwiredFormState_returnsFalse() async {
        _ = await pinRunningManager()
        sut.quickCaptureFormState = nil

        let ok = sut.sendMessageToAutovisor("hello", attachments: [])

        XCTAssertFalse(ok, "queueing into a nil form state would silently drop the message")
    }

    /// A manager parked on `wait_for_events` (`.needsSupervisorInput`) must still
    /// accept the message into the queue — the parked branch routes delivery through
    /// the `.needsSupervisorInput` flush backstop (same conversation), never through
    /// `startRun` (gated on that state, would silently strand the message pre-fix).
    func testSend_parkedManager_queuesMessage() async {
        let mgrID = await pinRunningManager()
        sut.engineState[mgrID] = .needsSupervisorInput

        let ok = sut.sendMessageToAutovisor("continue please", attachments: [])

        XCTAssertTrue(ok)
        XCTAssertEqual(formState.queuedMessages(for: mgrID).count, 1,
                       "Message must be queued for the parked-step flush to deliver")
    }

    /// `startAutovisorPass` (event wake / Run-now supersede of a parked manager)
    /// must preserve queued chat messages — the doc promises they "survive the
    /// supersede and drain on iteration 1" — while actually starting a fresh run.
    func testStartAutovisorPass_parkedManager_preservesQueueAndStartsFreshRun() async {
        let mgrID = await pinRunningManager()
        sut.engineState[mgrID] = .needsSupervisorInput  // parked on wait_for_events
        _ = sut.sendMessageToAutovisor("standing guidance", attachments: [])
        XCTAssertEqual(formState.queuedMessages(for: mgrID).count, 1, "precondition")
        let runsBefore = sut.loadedTask(mgrID)?.runs.count ?? 0

        await sut.startAutovisorPass(taskID: mgrID)

        XCTAssertGreaterThan(sut.loadedTask(mgrID)?.runs.count ?? 0, runsBefore,
                             "The supersede must produce a fresh run")
        XCTAssertEqual(formState.queuedMessages(for: mgrID).count, 1,
                       "Queued messages survive the supersede (drained on iteration 1)")
        sut.stopEngineForTask(mgrID)  // tidy the spawned run
    }

    /// Pure wake-routing table for `sendMessageToAutovisor`: running → next-iteration
    /// injection; parked → flush into the parked conversation; everything else →
    /// fresh `startRun`.
    func testAutovisorMessageWake_routing() {
        XCTAssertEqual(NTMSOrchestrator.autovisorMessageWake(for: .running), .nextIteration)
        XCTAssertEqual(NTMSOrchestrator.autovisorMessageWake(for: .needsSupervisorInput), .flushParked)
        XCTAssertEqual(NTMSOrchestrator.autovisorMessageWake(for: nil), .startRun)
        XCTAssertEqual(NTMSOrchestrator.autovisorMessageWake(for: .paused), .startRun)
        XCTAssertEqual(NTMSOrchestrator.autovisorMessageWake(for: .done), .startRun)
        XCTAssertEqual(NTMSOrchestrator.autovisorMessageWake(for: .failed), .startRun)
        // Corner states: `.pending` (engine created, not started) routes through
        // startRun like any idle state; `.needsAcceptance` is structurally
        // unreachable for the chat-mode manager but must still map somewhere
        // total — startRun's own re-entry guard then decides (no-ops on it).
        XCTAssertEqual(NTMSOrchestrator.autovisorMessageWake(for: .pending), .startRun)
        XCTAssertEqual(NTMSOrchestrator.autovisorMessageWake(for: .needsAcceptance), .startRun)
    }
}
