import XCTest

@testable import NanoTeams

/// `AutovisorReply` — the one builder of every text the Autovisor's manager is told about its own
/// actions and its folder — and the registry rows that version it.
@MainActor
final class AutovisorReplyTests: XCTestCase {

    private var samples: [(name: String, reply: AutovisorReply)] { RuntimePromptRegistry.autovisorReplySamples }

    /// The case a reply is, by the compiler: a new case does not build here until it is named. Named
    /// in `everyCase` as well, `testEveryCaseIsSampledByTheRegistry` then fails until the registry
    /// renders it.
    private func caseName(_ reply: AutovisorReply) -> String {
        switch reply {
        case .drivenByExternalAgent: "drivenByExternalAgent"
        case .ownTask: "ownTask"
        case .taskNotFound: "taskNotFound"
        case .tooManyRunning: "tooManyRunning"
        case .creationLimitReached: "creationLimitReached"
        case .openTaskLimitReached: "openTaskLimitReached"
        case .creationWindowLimitReached: "creationWindowLimitReached"
        case .creationFailed: "creationFailed"
        case .createdNotStarted: "createdNotStarted"
        case .createdAndStarted: "createdAndStarted"
        case .createdScheduled: "createdScheduled"
        case .notWaitingForInput: "notWaitingForInput"
        case .notWaitingForInputExternal: "notWaitingForInputExternal"
        case .roleNotWaiting: "roleNotWaiting"
        case .answered: "answered"
        case .answeredWhilePausedInTheApp: "answeredWhilePausedInTheApp"
        case .answerNotDelivered: "answerNotDelivered"
        case .messageNotQueued: "messageNotQueued"
        case .messageDiscardedTaskFinished: "messageDiscardedTaskFinished"
        case .messageQueued: "messageQueued"
        case .messageQueuedAndResumed: "messageQueuedAndResumed"
        case .messageQueuedWhilePausedInTheApp: "messageQueuedWhilePausedInTheApp"
        case .decisionWaitsForThePersonsResume: "decisionWaitsForThePersonsResume"
        case .scheduleNotCleared: "scheduleNotCleared"
        case .scheduleCleared: "scheduleCleared"
        case .scheduleNotStored: "scheduleNotStored"
        case .scheduled: "scheduled"
        case .workFolderContextUpdated: "workFolderContextUpdated"
        case .workFolderContextChangedSinceRead: "workFolderContextChangedSinceRead"
        case .alreadyRunning: "alreadyRunning"
        case .started: "started"
        case .couldNotStart: "couldNotStart"
        case .paused: "paused"
        case .couldNotPause: "couldNotPause"
        case .closedNotResumable: "closedNotResumable"
        case .noRunToResume: "noRunToResume"
        case .pausedByThePerson: "pausedByThePerson"
        case .resumed: "resumed"
        case .stopped: "stopped"
        case .closed: "closed"
        case .closeFailed: "closeFailed"
        case .deleted: "deleted"
        case .renamed: "renamed"
        case .timeoutCleared: "timeoutCleared"
        case .timeoutSet: "timeoutSet"
        case .noSuchRole: "noSuchRole"
        case .generationIsNotARole: "generationIsNotARole"
        case .restartWouldDiscard: "restartWouldDiscard"
        case .restartWouldOrphanChild: "restartWouldOrphanChild"
        case .restarted: "restarted"
        case .changesRequested: "changesRequested"
        case .correctNeedsPause: "correctNeedsPause"
        case .corrected: "corrected"
        case .alreadyClosed: "alreadyClosed"
        case .finishAdvisoryOnProducingRole: "finishAdvisoryOnProducingRole"
        case .noActiveRun: "noActiveRun"
        case .accepted: "accepted"
        case .acceptFailed: "acceptFailed"
        case .acceptRejected: "acceptRejected"
        case .finishFailed: "finishFailed"
        case .advisoryFinished: "advisoryFinished"
        case .chatRoleFinished: "chatRoleFinished"
        case .chatRoleFinishedAndClosed: "chatRoleFinishedAndClosed"
        case .chatRoleFinishedCloseFailed: "chatRoleFinishedCloseFailed"
        case .noPendingGeneration: "noPendingGeneration"
        case .noLongerLoaded: "noLongerLoaded"
        case .generationRerun: "generationRerun"
        case .generationInProgress: "generationInProgress"
        case .generationFailedAgain: "generationFailedAgain"
        case .generationDidNotRestart: "generationDidNotRestart"
        case .eventNotice: "eventNotice"
        }
    }

    /// Every case name above, once, beside the switch that names them.
    private let everyCase: Set<String> = [
        "drivenByExternalAgent", "ownTask", "taskNotFound", "tooManyRunning", "creationLimitReached",
        "openTaskLimitReached", "creationWindowLimitReached", "creationFailed",
        "createdNotStarted", "createdAndStarted", "createdScheduled", "notWaitingForInput", "notWaitingForInputExternal", "roleNotWaiting", "answered",
        "answeredWhilePausedInTheApp", "answerNotDelivered", "messageNotQueued", "messageDiscardedTaskFinished", "messageQueued",
        "messageQueuedAndResumed", "messageQueuedWhilePausedInTheApp", "decisionWaitsForThePersonsResume",
        "scheduleNotCleared",
        "scheduleCleared", "scheduleNotStored", "scheduled", "workFolderContextUpdated", "workFolderContextChangedSinceRead",
        "alreadyRunning", "started", "couldNotStart", "paused", "couldNotPause", "closedNotResumable",
        "noRunToResume", "pausedByThePerson", "resumed", "stopped", "closed", "closeFailed", "deleted", "renamed",
        "timeoutCleared", "timeoutSet", "noSuchRole", "generationIsNotARole", "restartWouldDiscard", "restartWouldOrphanChild",
        "restarted", "changesRequested", "correctNeedsPause", "corrected", "alreadyClosed",
        "finishAdvisoryOnProducingRole", "noActiveRun", "accepted", "acceptFailed", "acceptRejected",
        "finishFailed", "advisoryFinished", "chatRoleFinished", "chatRoleFinishedAndClosed",
        "chatRoleFinishedCloseFailed", "noPendingGeneration", "noLongerLoaded", "generationRerun",
        "generationInProgress", "generationFailedAgain", "generationDidNotRestart", "eventNotice",
    ]

    // MARK: - The registry covers the builder

    func testEveryCaseIsSampledByTheRegistry() {
        XCTAssertEqual(Set(samples.map { caseName($0.reply) }), everyCase,
                       "a case of the builder that no registry row renders ships its wording unversioned")
    }

    func testEverySampleHasItsOwnRowAndText() {
        XCTAssertEqual(Set(samples.map(\.name)).count, samples.count, "two samples share a row name")
        for sample in samples {
            XCTAssertFalse(sample.reply.text.isEmpty, "\(sample.name) renders nothing")
        }
        let rows = Set(RuntimePromptRegistry.entries.map(\.name))
        for sample in samples {
            XCTAssertTrue(rows.contains("AutovisorReply.text/\(sample.name)"), "\(sample.name) has no registry row")
        }
    }

    /// The dormant manager's refusal reaches only the built-in manager's local model, so it is
    /// versioned in the local fingerprint and swept by the local-model format conventions.
    func testTheDormancyRefusalIsALocalModelText() {
        XCTAssertEqual(AutovisorReply.drivenByExternalAgent.audience, .localModel)
        let row = RuntimePromptRegistry.entries.first { $0.name == "AutovisorReply.text/drivenByExternalAgent" }
        XCTAssertEqual(row?.audience, .localModel)
        XCTAssertEqual(row?.render(), AutovisorReply.drivenByExternalAgent.text)
    }

    /// The registry also versions the two deferred-call replies and the team refusal per failing
    /// resolution, the arms of its remedy included.
    func testTheDeferredCallRepliesAndTheTeamRefusalAreRows() {
        let rows = Dictionary(RuntimePromptRegistry.entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(rows["DeferredCallReplies.notRun"]?.render(), DeferredCallReplies.notRun)
        XCTAssertEqual(rows["DeferredCallReplies.folderChanged"]?.render(), DeferredCallReplies.folderChanged)
        for name in ["generationDisabled", "teamBlocked", "activeTeamBlocked", "activeTeamIsChat",
                     "activeTeamNotUsable", "unknown"] {
            let text = rows["AutovisorTeamPolicy.failureMessage/\(name)"]?.render()
            XCTAssertNotNil(text, "no team-refusal row for \(name)")
            XCTAssertNotEqual(text, "(none)", "the \(name) sample resolves to no refusal")
        }
        XCTAssertTrue(rows["AutovisorTeamPolicy.failureMessage/unknown"]?.render().contains("No team is available") == true,
                      "the remedy's no-option arm is rendered by no row")
        XCTAssertTrue(rows["AutovisorTeamPolicy.failureMessage/teamBlocked"]?.render().contains(", or ") == true,
                      "the remedy's several-options arm is rendered by no row")
        // The accept refusal's two halves: the fact for every status (and none), the remedy for
        // every status, and the two remedy arms a `.done` role can take.
        XCTAssertNotNil(rows["AcceptanceService.validateAcceptance/unknownRole"])
        XCTAssertNotNil(rows["AutovisorStatus.acceptRejectionAdvice/noStatus"])
        for status in RoleExecutionStatus.allCases {
            XCTAssertNotNil(rows["AcceptanceService.validateAcceptance/\(status.rawValue)"], "no fact row for \(status)")
            XCTAssertNotNil(rows["AutovisorStatus.acceptRejectionAdvice/\(status.rawValue)"], "no remedy row for \(status)")
        }
        for arm in ["done/readyToClose", "done/chat"] {
            let text = rows["AutovisorStatus.acceptRejectionAdvice/\(arm)"]?.render()
            XCTAssertTrue(text?.contains("control_task close") == true, "the \(arm) remedy arm is rendered by no row")
        }
    }

    // MARK: - The wording moved, unchanged

    /// The texts moved into the builder byte for byte: these are the replies the manager read
    /// before, spelled out.
    func testTheRepliesKeepTheirWording() {
        XCTAssertEqual(AutovisorReply.taskNotFound(taskID: 9).text, "Task #9 not found — call list_tasks for current task ids.")
        XCTAssertEqual(AutovisorReply.createdNotStarted(taskID: 3, title: "Fix", reason: nil).text,
                       "Created task #3: Fix. It did NOT start (no run was created) — call control_task start on #3.")
        XCTAssertEqual(AutovisorReply.createdNotStarted(taskID: 3, title: "Fix", reason: "busy").text,
                       "Created task #3: Fix. It did NOT start (busy) — call control_task start on #3.")
        XCTAssertEqual(AutovisorReply.scheduled(taskID: 4, minutes: 15).text, "Task #4 will now run every 15 min.")
        XCTAssertEqual(AutovisorReply.renamed(taskID: 2, title: "New").text, "Renamed task #2 to \"New\".")
        XCTAssertEqual(AutovisorReply.chatRoleFinished(taskID: 5, roleID: "a", stillActive: ["B", "C"]).text,
                       "Finished role a on chat task #5. Still active: B, C. A chat task never finishes on its own — use control_task close when you want to end it.")
        XCTAssertEqual(AutovisorReply.chatRoleFinishedCloseFailed(taskID: 5, roleID: "a", reason: nil).text,
                       "Finished role a on chat task #5, but closing it failed: unknown. Retry with control_task close.")
        XCTAssertEqual(AutovisorReply.generationFailedAgain(taskID: 6, reason: nil).text, "Team generation for task #6 failed again.")
        XCTAssertEqual(AutovisorReply.generationFailedAgain(taskID: 6, reason: "x").text, "Team generation for task #6 failed again: x")
        XCTAssertEqual(AutovisorReply.acceptRejected(reason: "Role already completed", remedy: nil).text, "Role already completed")
        XCTAssertEqual(AutovisorReply.acceptRejected(reason: "Role already completed", remedy: "call task_status").text,
                       "Role already completed — call task_status")
        XCTAssertEqual(
            AutovisorReply.couldNotPause(
                taskID: 2,
                reason: AutovisorReply.PauseFailureReason.alreadyPaused.rawValue).text,
            "Could not pause task #2 — it is already paused.")
    }

    /// The event notice: its header first, then one bullet per condition in the order given, each
    /// naming the call that acts on it. Empty input is the header alone.
    func testTheEventNoticeIsTheHeaderThenOneBulletPerCondition() {
        let triggers = NTMSOrchestrator.AutovisorAttentionTrigger.allCases
        let items = triggers.map { NTMSOrchestrator.AutovisorAttentionItem(taskID: 7, title: "T", trigger: $0) }
        let lines = AutovisorReply.eventNotice(items).text.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, MessageSourceContext.autovisorEventNoticeHeader)
        XCTAssertEqual(lines.count, items.count + 1)
        XCTAssertTrue(lines.dropFirst().allSatisfy { $0.hasPrefix("- ") && $0.contains("#7") })
        XCTAssertEqual(AutovisorReply.eventNotice([]).text, MessageSourceContext.autovisorEventNoticeHeader)
        XCTAssertEqual(NTMSOrchestrator.composeAutovisorEventNotice(items), AutovisorReply.eventNotice(items).text,
                       "the orchestrator's composer is the builder's notice")
    }

    /// The action result spellings carry the reply's text and nothing else of their own.
    func testTheResultSpellingsCarryTheReplyText() {
        let success = AutovisorActionResult.success(.started(taskID: 3), createdTaskID: 3)
        XCTAssertTrue(success.ok)
        XCTAssertEqual(success.message, "Started task #3.")
        XCTAssertEqual(success.createdTaskID, 3)
        let failure = AutovisorActionResult.failure(.alreadyRunning(taskID: 3))
        XCTAssertFalse(failure.ok)
        XCTAssertEqual(failure.message, "Task #3 is already running.")
        XCTAssertNil(failure.next)
    }

    /// `list_tasks` and `task_status` render JSON envelopes and fallback messages that go
    /// straight into the manager's tool-result messages — every one of their builders must
    // MARK: - Refusals written for the reader who gets them (2026-11-08)

    /// The external agent's two creation caps had one string between them, and it was the
    /// built-in manager's per-REVIEW cap. Its remedy — close or finish tasks — frees an OPEN slot
    /// and cannot refill a sliding window, so an agent that obeyed it retried into the identical
    /// refusal; and because both rendered the same text it could not tell which cap it had hit
    /// except by the number happening to differ. The ledger computes `windowMinutes` and the old
    /// mapping threw it away.
    func testTheTwoCreationCapsRefuseDifferentlyAndNameTheWindow() {
        let open = AutovisorReply.openTaskLimitReached(count: 3, limit: 3).text
        let window = AutovisorReply.creationWindowLimitReached(limit: 5, windowMinutes: 15).text
        XCTAssertNotEqual(open, window, "one string for two caps is the defect")

        XCTAssertTrue(open.contains("3 of 3"), open)
        XCTAssertTrue(open.lowercased().contains("close"), "closing IS the remedy for this one: \(open)")

        XCTAssertTrue(window.contains("15 min"), "the window length is computed — say it: \(window)")
        XCTAssertTrue(window.contains("5"), window)
        XCTAssertTrue(
            window.contains("does NOT"),
            "the remedy that cannot work must be ruled out, not merely omitted: \(window)")
        // "this pass" and "per-review" are the built-in manager's review-loop vocabulary; an
        // external agent has no referent for either. ("wait for it to pass" is this text's own.)
        for jargon in ["this pass", "per-review", "Per-review"] {
            XCTAssertFalse(window.contains(jargon), "\(jargon) means nothing to an agent: \(window)")
            XCTAssertFalse(open.contains(jargon), "\(jargon) means nothing to an agent: \(open)")
        }

        for reply in [
            AutovisorReply.openTaskLimitReached(count: 3, limit: 3),
            .creationWindowLimitReached(limit: 5, windowMinutes: 15),
        ] {
            XCTAssertEqual(reply.audience, .externalAgent, "\(reply) reaches no local model")
        }
    }

    /// The feed has no `answered` and no `accepted` kind, so a question the person answers in the
    /// app is never retracted. The bare "not waiting" then reads as a stale id; the external
    /// wording says what happened and names the one channel that records it.
    func testTheNotWaitingRefusalTellsAnAgentThatSomeoneMayHaveAnsweredFirst() {
        let external = AutovisorReply.notWaitingForInputExternal(taskID: 7).text
        XCTAssertTrue(external.contains("#7"), external)
        XCTAssertTrue(external.contains("task_log"), "the only record of who spoke: \(external)")
        XCTAssertTrue(external.contains("from"), external)
        XCTAssertEqual(AutovisorReply.notWaitingForInputExternal(taskID: 7).audience, .externalAgent)

        // The built-in manager keeps its own wording: it has no `task_log` tool to be sent to.
        let local = AutovisorReply.notWaitingForInput(taskID: 7).text
        XCTAssertFalse(local.contains("task_log"), local)
        XCTAssertEqual(AutovisorReply.notWaitingForInput(taskID: 7).audience, .localModel)
    }

    /// Shared, not external-only: the built-in manager can restart a delegating role too, and
    /// orphans the child exactly the same way.
    func testTheOrphanRefusalExplainsTheSilenceAndIsSharedByBothDrivers() {
        let reply = AutovisorReply.restartWouldOrphanChild(taskID: 3, roleID: "swe", childTaskID: 7)
        XCTAssertTrue(reply.text.contains("#7"), "the child must be nameable: \(reply.text)")
        XCTAssertTrue(
            reply.text.contains("not stalled"),
            "the refusal exists because the role LOOKS stalled: \(reply.text)")
        XCTAssertEqual(reply.audience, .localModel, "both drivers can do this")
    }

    /// sit in `RuntimePromptRegistry.entries` with non-empty sample output.
    func testAutovisorReadToolRenderersAreRegisteredInTheCensus() {
        let byName = Dictionary(grouping: RuntimePromptRegistry.entries, by: \.name)
        for expectedName in [
            "LLMExecutionService.autovisorUnavailableMessage",
            "LLMExecutionService.taskStatusNotFoundMessage",
            "LLMExecutionService.reviewReadyCloseReason",
            "LLMExecutionService.renderListTasksEnvelope",
            "LLMExecutionService.renderTaskStatusEnvelope/running",
            "LLMExecutionService.renderTaskStatusEnvelope/reviewReadyToClose",
        ] {
            let rows = byName[expectedName] ?? []
            XCTAssertFalse(rows.isEmpty, "Missing RuntimePromptRegistry row for \(expectedName)")
            for row in rows {
                let sample = row.render().trimmingCharacters(in: .whitespacesAndNewlines)
                XCTAssertFalse(sample.isEmpty, "\(expectedName) sample must not be empty")
            }
        }
    }
}
