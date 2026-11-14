import Foundation

// MARK: - Supervisor Message Queue Service

/// Orchestrator-owned control plane for the Supervisor chat-message queue:
/// enqueue, the `.needsSupervisorInput` / terminal-state backstop (`tryFlushQueuedMessages`),
/// the resume/start wake mechanisms with their give-up maps, and task-level discard.
///
/// Extracted from `QuickCaptureController+QueueManagement` so `NTMSOrchestrator`
/// owns its queue wake/drain lifecycle directly without a reverse reference to
/// the UI controller (`DEBTS.md` D-29 / D-B26) and works in headless/MCP runs
/// where no SwiftUI view or `QuickCaptureController` is mounted.
@MainActor
final class SupervisorMessageQueueService {

    weak var store: NTMSOrchestrator?

    /// Standalone queue storage used when no UI `QuickCaptureFormState` is bridged
    /// (headless / MCP orchestrators). When `AppDependencyWiring` or a test sets
    /// `store.quickCaptureFormState`, `bridgedFormState` takes precedence so UI
    /// badges and the orchestrator read the same `QuickCaptureFormState` instance.
    private let ownedFormState = QuickCaptureFormState()
    weak var bridgedFormState: QuickCaptureFormState?
    weak var controllerFormState: QuickCaptureFormState?
    private(set) var isExplicitlyUnwired = false

    /// Active queue storage for this orchestrator.
    /// - Returns `nil` when a test explicitly cleared `store.quickCaptureFormState = nil`
    ///   to exercise the unwired guard.
    /// - Returns `bridgedFormState` when wired via `store.quickCaptureFormState = ...`.
    /// - Returns `controllerFormState` when a test attached `store` to a controller
    ///   without setting `quickCaptureFormState`.
    /// - Otherwise returns `ownedFormState` so headless / MCP orchestrators work standalone.
    var activeFormState: QuickCaptureFormState? {
        if isExplicitlyUnwired { return nil }
        if let bridgedFormState { return bridgedFormState }
        if let controllerFormState { return controllerFormState }
        return ownedFormState
    }

    func setBridgedFormState(_ formState: QuickCaptureFormState?) {
        bridgedFormState = formState
        isExplicitlyUnwired = (formState == nil)
    }

    private func resolvedFormState(_ override: QuickCaptureFormState?) -> QuickCaptureFormState? {
        if let override { return override }
        return activeFormState
    }

    /// In-flight guard for the queue-driven wake-ups (`resumeRun` AND the
    /// `.done`-chat `startRun`). Prevents two `tryFlush` ticks (e.g. an enqueue
    /// immediately followed by an engineState onChange) from spawning two
    /// concurrent wake calls before the first transitions the engine. Cleared in
    /// the dispatched `Task`'s `defer` so back-to-back callers within the same
    /// in-flight cycle collapse to one wake. Shared across both wake modes — a
    /// task can only be in one wake at a time, so a racing `.done`-start and a
    /// flickering `.failed`-resume dedupe against each other too.
    var pendingResumeForQueueFlush: Set<Int> = []

    /// One-shot guard for `.failed`-engine queue resumes, keyed by the specific queued
    /// MESSAGE IDs a `resumeRun` was already attempted for.
    ///
    /// DELIBERATELY SEPARATE from `chatStartAttemptedMessageIDs`: the two wake
    /// mechanisms operate on different state (revive an existing run vs create a fresh
    /// one), so a spent `.failed`-resume attempt is no evidence that a `.done`-chat
    /// start would also fail.
    var failedResumeAttemptedMessageIDs: [Int: Set<UUID>] = [:]

    /// `.done`-chat counterpart of `failedResumeAttemptedMessageIDs`: one `startRun`
    /// attempt per message ID.
    var chatStartAttemptedMessageIDs: [Int: Set<UUID>] = [:]

    /// Test seam — overrides the `Task { resumeRun }` dispatched by the
    /// `.paused`/`.pending`/`.none`/`.failed` branches of `tryFlushQueuedMessages`.
    var resumeRunForTesting: ((Int) -> Void)?

    /// Test seam — same contract as `resumeRunForTesting`, for the `Task { startRun }`
    /// dispatched by the `.done`-chat branch (`QueueWakeMode.start`).
    var startRunForTesting: ((Int) -> Void)?

    /// The role ID of the first running step in `task`'s latest run, if any.
    /// Single source of truth used by both `QuickCaptureModeCoordinator` (to
    /// build the `.taskWorking` title) and `submitQueuedMessageFromForm` (to
    /// target the queue at the same role).
    static func firstRunningStepRoleID(in task: NTMSTask) -> String? {
        task.runs.last?.steps.first(where: { $0.status == .running })?.effectiveRoleID
    }

    /// Stores a message for `taskID`.
    /// Returns `true` if the message was queued AND survived the immediate flush;
    /// `false` if rejected (empty payload via `QueuedChatMessage.init?`) or
    /// synchronously discarded by the flush (non-chat completed task, closed task).
    @discardableResult
    func queueChatMessage(
        text: String,
        attachments: [StagedAttachment],
        clippedTexts: [String],
        taskID: Int,
        targetRoleID: String? = nil,
        formState: QuickCaptureFormState? = nil
    ) -> Bool {
        guard let targetFormState = resolvedFormState(formState),
              let message = QuickCaptureFormState.QueuedChatMessage(
                  text: text,
                  attachments: attachments,
                  clippedTexts: clippedTexts,
                  targetRoleID: targetRoleID
              ) else {
            return false
        }
        targetFormState.appendQueuedMessage(message, for: taskID)
        // Delegation-interrupt path: when the message is targeted at a role
        // that's currently mid-`delegate_to_team`, wake the handler instead so
        // it can pause the child engine and surface the message text inside a
        // `paused_by_supervisor` success envelope on the parent role's next
        // iteration. Attachments decline the fast path and stay queued.
        if let role = targetRoleID,
           let store,
           message.attachments.isEmpty,
           store.notifyDelegationInterrupt(
               parentTaskID: taskID,
               parentRoleID: role,
               text: AnswerTextBuilder.build(text: text, clips: clippedTexts).answer
           )
        {
            targetFormState.removeQueuedMessage(withID: message.id, for: taskID)
            return true
        }
        tryFlushQueuedMessages(formState: targetFormState)
        return targetFormState.queuedMessages(for: taskID).contains { $0.id == message.id }
    }

    /// Fires `tryFlushQueuedMessages` when `taskID` has queued messages after an
    /// engine-less state update (`syncEngineStateFromRun` or team-generation failure).
    func noteEngineLessStateUpdated(taskID: Int) {
        guard activeFormState?.hasQueuedMessage(for: taskID) == true else { return }
        tryFlushQueuedMessages()
    }

    /// Backstop for the queue — handles `.needsSupervisorInput` and terminal/idle wakes
    /// independent of any SwiftUI view or panel visibility.
    func tryFlushQueuedMessages(formState: QuickCaptureFormState? = nil) {
        guard let store, let targetFormState = resolvedFormState(formState) else { return }
        guard !store.isFolderTransitionInProgress else { return }

        if !failedResumeAttemptedMessageIDs.isEmpty {
            failedResumeAttemptedMessageIDs = failedResumeAttemptedMessageIDs.filter {
                targetFormState.hasQueuedMessage(for: $0.key)
            }
        }
        if !chatStartAttemptedMessageIDs.isEmpty {
            chatStartAttemptedMessageIDs = chatStartAttemptedMessageIDs.filter {
                targetFormState.hasQueuedMessage(for: $0.key)
            }
        }

        let lifecycle = store.currentFolderLifecycle
        for taskID in targetFormState.taskIDsWithQueuedMessages {
            if store.isDormantAutovisorManagerTask(taskID) { continue }
            switch store.taskEngineStates[taskID] {
            case .needsSupervisorInput:
                retainFlushTaskForTests(Task { @MainActor [weak self] in
                    guard let self, self.store?.isCurrentFolderLifecycle(lifecycle) == true else { return }
                    await self.flushQueuedChatMessage(
                        taskID: taskID, within: lifecycle, formState: targetFormState)
                })
            case .done:
                if Self.isChatModeTask(taskID, store: store) {
                    let queuedIDs = Set(targetFormState.queuedMessages(for: taskID).map(\.id))
                    let attempted = (chatStartAttemptedMessageIDs[taskID] ?? []).intersection(queuedIDs)
                    let allAlreadyAttempted = !queuedIDs.isEmpty && queuedIDs.isSubset(of: attempted)
                    if allAlreadyAttempted, !pendingResumeForQueueFlush.contains(taskID) {
                        targetFormState.clearQueuedMessages(for: taskID)
                        chatStartAttemptedMessageIDs[taskID] = nil
                        store.lastInfoMessage = "\(queuedIDs.count) queued message(s) discarded — the chat couldn't be restarted."
                    } else {
                        let newlyStamped = queuedIDs.subtracting(attempted)
                        chatStartAttemptedMessageIDs[taskID] = attempted.union(queuedIDs)
                        wakeRunForQueuedMessages(
                            taskID: taskID, store: store, formState: targetFormState, mode: .start,
                            newlyStampedIDs: newlyStamped, within: lifecycle)
                    }
                } else {
                    failedResumeAttemptedMessageIDs[taskID] = nil
                    chatStartAttemptedMessageIDs[taskID] = nil
                    let count = targetFormState.queuedMessages(for: taskID).count
                    targetFormState.clearQueuedMessages(for: taskID)
                    if count > 0 {
                        store.lastInfoMessage = "\(count) queued message(s) discarded — task completed."
                    }
                }
            case .failed:
                let queuedIDs = Set(targetFormState.queuedMessages(for: taskID).map(\.id))
                let attempted = (failedResumeAttemptedMessageIDs[taskID] ?? []).intersection(queuedIDs)
                let allAlreadyAttempted = !queuedIDs.isEmpty && queuedIDs.isSubset(of: attempted)
                if allAlreadyAttempted, !pendingResumeForQueueFlush.contains(taskID) {
                    targetFormState.clearQueuedMessages(for: taskID)
                    failedResumeAttemptedMessageIDs[taskID] = nil
                    if !queuedIDs.isEmpty {
                        store.lastInfoMessage = "\(queuedIDs.count) queued message(s) discarded — task failed and couldn't be retried."
                    }
                } else {
                    failedResumeAttemptedMessageIDs[taskID] = attempted.union(queuedIDs)
                    wakeRunForQueuedMessages(
                        taskID: taskID, store: store, formState: targetFormState,
                        newlyStampedIDs: queuedIDs.subtracting(attempted), within: lifecycle)
                }
            case .paused, .pending, .none:
                if Self.hasDeliverableWaitingStep(
                    taskID: taskID, store: store,
                    queue: targetFormState.queuedMessages(for: taskID))
                {
                    retainFlushTaskForTests(Task { @MainActor [weak self] in
                        guard let self, self.store?.isCurrentFolderLifecycle(lifecycle) == true else { return }
                        await self.flushQueuedChatMessage(
                            taskID: taskID, within: lifecycle, formState: targetFormState)
                    })
                    continue
                }
                // A Pause pressed in the app is the person's to lift: messages only automated
                // Supervisors queued wait for it (`NTMSOrchestrator.isPausedInTheApp`).
                if Self.resumer(of: targetFormState.queuedMessages(for: taskID)).isAutomated,
                   store.isPausedInTheApp(taskID: taskID)
                {
                    continue
                }
                wakeRunForQueuedMessages(
                    taskID: taskID, store: store, formState: targetFormState, within: lifecycle)
            case .running, .needsAcceptance:
                continue
            }
        }
    }

    enum QueueWakeMode { case resume, start }

    private func wakeRunForQueuedMessages(
        taskID: Int, store: NTMSOrchestrator, formState: QuickCaptureFormState,
        mode: QueueWakeMode = .resume,
        newlyStampedIDs: Set<UUID> = [], within lifecycle: WorkFolderLifecycle
    ) {
        if store.loadedTask(taskID)?.closedAt != nil {
            discardQueueForClosedTask(taskID: taskID, store: store, formState: formState)
            return
        }
        guard !pendingResumeForQueueFlush.contains(taskID) else { return }
        pendingResumeForQueueFlush.insert(taskID)
        switch mode {
        case .resume:
            if let resume = resumeRunForTesting {
                resume(taskID)
                return
            }
            Task { @MainActor [weak self] in
                defer { self?.pendingResumeForQueueFlush.remove(taskID) }
                guard let self, let store = self.store else { return }
                guard store.isCurrentFolderLifecycle(lifecycle) else {
                    self.refundAttempt(newlyStampedIDs, of: taskID, from: \.failedResumeAttemptedMessageIDs)
                    return
                }
                await store.resumeRun(taskID: taskID, by: Self.resumer(of: formState.queuedMessages(for: taskID)))
            }
        case .start:
            if let start = startRunForTesting {
                start(taskID)
                return
            }
            Task { @MainActor [weak self] in
                defer { self?.pendingResumeForQueueFlush.remove(taskID) }
                guard let self, let store = self.store else { return }
                guard store.isCurrentFolderLifecycle(lifecycle) else {
                    self.refundAttempt(newlyStampedIDs, of: taskID, from: \.chatStartAttemptedMessageIDs)
                    return
                }
                await self.performStartWake(
                    taskID: taskID, newlyStampedIDs: newlyStampedIDs, formState: formState)
            }
        }
    }

    private func refundAttempt(
        _ ids: Set<UUID>, of taskID: Int,
        from map: ReferenceWritableKeyPath<SupervisorMessageQueueService, [Int: Set<UUID>]>
    ) {
        guard !ids.isEmpty, let stamped = self[keyPath: map][taskID] else { return }
        let kept = stamped.subtracting(ids)
        self[keyPath: map][taskID] = kept.isEmpty ? nil : kept
    }

    func performStartWake(
        taskID: Int, newlyStampedIDs: Set<UUID>, formState: QuickCaptureFormState? = nil
    ) async {
        guard let store, let targetFormState = resolvedFormState(formState) else { return }
        let lifecycle = store.currentFolderLifecycle
        guard store.isCurrentFolderLifecycle(lifecycle) else {
            refundAttempt(newlyStampedIDs, of: taskID, from: \.chatStartAttemptedMessageIDs)
            return
        }
        await store.ensureTaskLoaded(taskID)
        guard store.isCurrentFolderLifecycle(lifecycle) else {
            refundAttempt(newlyStampedIDs, of: taskID, from: \.chatStartAttemptedMessageIDs)
            return
        }
        guard let task = store.loadedTask(taskID) else {
            refundAttempt(newlyStampedIDs, of: taskID, from: \.chatStartAttemptedMessageIDs)
            store.lastErrorMessage =
                "Couldn't load task #\(taskID) to deliver queued message(s) — kept in queue."
            return
        }
        guard task.closedAt == nil else {
            discardQueueForClosedTask(taskID: taskID, store: store, formState: targetFormState)
            return
        }
        await store.startRun(taskID: taskID)
    }

    private func discardQueueForClosedTask(
        taskID: Int, store: NTMSOrchestrator, formState: QuickCaptureFormState
    ) {
        let count = formState.queuedMessages(for: taskID).count
        formState.clearQueuedMessages(for: taskID)
        if count > 0 {
            store.lastInfoMessage = "\(count) queued message(s) discarded — task closed."
        }
    }

    /// How many Supervisor messages wait in `taskID`'s queue, not yet delivered to a role — read
    /// from the queue this service delivers from (`activeFormState`), which in headless and MCP
    /// runs is its own and not the panel's.
    func queuedMessageCount(for taskID: Int) -> Int {
        activeFormState?.queuedMessages(for: taskID).count ?? 0
    }

    static func isChatModeTask(_ taskID: Int, store: NTMSOrchestrator) -> Bool {
        if let task = store.loadedTask(taskID) { return task.isChatMode }
        return store.snapshot?.tasksIndex.tasks.first(where: { $0.id == taskID })?.isChatMode ?? false
    }

    /// Discards all queued chat messages and give-up stamps for the given task.
    func discardQueuedChatMessage(taskID: Int, formState: QuickCaptureFormState? = nil) {
        resolvedFormState(formState)?.clearQueuedMessages(for: taskID)
        failedResumeAttemptedMessageIDs[taskID] = nil
        chatStartAttemptedMessageIDs[taskID] = nil
    }

    /// Discards all folder-scoped queue state and give-up maps across a folder switch.
    func discardFolderScopedState() {
        activeFormState?.discardFolderScopedState()
        pendingResumeForQueueFlush.removeAll()
        failedResumeAttemptedMessageIDs.removeAll()
        chatStartAttemptedMessageIDs.removeAll()
    }

    static func hasDeliverableWaitingStep(
        taskID: Int, store: NTMSOrchestrator,
        queue: [QuickCaptureFormState.QueuedChatMessage]
    ) -> Bool {
        guard let run = store.loadedTask(taskID)?.runs.last else { return false }
        let waitingRoleIDs = run.steps.compactMap {
            $0.canReceiveSupervisorAnswer ? $0.effectiveRoleID : nil
        }
        return collectQueuedMessagesForFlush(
            queue: queue,
            waitingStepRoleIDs: waitingRoleIDs
        ) != nil
    }

    func flushQueuedChatMessage(
        taskID: Int, within lifecycle: WorkFolderLifecycle,
        formState: QuickCaptureFormState? = nil
    ) async {
        guard let store, let targetFormState = resolvedFormState(formState) else { return }
        guard store.isCurrentFolderLifecycle(lifecycle),
              !store.isDormantAutovisorManagerTask(taskID),
              let task = store.loadedTask(taskID),
              let run = task.runs.last
        else { return }

        let waitingSteps = run.steps.filter(\.canReceiveSupervisorAnswer)
        guard !waitingSteps.isEmpty else { return }

        let queue = targetFormState.queuedMessages(for: taskID)
        guard let picked = Self.collectQueuedMessagesForFlush(
            queue: queue,
            waitingStepRoleIDs: waitingSteps.map(\.effectiveRoleID)
        ) else { return }
        guard let step = waitingSteps.first(where: { $0.effectiveRoleID == picked.stepRoleID })
        else { return }

        // ATOMIC RESERVE — pop every collected id synchronously before any await.
        let popped = targetFormState.popQueuedMessages(withIDs: picked.messageIDs, for: taskID)
        guard !popped.isEmpty else { return }

        let embedFiles = store.configuration.embedFilesInPrompt
        var bodies: [String] = []
        var typed: [String] = []
        var combinedAttachments: [StagedAttachment] = []
        var failedFiles: [String] = []
        var sharedAuthor = popped.first?.authorLabel
        for msg in popped {
            if msg.authorLabel != sharedAuthor {
                sharedAuthor = nil
            }
            typed.append(msg.text)
            let built = AnswerTextBuilder.build(
                text: msg.text,
                clips: msg.clippedTexts,
                attachments: msg.attachments,
                embedFiles: embedFiles
            )
            bodies.append(built.answer)
            combinedAttachments.append(contentsOf: msg.attachments)
            failedFiles.append(contentsOf: built.failedFiles)
        }
        let combinedAnswer = bodies.joined(separator: "\n")
        let allAutomated = popped.allSatisfy(\.isFromAutomatedSupervisor)
        let answerer = Self.resumer(of: popped)
        if !allAutomated {
            sharedAuthor = nil
        }

        let submission = step.supervisorInquiry.map { _ in
            SupervisorInquirySubmission(
                answer: SupervisorInquiryAnswer(),
                note: typed.joined(separator: "\n"))
        }

        // answerSupervisorQuestion auto-resumes the run — do NOT call resumeRun separately.
        // The delivery's own error, from its own scope: an error another task surfaced while
        // the answer was being written is not why THIS delivery failed (D-M18, 2026-11-13).
        let (delivered, deliveryError) = await store.surfacingError {
            await store.answerSupervisorQuestion(
                stepID: step.id,
                taskID: taskID,
                answer: combinedAnswer,
                attachments: combinedAttachments,
                origin: allAutomated ? .automated : .supervisor,
                submission: submission,
                author: sharedAuthor,
                by: answerer,
                within: lifecycle
            )
        }
        guard store.isCurrentFolderLifecycle(lifecycle) else { return }
        if delivered, !failedFiles.isEmpty {
            store.lastErrorMessage = "Could not embed \(failedFiles.count) file(s) as text: "
                + "\(failedFiles.joined(separator: ", ")). They may be binary files."
        }
        if !delivered {
            targetFormState.prependQueuedMessages(popped, for: taskID)
            let reason = deliveryError ?? "Message delivery failed."
            store.lastErrorMessage = reason
                + " — \(popped.count) queued message(s) kept; retry after resolving the issue."
        }
    }

    // MARK: - Backstop Priority (pure, unit-testable)

    /// Who a delivery of `queue` acts for: the person when any message is theirs — an
    /// unattributed message is theirs — else the automated Supervisor that queued the first one.
    static func resumer(of queue: [QuickCaptureFormState.QueuedChatMessage]) -> ControlActor {
        var automatedActor: ControlActor?
        for message in queue {
            guard message.isFromAutomatedSupervisor else { return .person }
            automatedActor = automatedActor ?? message.actor
        }
        guard !queue.isEmpty else { return .person }
        return automatedActor ?? .builtInAutovisor
    }

    static func collectQueuedMessagesForFlush(
        queue: [QuickCaptureFormState.QueuedChatMessage],
        waitingStepRoleIDs: [String]
    ) -> (stepRoleID: String, messageIDs: [UUID])? {
        guard !waitingStepRoleIDs.isEmpty else { return nil }
        let waiting = Set(waitingStepRoleIDs)

        var pickedRoleID: String?
        var targetedByRole: [String: [UUID]] = [:]
        var untargeted: [UUID] = []
        for msg in queue {
            if let target = msg.targetRoleID {
                targetedByRole[target, default: []].append(msg.id)
                if pickedRoleID == nil, waiting.contains(target) { pickedRoleID = target }
            } else {
                untargeted.append(msg.id)
            }
        }
        let roleID = pickedRoleID ?? (untargeted.isEmpty ? nil : waitingStepRoleIDs.first)
        guard let roleID else { return nil }

        let ids = targetedByRole[roleID, default: []] + untargeted
        guard !ids.isEmpty else { return nil }
        return (roleID, ids)
    }

    // MARK: - Test Helpers

    #if DEBUG
    var _testPendingFlushTasks: [Task<Void, Never>] = []

    func _testAwaitPendingFlushes() async {
        while !_testPendingFlushTasks.isEmpty {
            let batch = _testPendingFlushTasks
            _testPendingFlushTasks = []
            for task in batch { await task.value }
        }
    }

    func retainFlushTaskForTests(_ task: Task<Void, Never>) {
        _testPendingFlushTasks.append(task)
    }

    func clearPendingResumeForQueueFlushForTesting(taskID: Int) {
        pendingResumeForQueueFlush.remove(taskID)
    }

    func _testHasFailedResumeAttempted(taskID: Int) -> Bool {
        failedResumeAttemptedMessageIDs[taskID] != nil
    }

    func _testHasChatStartAttempted(taskID: Int) -> Bool {
        chatStartAttemptedMessageIDs[taskID] != nil
    }

    func _testReset() {
        bridgedFormState = nil
        isExplicitlyUnwired = false
        ownedFormState._testReset()
        pendingResumeForQueueFlush.removeAll()
        failedResumeAttemptedMessageIDs.removeAll()
        chatStartAttemptedMessageIDs.removeAll()
        resumeRunForTesting = nil
        startRunForTesting = nil
        _testPendingFlushTasks.removeAll()
    }
    #else
    func retainFlushTaskForTests(_ task: Task<Void, Never>) {}
    #endif
}
