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
    /// The NEW-TASK composer's text, and nothing else's.
    ///
    /// It used to be all three composers' text — `answerModeBody`, `taskCreationBody` and
    /// `chatWorkingBody` all bound this one property, with `savedSupervisorTask` stashing the
    /// task-draft meaning while the field held one of the other two. A stash covers exactly the
    /// transition that takes it; every other route between the meanings (open the panel onto a
    /// running chat task with a draft in hand, or navigate to Watchtower with a half-typed chat
    /// message) delivered content to a composer it was not written for — and both arriving
    /// composers have a live send button, so the leak submitted rather than merely displayed.
    /// The two attachment/clip buckets beside it were split per-purpose long ago; the text was
    /// simply left behind.
    ///
    /// `didSet` maintains `hasSubmittableText` so submit-button-style views can subscribe to
    /// the **threshold crossing** (empty ↔ non-empty) instead of every keystroke. Reading
    /// `supervisorTask` directly inside a SwiftUI view body subscribes that view to
    /// per-keystroke invalidation — which rebuilds the entire `QuickCaptureFormView.body` every
    /// time the user types a character. Routes through `hasSubmittableText` for the validity
    /// check.
    var supervisorTask: String = "" {
        didSet { refreshHasSubmittableText() }
    }
    /// Cached threshold flag — true iff `supervisorTask` (trimmed) is
    /// non-empty. Maintained by `supervisorTask.didSet`. Read by
    /// `canSubmit(mode:)` and `hasTaskDraftContent` so they don't
    /// subscribe their callers to per-keystroke invalidation.
    private(set) var hasSubmittableText: Bool = false
    var selectedTeamID: NTMSID?
    var draftID: UUID = UUID()
    var attachments: [StagedAttachment] = []
    var clippedTexts: [String] = []

    private func refreshHasSubmittableText() {
        let computed = !supervisorTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard computed != hasSubmittableText else { return }
        hasSubmittableText = computed
    }

    // MARK: - Answer Mode Sub-State

    private(set) var pendingAnswer: SupervisorAnswerPayload?
    /// The text of whichever composer is bound to the answer buckets — `.supervisorAnswer` and
    /// chat-mode `.taskWorking`, exactly the pair `QuickCaptureMode.composerBindsAnswerBuckets`
    /// already names. Third member of that bucket, and split out of `supervisorTask` for the
    /// reason recorded there.
    ///
    /// Carries its own threshold flag for the same per-keystroke-invalidation reason.
    var answerText: String = "" {
        didSet { refreshHasSubmittableAnswerText() }
    }
    private(set) var hasSubmittableAnswerText: Bool = false
    var answerAttachments: [StagedAttachment] = []
    var answerClippedTexts: [String] = []

    @ObservationIgnored private(set) var isInAnswerMode: Bool = false

    /// Which task the live answer bucket currently holds content for, or nil when it is
    /// unclaimed. The bucket is ONE set of fields shared by every task's answer and chat
    /// composer, so "whose content is in there" has to be recorded rather than inferred.
    ///
    /// It was inferred, from the panel's previous VISUAL mode — a proxy that agrees with the
    /// answer only while the panel goes straight from one chat task to another. Any detour (the
    /// new-task form, Watchtower) made the previous mode `.newTask`, the hand-off decline, and
    /// the message typed for A arrive in B's composer under B's send button.
    @ObservationIgnored private(set) var answerFieldsOwnerTaskID: Int?

    private func refreshHasSubmittableAnswerText() {
        let computed = !answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard computed != hasSubmittableAnswerText else { return }
        hasSubmittableAnswerText = computed
    }

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
        /// `true` when an automated supervisor authored the message (the Autovisor's
        /// `message_task`). When the `.needsSupervisorInput` backstop delivers the
        /// message as a question ANSWER, this rides into
        /// `answerSupervisorQuestion(isAutoAnswer:)` → `supervisorAnswerWasAuto`, so
        /// the feed's "Auto-answered" badge stays honest. Human enqueue paths
        /// (composer, QuickCapture, `sendMessageToAutovisor`) use the default `false`.
        let isFromAutomatedSupervisor: Bool
        /// Monotonic timestamp — useful for diagnosing FIFO-order issues across task
        /// switches and for future "queued N seconds ago" UX.
        let createdAt: Date
        /// `true` when this message has ALREADY been delivered once and shown in the feed, and is
        /// only back in the queue because a wire it rode was discarded — today that means the
        /// planning-phase boundary, which keeps just the task statement and the scratchpad.
        ///
        /// The redelivery still reaches the model (the implementation phase never saw it), but it
        /// must NOT produce a second Supervisor bubble: the user typed once and would otherwise
        /// watch their own message appear twice.
        let isRedelivery: Bool

        /// Fails when the payload is entirely empty. Trims `text` for the emptiness
        /// check but preserves the original (including leading/trailing whitespace)
        /// for the LLM prompt.
        init?(
            text: String,
            attachments: [StagedAttachment],
            clippedTexts: [String],
            targetRoleID: String? = nil,
            isFromAutomatedSupervisor: Bool = false,
            id: UUID = UUID(),
            createdAt: Date = MonotonicClock.shared.now(),
            isRedelivery: Bool = false
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
            self.isFromAutomatedSupervisor = isFromAutomatedSupervisor
            self.createdAt = createdAt
            self.isRedelivery = isRedelivery
        }
    }

    // MARK: - Answer Mode Transitions

    /// Enters answer mode: loads this task's saved answer draft, or starts with empty answer
    /// fields. `supervisorTask` is not read and not written — the task draft is a different
    /// composer's content and simply stays where it is, which is what removed the
    /// `savedSupervisorTask` stash along with every route the stash did not cover.
    ///
    /// The hand-off cycle runs through the FRESH branch below, not the re-entry guard: the
    /// controller's only call site is gated on `!isInAnswerMode`, so a working→answer transition
    /// arrives here having just snapshotted the live composer, and the draft load restores text,
    /// attachments and clips together. The re-entry guard is defensive — it keeps a second call
    /// from clobbering live fields, and routes a task change the same way the controller's own
    /// already-in-answer-mode branch does.
    func enterAnswerMode(payload: SupervisorAnswerPayload) {
        guard !isInAnswerMode else {
            // Task changed while already in answer mode — switch drafts
            if let oldTaskID = pendingAnswer?.taskID, oldTaskID != payload.taskID {
                switchAnswerTask(from: oldTaskID, to: payload)
            } else {
                pendingAnswer = payload
                answerFieldsOwnerTaskID = payload.taskID
                // Re-entry after a hand-off that saved a draft. Restore the buckets so the
                // cycle keeps clips and attachments intact; `answerText` was left correct by
                // whoever saved.
                if answerAttachments.isEmpty && answerClippedTexts.isEmpty,
                   let draft = answerDrafts[payload.taskID] {
                    answerAttachments = draft.attachments
                    answerClippedTexts = draft.clippedTexts
                }
            }
            return
        }
        if let draft = answerDrafts[payload.taskID] {
            answerText = draft.text
            answerAttachments = draft.attachments
            answerClippedTexts = draft.clippedTexts
        } else {
            answerText = ""
            answerAttachments = []
            answerClippedTexts = []
        }
        pendingAnswer = payload
        answerFieldsOwnerTaskID = payload.taskID
        isInAnswerMode = true
    }

    /// Exits answer mode: saves the current answer draft per-task, then clears the answer
    /// composer. Nothing is restored — the task composer's text was never moved.
    func exitAnswerMode() {
        // Save current answer state as draft before exiting
        if let payload = pendingAnswer {
            saveCurrentAnswerDraft(taskID: payload.taskID)
        }
        answerText = ""
        answerAttachments = []
        answerClippedTexts = []
        answerFieldsOwnerTaskID = nil
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
            answerText = draft.text
            answerAttachments = draft.attachments
            answerClippedTexts = draft.clippedTexts
        } else {
            answerText = ""
            answerAttachments = []
            answerClippedTexts = []
        }
        pendingAnswer = newPayload
        answerFieldsOwnerTaskID = newPayload.taskID
    }

    /// Drops every piece of form state that is keyed by a **folder-local task id**, or
    /// that points at a file staged inside the folder being left.
    ///
    /// Task ids are allocated from each folder's own `TasksIndex.nextTaskID`, so the first
    /// task of every folder carries the same id — collision across folders is the norm,
    /// not an edge case. `NTMSOrchestrator.apply(_:)` already says exactly that and already
    /// drops `loadedTasks` for it; this map and `answerDrafts` are the same class of state
    /// one layer up, in a process-global singleton, and were simply not included. Left
    /// behind, a message the user typed for folder A's task #3 is delivered to folder B's
    /// unrelated task #3, and `tryFlushQueuedMessages` — which iterates the surviving keys
    /// — wakes runs on tasks the user never touched.
    ///
    /// Deliberately NOT dropped: `title` / `supervisorTask` / `clippedTexts`. Unsent task text
    /// is folder-agnostic; the task it becomes is created in whichever folder is open when
    /// the user submits. `answerText` is the opposite — it is a reply to a question asked by a
    /// task in the folder being closed — so it goes with the rest of the answer bucket.
    func discardFolderScopedState() {
        queuedChatMessages.removeAll()
        answerDrafts.removeAll()
        // Torn down directly rather than through `exitAnswerMode()`, whose first act is to
        // SAVE the very draft we are discarding.
        pendingAnswer = nil
        isInAnswerMode = false
        answerText = ""
        answerAttachments = []
        answerClippedTexts = []
        answerFieldsOwnerTaskID = nil
        // Staged files live under the closed folder's `.nanoteams/staged/<draftID>/`, so
        // their relative paths resolve to nothing under the new root. A fresh `draftID`
        // keeps the next drop out of a directory keyed to the folder we just left.
        attachments = []
        draftID = UUID()
        // Team ids are per-folder; a nil pin is re-seeded by `presentPanelSync`.
        selectedTeamID = nil
    }

    /// Discards the answer draft for a specific task. Called on successful submit or explicit cancel.
    func discardAnswerDraft(taskID: Int) {
        answerDrafts.removeValue(forKey: taskID)
    }

    /// Snapshots the current live composer fields into `answerDrafts[taskID]`. Called by the
    /// controller across `.taskWorking` (chat) → `.supervisorAnswer` transitions for the same
    /// task so the in-progress message survives `enterAnswerMode`'s reset path. Reuses the
    /// same emptiness contract as `saveCurrentAnswerDraft` — empty content removes the entry
    /// rather than creating a phantom draft.
    func captureLiveComposerAsAnswerDraft(taskID: Int) {
        saveCurrentAnswerDraft(taskID: taskID)
    }

    /// Records that the live answer bucket now holds content for `taskID`. Called by the
    /// controller every time it resolves a composer bound to that bucket, so the claim is made
    /// where the binding is, not inferred later from which surface happened to precede it.
    func claimAnswerFields(for taskID: Int) {
        answerFieldsOwnerTaskID = taskID
    }

    /// Loads `answerDrafts[taskID]` into the live composer fields. No-op when no draft exists.
    /// Called by the controller after `.supervisorAnswer` → `.taskWorking` (chat) transitions
    /// for the same task so the just-saved draft becomes visible again in the chat-working
    /// composer (which binds to the same three live fields).
    func restoreAnswerDraftToLiveFields(taskID: Int) {
        answerFieldsOwnerTaskID = taskID
        guard let draft = answerDrafts[taskID] else { return }
        answerText = draft.text
        answerAttachments = draft.attachments
        answerClippedTexts = draft.clippedTexts
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

    /// Pops every message whose id is in `ids` in ONE pass over the queue, and
    /// returns them in the ORDER OF `ids` — the caller's tier order (targeted
    /// then untargeted) is what feeds the combined answer's body join, while
    /// the queue itself is stored in arrival order. Ids with no match are
    /// skipped. Removes the dictionary key when the queue empties —
    /// `taskIDsWithQueuedMessages` iterates KEYS, and a lingering empty array
    /// would wake the backstop on every engine-state change, forever.
    ///
    /// Replaces the per-id `popFirstQueuedMessage` loops in both drain paths
    /// (`consumeQueuedSupervisorMessage`, `flushQueuedChatMessage`), whose cost
    /// was O(batch × queue).
    func popQueuedMessages(withIDs ids: [UUID], for taskID: Int) -> [QueuedChatMessage] {
        guard var queue = queuedChatMessages[taskID], !ids.isEmpty else { return [] }
        let wanted = Set(ids)
        var byID: [UUID: QueuedChatMessage] = [:]
        queue.removeAll { msg in
            guard wanted.contains(msg.id) else { return false }
            byID[msg.id] = msg
            return true
        }
        if queue.isEmpty {
            queuedChatMessages.removeValue(forKey: taskID)
        } else {
            queuedChatMessages[taskID] = queue
        }
        return ids.compactMap { byID[$0] }
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

    /// Can the form be submitted given its current mode? Reads
    /// `hasSubmittableText` (a cached threshold flag) instead of
    /// `supervisorTask` directly — callers in SwiftUI view bodies would
    /// otherwise subscribe to per-keystroke invalidation through this
    /// path, rebuilding the whole `QuickCaptureFormView.body` per
    /// character.
    func canSubmit(mode: QuickCaptureMode) -> Bool {
        if case .supervisorAnswer = mode {
            return hasSubmittableAnswerText || !answerAttachments.isEmpty
                || !answerClippedTexts.isEmpty
        }
        // Chat-mode working lets the user queue the next message — same rules as answer mode.
        // Non-chat working has no composer, so submit is always disabled there.
        if case .taskWorking(_, let isChatMode) = mode {
            guard isChatMode else { return false }
            return hasSubmittableAnswerText || !answerAttachments.isEmpty
                || !answerClippedTexts.isEmpty
        }
        // A captured clip IS a request: ⌃⌥⌘K files text into `clippedTexts` and never into
        // `supervisorTask`, and `AnswerTextBuilder` folds clips into the task body the title is
        // derived from — so a clip-only draft submits fine, and refusing it left the panel
        // showing a chip beside a dead send button. `hasTaskDraftContent` already counted the
        // same clip as content worth confirming the discard of; the two disagreed.
        //
        // Attachments stay excluded on purpose: with no text and no clip the built body is
        // empty, `createPreparedTaskAndStart` can derive no title and returns nil without a
        // word — enabling the button there would trade a dead button for a dead press.
        return hasSubmittableText || hasSubmittableClip
    }

    /// True when at least one clip carries something other than whitespace. Same trim as
    /// `hasTaskDraftContent`, so the submit gate and the discard prompt agree.
    private var hasSubmittableClip: Bool {
        clippedTexts.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// True when any task-draft content is present. Used to decide whether to show a
    /// "discard draft?" confirmation on cancel. Reads `hasSubmittableText`
    /// rather than `supervisorTask` for the same per-keystroke-invalidation
    /// reason as `canSubmit(mode:)`.
    var hasTaskDraftContent: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || hasSubmittableText
            || clippedTexts.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            || !attachments.isEmpty
    }

    // MARK: - Private

    private func saveCurrentAnswerDraft(taskID: Int) {
        let text = answerText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty && answerAttachments.isEmpty && answerClippedTexts.isEmpty {
            answerDrafts.removeValue(forKey: taskID)
        } else {
            answerDrafts[taskID] = AnswerDraft(
                text: answerText,
                attachments: answerAttachments,
                clippedTexts: answerClippedTexts
            )
        }
    }

    // MARK: - Test Helpers

    #if DEBUG
    var _testAnswerDrafts: [Int: AnswerDraft] { answerDrafts }
    func _testClearAnswerDrafts() { answerDrafts.removeAll() }

    /// Full form-state reset for test isolation, driven by `QuickCaptureController._testReset()`.
    /// `exitAnswerMode()` already clears `pendingAnswer` / `isInAnswerMode` / the answer bucket.
    func _testReset() {
        if isInAnswerMode { exitAnswerMode() }
        title = ""
        supervisorTask = ""
        selectedTeamID = nil
        attachments = []
        clippedTexts = []
        answerText = ""
        answerAttachments = []
        answerClippedTexts = []
        answerFieldsOwnerTaskID = nil
        answerDrafts.removeAll()
        queuedChatMessages.removeAll()
    }
    #endif
    nonisolated deinit {}
}
