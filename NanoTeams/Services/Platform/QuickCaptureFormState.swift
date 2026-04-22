import Foundation

// MARK: - Quick Capture Form State

/// Owns all user-editable form state for Quick Capture (overlay + sheet).
///
/// Separated from `QuickCaptureController` (panel lifecycle, hotkeys, mode routing)
/// and from `TaskManagementState` (sidebar selection, delete/rename state). This is
/// the Information Expert for the form itself: title, supervisorTask, team, attachments, and
/// the answer-mode sub-state that tracks a transient Supervisor question.
@Observable @MainActor
final class QuickCaptureFormState {
    // MARK: - Task Creation Fields

    var title: String = ""
    var supervisorTask: String = ""
    var selectedTeamID: NTMSID?
    var draftID: UUID = UUID()
    var attachments: [StagedAttachment] = []
    var clippedTexts: [String] = []

    // MARK: - Answer Mode Sub-State

    private(set) var pendingAnswer: SupervisorAnswerPayload?
    var answerAttachments: [StagedAttachment] = []
    var answerClippedTexts: [String] = []

    @ObservationIgnored private(set) var isInAnswerMode: Bool = false
    @ObservationIgnored private var savedSupervisorTask: String?

    /// Per-task answer draft storage. Keyed by taskID. `@ObservationIgnored` because this
    /// map is a snapshot store — readers (`enterAnswerMode`, `switchAnswerTask`,
    /// `saveCurrentAnswerDraft`) COPY between this dictionary and the observed
    /// `supervisorTask` / `answerAttachments` / `answerClippedTexts` properties. UI
    /// observers re-render off those observed copies, so tracking the map itself would
    /// produce redundant re-renders every time a draft is saved with no visible effect.
    /// The queue below (`queuedChatMessages`) is deliberately NOT ignored because the
    /// composer renders each queued row directly — see its own comment.
    @ObservationIgnored private var answerDrafts: [Int: AnswerDraft] = [:]

    /// In-memory FIFO queue of chat messages per task, waiting to be flushed when the
    /// engine reaches `.needsSupervisorInput`. Each entry may be targeted at a specific
    /// role (delivered only when THAT role asks) or untargeted (first asker wins).
    /// Not persisted — dropped on app restart by design. INTENTIONALLY tracked by the
    /// `@Observable` macro (no `@ObservationIgnored`) because `TeamActivityComposer.queuedList`
    /// and `QuickCaptureFormView.queuedBadge` render directly from it — any append / pop /
    /// clear must trigger a re-render.
    private var queuedChatMessages: [Int: [QueuedChatMessage]] = [:]

    // MARK: - Answer Draft

    struct AnswerDraft {
        var text: String
        var attachments: [StagedAttachment]
        var clippedTexts: [String]
    }

    // MARK: - Queued Chat Message

    /// Immutable record of a message waiting to be delivered. Invariants enforced in
    /// the failable `init?`:
    /// - At least one of (trimmed) `text` / `attachments` / `clippedTexts` is non-empty.
    ///
    /// `id: UUID` gives each message a stable identity so the composer's `ForEach` and
    /// the flush path's `popFirstQueuedMessage(matching: id)` don't depend on structural
    /// equality (which would misbehave when two messages have identical content).
    struct QueuedChatMessage: Equatable, Identifiable {
        let id: UUID
        let text: String
        let attachments: [StagedAttachment]
        let clippedTexts: [String]
        /// When non-nil, the message is delivered only when this specific role reaches
        /// `.needsSupervisorInput`. `nil` = any role / first asker wins.
        let targetRoleID: String?
        /// Monotonic timestamp — useful for diagnosing FIFO-order issues across task
        /// switches and for future "queued N seconds ago" UX.
        let createdAt: Date

        /// Fails when the payload is entirely empty. Trims `text` for the emptiness
        /// check but preserves the original (including leading/trailing whitespace)
        /// for the LLM prompt.
        init?(
            text: String,
            attachments: [StagedAttachment],
            clippedTexts: [String],
            targetRoleID: String? = nil,
            id: UUID = UUID(),
            createdAt: Date = MonotonicClock.shared.now()
        ) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty || !attachments.isEmpty || !clippedTexts.isEmpty else {
                return nil
            }
            self.id = id
            self.text = text
            self.attachments = attachments
            self.clippedTexts = clippedTexts
            self.targetRoleID = targetRoleID
            self.createdAt = createdAt
        }
    }

    // MARK: - Answer Mode Transitions

    /// Enters answer mode: stashes the current `supervisorTask` so it can be restored
    /// on exit, then either restores a saved per-task answer draft or — if no draft
    /// exists — carries the current text/attachments/clips over as the initial answer.
    /// The carry-over matters for chat-working mode: a queue message the user was
    /// typing (`формState.supervisorTask` shared with the working composer) should
    /// become the initial answer when the LLM finally asks for input, not get wiped.
    /// Re-entry is non-destructive — if already in answer mode, only the payload is
    /// updated so the original `savedSupervisorTask` (the user's task draft) is preserved.
    func enterAnswerMode(payload: SupervisorAnswerPayload) {
        guard !isInAnswerMode else {
            // Task changed while already in answer mode — switch drafts
            if let oldTaskID = pendingAnswer?.taskID, oldTaskID != payload.taskID {
                switchAnswerTask(from: oldTaskID, to: payload)
            } else {
                pendingAnswer = payload
            }
            return
        }
        savedSupervisorTask = supervisorTask
        if let draft = answerDrafts[payload.taskID] {
            supervisorTask = draft.text
            answerAttachments = draft.attachments
            answerClippedTexts = draft.clippedTexts
        }
        // Else: leave supervisorTask / answerAttachments / answerClippedTexts as-is so
        // anything the user already typed (chat-working queue draft) carries over.
        pendingAnswer = payload
        isInAnswerMode = true
    }

    /// Exits answer mode: saves current answer draft per-task, restores `supervisorTask`.
    func exitAnswerMode() {
        // Save current answer state as draft before exiting
        if let payload = pendingAnswer {
            saveCurrentAnswerDraft(taskID: payload.taskID)
        }
        supervisorTask = savedSupervisorTask ?? ""
        savedSupervisorTask = nil
        answerAttachments = []
        answerClippedTexts = []
        pendingAnswer = nil
        isInAnswerMode = false
    }

    /// Updates the pending answer payload without toggling the mode flag. Used when the
    /// active task changes while the panel is already in answer mode.
    func updateAnswerPayload(_ payload: SupervisorAnswerPayload) {
        pendingAnswer = payload
    }

    /// Saves the current answer-mode fields as a draft for the given task,
    /// then clears them so the next task starts clean.
    func switchAnswerTask(from oldTaskID: Int, to newPayload: SupervisorAnswerPayload) {
        saveCurrentAnswerDraft(taskID: oldTaskID)
        // Load draft for the new task (or start fresh)
        if let draft = answerDrafts[newPayload.taskID] {
            supervisorTask = draft.text
            answerAttachments = draft.attachments
            answerClippedTexts = draft.clippedTexts
        } else {
            supervisorTask = ""
            answerAttachments = []
            answerClippedTexts = []
        }
        pendingAnswer = newPayload
    }

    /// Clears answer-mode clips/attachments without restoring the saved supervisor task.
    /// Used on panel dismiss — saves draft first so it persists across open/close.
    func clearAnswerSession() {
        if let payload = pendingAnswer {
            saveCurrentAnswerDraft(taskID: payload.taskID)
        }
        answerAttachments = []
        answerClippedTexts = []
    }

    /// Discards the answer draft for a specific task. Called on successful submit or explicit cancel.
    func discardAnswerDraft(taskID: Int) {
        answerDrafts.removeValue(forKey: taskID)
    }

    // MARK: - Queued Chat Message API

    /// All pending queued messages for the task, in FIFO order.
    func queuedMessages(for taskID: Int) -> [QueuedChatMessage] {
        queuedChatMessages[taskID] ?? []
    }

    func hasQueuedMessage(for taskID: Int) -> Bool {
        !(queuedChatMessages[taskID] ?? []).isEmpty
    }

    /// Appends a message to the end of the task's queue.
    func appendQueuedMessage(_ message: QueuedChatMessage, for taskID: Int) {
        queuedChatMessages[taskID, default: []].append(message)
    }

    /// Inserts `messages` at the head of the task's queue, preserving their
    /// relative order. Used by the consumption pipeline's re-queue-on-failure
    /// path so a popped batch restores to the same head-of-queue position it
    /// had before the pop — not pushed behind any messages queued during the
    /// intervening `await`. Keeps the user's FIFO intent intact under failure.
    func prependQueuedMessages(_ messages: [QueuedChatMessage], for taskID: Int) {
        guard !messages.isEmpty else { return }
        queuedChatMessages[taskID, default: []].insert(contentsOf: messages, at: 0)
    }

    /// Pops the first queued message that satisfies `predicate` and returns it.
    /// Leaves other messages in place. Returns `nil` if no eligible message exists.
    @discardableResult
    func popFirstQueuedMessage(
        for taskID: Int,
        matching predicate: (QueuedChatMessage) -> Bool
    ) -> QueuedChatMessage? {
        guard var queue = queuedChatMessages[taskID] else { return nil }
        guard let index = queue.firstIndex(where: predicate) else { return nil }
        let message = queue.remove(at: index)
        if queue.isEmpty {
            queuedChatMessages.removeValue(forKey: taskID)
        } else {
            queuedChatMessages[taskID] = queue
        }
        return message
    }

    /// Removes one message at the given index. Retained for tests that exercise
    /// positional behavior directly; production UI should use `removeQueuedMessage(withID:for:)`.
    func removeQueuedMessage(at index: Int, for taskID: Int) {
        guard var queue = queuedChatMessages[taskID],
              queue.indices.contains(index)
        else { return }
        queue.remove(at: index)
        if queue.isEmpty {
            queuedChatMessages.removeValue(forKey: taskID)
        } else {
            queuedChatMessages[taskID] = queue
        }
    }

    /// Removes the queued message with the given stable id. Used by the composer's
    /// per-row X button — safer than index-based removal when the queue can mutate
    /// concurrently (flush between render and tap).
    func removeQueuedMessage(withID id: UUID, for taskID: Int) {
        guard var queue = queuedChatMessages[taskID],
              let index = queue.firstIndex(where: { $0.id == id })
        else { return }
        queue.remove(at: index)
        if queue.isEmpty {
            queuedChatMessages.removeValue(forKey: taskID)
        } else {
            queuedChatMessages[taskID] = queue
        }
    }

    /// Drops the task's entire queue (e.g. on task close/delete or engine `.done`/`.failed`).
    func clearQueuedMessages(for taskID: Int) {
        queuedChatMessages.removeValue(forKey: taskID)
    }

    var taskIDsWithQueuedMessages: [Int] {
        Array(queuedChatMessages.keys)
    }

    // MARK: - Task Creation State Reset

    /// Clears task-creation fields and generates a new `draftID` for the next task.
    func clearTaskDraft() {
        title = ""
        supervisorTask = ""
        selectedTeamID = nil
        draftID = UUID()
        attachments = []
        clippedTexts = []
    }

    // MARK: - Submission Guards

    /// Can the form be submitted given its current mode?
    func canSubmit(mode: QuickCaptureMode) -> Bool {
        let hasText = !supervisorTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if case .supervisorAnswer = mode {
            return hasText || !answerAttachments.isEmpty || !answerClippedTexts.isEmpty
        }
        // Chat-mode working lets the user queue the next message — same rules as answer mode.
        // Non-chat working has no composer, so submit is always disabled there.
        if case .taskWorking(_, let isChatMode) = mode {
            guard isChatMode else { return false }
            return hasText || !answerAttachments.isEmpty || !answerClippedTexts.isEmpty
        }
        return hasText
    }

    /// True when any task-draft content is present. Used to decide whether to show a
    /// "discard draft?" confirmation on cancel.
    var hasTaskDraftContent: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !supervisorTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || clippedTexts.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            || !attachments.isEmpty
    }

    // MARK: - Private

    private func saveCurrentAnswerDraft(taskID: Int) {
        let text = supervisorTask.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty && answerAttachments.isEmpty && answerClippedTexts.isEmpty {
            answerDrafts.removeValue(forKey: taskID)
        } else {
            answerDrafts[taskID] = AnswerDraft(
                text: supervisorTask,
                attachments: answerAttachments,
                clippedTexts: answerClippedTexts
            )
        }
    }

    // MARK: - Test Helpers

    #if DEBUG
    var _testSavedSupervisorTask: String? { savedSupervisorTask }
    var _testAnswerDrafts: [Int: AnswerDraft] { answerDrafts }
    func _testClearAnswerDrafts() { answerDrafts.removeAll() }
    var _testQueuedChatMessages: [Int: [QueuedChatMessage]] { queuedChatMessages }
    #endif
    nonisolated deinit {}
}
