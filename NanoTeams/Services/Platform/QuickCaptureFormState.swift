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
    var clippedTexts: [Clip] = []

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
    var answerClippedTexts: [Clip] = []
    /// The fourth member of the answer bucket: what the human has ticked and typed into an
    /// `ask_supervisor_form` questionnaire so far, together with WHICH questionnaire.
    ///
    /// Observed rather than derived from the card, because the card is rebuilt from scratch on
    /// every panel re-render (`QuickCaptureFormView` re-hosts its `NSHostingView`) — view state
    /// would reset mid-fill. It travels with `answerText` through every park and take, so a
    /// half-filled form survives exactly what the prose beside it survives.
    ///
    /// Paired with its questionnaire's identity, and that pairing is load-bearing here more
    /// than anywhere: the bucket FOLLOWS the panel across a branch that continues the same
    /// conversation (`AnswerDraftKey.continues(into:)`), which is right for a sentence and
    /// wrong for a set of ticks. Under the chat thread's `.taskChat` key every role of the task
    /// continues into every other, so a form filled for one role would arrive live under the
    /// next role's questions. It still arrives — nothing silently deletes the Supervisor's work
    /// — but every reader compares `SupervisorInquiryDraft.answer(for:)` and sees it is not an
    /// answer to what is on screen.
    var answerInquiry: SupervisorInquiryDraft?

    @ObservationIgnored private(set) var isInAnswerMode: Bool = false

    /// Which of the task's waiting questions the panel is aimed at, or nil for "whichever
    /// leads". Written when the user taps a chip, when a submit moves the panel on, and by the
    /// transition that APPLIES a resolved mode — so it always names what is on screen.
    ///
    /// A `TaskStepKey` and not a bare step id, for the reason invariant #5 exists:
    /// `StepExecution.id` IS the role id, so two tasks on one team carry byte-identical ones.
    /// A bare id picked on task A does not decay when the panel re-resolves onto task B — it
    /// MATCHES, and aims the panel at a role the Supervisor never picked there. That is a
    /// stronger collision than the cross-folder one, because it needs no folder switch at all.
    ///
    /// A preference, not a fact: `QuickCapturePresentationPolicy.aiming(_:at:)` honours it only
    /// for its own task and only while that question is still waiting, so a stale key decays.
    /// Re-written on every applied transition as well, which is what stops a pick that stopped
    /// resolving from lying dormant and then resurrecting when the same role asks again.
    ///
    /// `@ObservationIgnored` because nothing reads it from a view body — the panel renders the
    /// resolved session it is handed by value, and the controller is what reads this. Tracking
    /// it would invalidate the panel's whole tree on a change that already forces a rebuild
    /// through `renderIdentity`.
    @ObservationIgnored var aimedQuestion: TaskStepKey?

    /// Which BRANCH the live answer bucket currently holds content for, or nil when it is
    /// unclaimed. The bucket is ONE set of fields shared by every task's answer and chat
    /// composer, so "whose content is in there" has to be recorded rather than inferred.
    ///
    /// It was inferred, from the panel's previous VISUAL mode — a proxy that agrees with the
    /// answer only while the panel goes straight from one chat task to another. Any detour (the
    /// new-task form, Watchtower) made the previous mode `.newTask`, the hand-off decline, and
    /// the message typed for A arrive in B's composer under B's send button.
    ///
    /// A task id, which this was until the draft store learned branches, is too coarse for a
    /// TEAM task: parallel roles park at once (CLAUDE.md #45), the panel shows whichever question
    /// leads, and a role answered elsewhere hands the panel the NEXT one under the same task id
    /// — so the reply typed for the first role stayed in the fields aimed at the second.
    @ObservationIgnored private(set) var answerFieldsOwnerKey: AnswerDraftKey?

    private func refreshHasSubmittableAnswerText() {
        let computed = !answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard computed != hasSubmittableAnswerText else { return }
        hasSubmittableAnswerText = computed
    }

    /// Unsent replies for branches no composer is currently holding — shared with the docked
    /// `TeamActivityComposer`, which reaches it the same way it already reaches
    /// `queuedMessages`. Owned here rather than declared here: the panel is one of two
    /// surfaces that park drafts, not the store's home.
    ///
    /// Observed, unlike the per-task map it replaces. That one was `@ObservationIgnored`
    /// because readers COPIED between it and the live fields, so tracking it only produced
    /// re-renders with no visible effect. Under take-and-return an entry exists exactly when
    /// NO composer holds the content — which is a thing the parked-draft row renders directly.
    let answerDraftStore = SupervisorAnswerDraftStore()

    /// In-memory FIFO queue of chat messages per task, waiting to be flushed when the
    /// engine reaches `.needsSupervisorInput`. Each entry may be targeted at a specific
    /// role (delivered only when THAT role asks) or untargeted (first asker wins).
    /// Not persisted — dropped on app restart by design. INTENTIONALLY tracked by the
    /// `@Observable` macro (no `@ObservationIgnored`) because `TeamActivityComposer.queuedList`
    /// and `QuickCaptureFormView.queuedBadge` render directly from it — any append / pop /
    /// clear must trigger a re-render.
    private var queuedChatMessages: [Int: [QueuedChatMessage]] = [:]

    // MARK: - Queued Chat Message

    /// Immutable record of a message waiting to be delivered. Invariants enforced in
    /// the failable `init?`:
    /// - At least one of (trimmed) `text` / `attachments` / `clippedTexts` is non-empty.
    ///
    /// `id: UUID` gives each message a stable identity so the composer's `ForEach` and
    /// the flush path's `popFirstQueuedMessage(matching: id)` don't depend on structural
    /// equality (which would misbehave when two messages have identical content).
    struct QueuedChatMessage: Equatable, Identifiable {
        /// WHAT the entry is, as opposed to `isFromAutomatedSupervisor`'s WHO wrote it.
        ///
        /// The two axes are independent and both are load-bearing, which is why this is a
        /// second field rather than a reinterpretation of the flag: `message_task` is
        /// authored by the automated Supervisor AND is genuine Supervisor speech, so
        /// "automated" cannot stand in for "system-authored". The author axis drives the
        /// feed's "Auto-answered" badge and `autovisorHasPendingHumanContinuation`'s
        /// supersede-vs-defer decision; this axis decides only how
        /// `consumeQueuedSupervisorMessage` renders the drained turn.
        /// `nonisolated` so the pure composition helper that reads it
        /// (`NTMSOrchestrator.composeQueuedDelivery`) stays off the main actor and unit-
        /// testable — the enclosing `QuickCaptureFormState` is implicitly `@MainActor`.
        nonisolated enum Kind: Equatable {
            /// A Supervisor — human or automated — talking to a role. Drains with the
            /// `Supervisor:` attribution marker and persists as `.supervisorMessage`.
            case supervisorSpeech
            /// The app's mid-review notice that folder state moved
            /// (`NTMSOrchestrator.composeAutovisorEventNotice`). Drains UNMARKED, like every
            /// other system notice, and persists as `.autovisorEvent` so the feed collapses
            /// it to a one-line row instead of drawing a Supervisor bubble.
            case autovisorEventNotice
        }

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
        /// What this entry IS — see ``Kind``. Every human enqueue path and `message_task`
        /// take the default; only the Autovisor's mid-review injection sets the notice kind.
        let kind: Kind
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
            kind: Kind = .supervisorSpeech,
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
            self.kind = kind
            self.createdAt = createdAt
            self.isRedelivery = isRedelivery
        }
    }

    // MARK: - Answer Mode Transitions

    /// The branch a Supervisor question belongs to: the role that asked it.
    ///
    /// Chat mode does not change this. The panel's chat-working composer is the only surface
    /// that names no role, and it alone keys `.taskChat`; the two meet through
    /// `AnswerDraftKey.continues(into:)`, which lets the live fields follow the panel across
    /// the working↔answer flip instead of being parked and taken under two names.
    static func draftKey(for payload: SupervisorAnswerPayload) -> AnswerDraftKey {
        .role(TaskStepKey(taskID: payload.taskID, stepID: payload.stepID))
    }

    /// Hands the live answer bucket to `destination`.
    ///
    /// Content that `continues(into:)` the destination stays exactly where it is — the fields
    /// are simply re-labelled. Anything else is parked under the branch that owns it, and the
    /// destination's own parked draft is TAKEN into the fields.
    ///
    /// The one hand-off. Four call sites used to spell their own version of it (enter answer
    /// mode, leave it, switch payload inside it, the chat→chat reassign), and they agreed on
    /// the task switch and on nothing else.
    func handOffLiveAnswerFields(to destination: AnswerDraftKey) {
        if let owner = answerFieldsOwnerKey, owner.continues(into: destination) {
            answerFieldsOwnerKey = destination
            // The store's contract is that no entry stands under a branch a composer holds.
            // An entry here means another surface parked content while this one had the
            // fields; take it back rather than leaving the same reply in two places — but
            // never over live content.
            if !liveAnswerFieldsHaveContent, let parked = answerDraftStore.take(for: destination) {
                loadLiveAnswerFields(from: parked)
            }
            return
        }
        if let owner = answerFieldsOwnerKey {
            parkLiveAnswerFields(under: owner)
        }
        loadLiveAnswerFields(from: answerDraftStore.take(for: destination))
        answerFieldsOwnerKey = destination
    }

    /// Enters answer mode on `payload`'s branch, handing the live fields over.
    ///
    /// No capture beforehand: the hand-off decides whether the content in the bucket belongs
    /// to the arriving branch. A chat task's working composer holds content for the SAME
    /// thread the question was asked in, so it follows and nothing is parked — which is the
    /// whole reason the old "snapshot, reset, load it back again" round trip existed, and the
    /// reason it broke the moment a chat team had more than one role.
    ///
    /// `supervisorTask` is not read and not written — the task draft is a different composer's
    /// content and simply stays where it is, which is what removed the `savedSupervisorTask`
    /// stash along with every route the stash did not cover.
    func enterAnswerMode(payload: SupervisorAnswerPayload) {
        guard !isInAnswerMode else {
            updateAnswerPayload(payload)
            return
        }
        handOffLiveAnswerFields(to: Self.draftKey(for: payload))
        pendingAnswer = payload
        isInAnswerMode = true
    }

    /// Leaves answer mode with nowhere to hand the fields: parks them under the branch that
    /// owns them and clears. The panel dismissing, or arriving at a surface that binds no
    /// composer at all.
    func exitAnswerMode() {
        if let key = answerFieldsOwnerKey ?? pendingAnswer.map(Self.draftKey(for:)) {
            parkLiveAnswerFields(under: key)
        }
        clearLiveAnswerFields()
        answerFieldsOwnerKey = nil
        pendingAnswer = nil
        isInAnswerMode = false
    }

    /// Leaves answer mode INTO another composer — the chat-working field of the same task.
    /// The draft follows rather than round-tripping through the store, so the message the user
    /// was writing is still in the box when the role stops asking.
    func leaveAnswerMode(handingFieldsTo destination: AnswerDraftKey) {
        handOffLiveAnswerFields(to: destination)
        pendingAnswer = nil
        isInAnswerMode = false
    }

    /// Re-points answer mode at a question, handing the live fields to its branch.
    ///
    /// One method for every branch change — a task switch and a question moving to another
    /// ROLE of the same task are the same event seen from different distances, and the pair of
    /// methods that used to split them agreed only on the first. A team task whose leading role
    /// was answered from Watchtower hands the panel the NEXT role's question under the same
    /// task id, and the task-id comparison read that as "nothing moved".
    func updateAnswerPayload(_ payload: SupervisorAnswerPayload) {
        handOffLiveAnswerFields(to: Self.draftKey(for: payload))
        pendingAnswer = payload
    }

    /// Drops every piece of form state that is keyed by a **folder-local task id**, or
    /// that points at a file staged inside the folder being left.
    ///
    /// Task ids are allocated from each folder's own `TasksIndex.nextTaskID`, so the first
    /// task of every folder carries the same id — collision across folders is the norm,
    /// not an edge case. `NTMSOrchestrator.apply(_:)` already says exactly that and already
    /// drops `loadedTasks` for it; this map and the draft store are the same class of state
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
        answerDraftStore.discardAll()
        // Torn down directly rather than through `exitAnswerMode()`, whose first act is to
        // SAVE the very draft we are discarding.
        pendingAnswer = nil
        isInAnswerMode = false
        clearLiveAnswerFields()
        answerFieldsOwnerKey = nil
        // Task ids are folder-local, so the key names a task in the folder being left.
        aimedQuestion = nil
        // Staged files live under the closed folder's `.nanoteams/staged/<draftID>/`, so
        // their relative paths resolve to nothing under the new root. A fresh `draftID`
        // keeps the next drop out of a directory keyed to the folder we just left.
        attachments = []
        draftID = UUID()
        // Team ids are per-folder; a nil pin is re-seeded by `presentPanelSync`.
        selectedTeamID = nil
    }

    /// Discards the branch's draft for good. Called on successful submit or explicit cancel.
    func discardAnswerDraft(for key: AnswerDraftKey) {
        answerDraftStore.discard(for: key)
    }

    /// Records that the live answer bucket now holds `key`'s content. Called by the
    /// controller every time it resolves a composer bound to that bucket, so the claim is made
    /// where the binding is, not inferred later from which surface happened to precede it.
    func claimAnswerFields(for key: AnswerDraftKey) {
        answerFieldsOwnerKey = key
    }

    /// Claims the bucket for `key` and takes back the one parked draft that belongs in it.
    ///
    /// The ONE arrival the hand-off cannot describe: an UNCLAIMED bucket, where there is no
    /// owner to compare the destination against. The candidates are this task's parked
    /// branches that `continues(into:)` the destination — for a chat thread that is every
    /// branch of the task, because the thread and the questions asked in it are one
    /// conversation, and `dismissPanel` in answer mode parks under the ROLE that was asking.
    ///
    /// Exactly one candidate is unambiguous and is taken. Several are not: two roles of one
    /// task each holding an unsent reply is a real state (CLAUDE.md #45), and picking one of
    /// them for the user would be a guess. They stay parked, and the docked composer's rows
    /// offer them by name.
    ///
    /// A take rather than a read: leaving the entry behind would put the same reply in the
    /// live fields AND in the store, and the store is what those rows render — the user would
    /// be offered a copy of the text already in front of them.
    func restoreAnswerDraftToLiveFields(for key: AnswerDraftKey) {
        answerFieldsOwnerKey = key
        let candidates = answerDraftStore
            .keys(forTask: key.taskID)
            .filter { $0.continues(into: key) }
        guard candidates.count == 1, let draft = answerDraftStore.take(for: candidates[0]) else {
            return
        }
        loadLiveAnswerFields(from: draft)
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
        if case .supervisorAnswer(let session) = mode {
            let payload = session.selected
            // A ticked questionnaire with no prose beside it is a whole answer — the card IS
            // the answer field there. Only the answer branch counts it, and only for the form
            // actually on screen: the chat-working branch below queues a MESSAGE, which no
            // questionnaire is.
            return hasSubmittableAnswerText || !answerAttachments.isEmpty
                || !answerClippedTexts.isEmpty || hasAnsweredInquiry(of: payload)
        }
        // Chat-mode working lets the user queue the next message — same rules as answer mode.
        // Non-chat working has no composer, so submit is always disabled there.
        if let isChatMode = mode.liveTaskChatMode {
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

    /// True when the human has ticked or typed something into the questionnaire THIS payload is
    /// asking — not merely into some questionnaire.
    ///
    /// The identity check is the gate, not decoration. The bucket follows the panel across
    /// branches that continue one conversation, and a role that re-asks plainly leaves
    /// `payload.inquiry == nil` while the ticks are still in hand: without it, a stale form
    /// lights Send over a plain question, `submitAnswer` sends an EMPTY answer (there is no
    /// prose and the structure is scoped away downstream), and the step is unparked having been
    /// told nothing.
    ///
    /// Reads the answer's own emptiness rule rather than `byQuestionID.isEmpty`: opening the
    /// "other" field on a question mints an entry holding nothing, and a send button that lit
    /// up for an empty field the user merely opened would submit a blank answer.
    private func hasAnsweredInquiry(of payload: SupervisorAnswerPayload) -> Bool {
        guard let answered = answerInquiry?.answer(for: payload.inquiry) else { return false }
        return !answered.isEmpty
    }

    /// True when at least one clip carries something other than whitespace. Same trim as
    /// `hasTaskDraftContent`, so the submit gate and the discard prompt agree.
    private var hasSubmittableClip: Bool {
        clippedTexts.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// True when any task-draft content is present. Used to decide whether to show a
    /// "discard draft?" confirmation on cancel. Reads `hasSubmittableText`
    /// rather than `supervisorTask` for the same per-keystroke-invalidation
    /// reason as `canSubmit(mode:)`.
    var hasTaskDraftContent: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || hasSubmittableText
            || clippedTexts.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            || !attachments.isEmpty
    }

    // MARK: - Private

    /// Whether the live answer bucket is holding anything — prose, files, clips, or a
    /// questionnaire the human has started filling in.
    ///
    /// Asked through `AnswerDraft.isEmpty` so "is this worth keeping" has ONE definition, the
    /// same one the store uses to decide whether to drop an entry.
    private var liveAnswerFieldsHaveContent: Bool {
        !liveAnswerDraft.isEmpty
    }

    private var liveAnswerDraft: AnswerDraft {
        AnswerDraft(
            text: answerText,
            attachments: answerAttachments,
            clippedTexts: answerClippedTexts.texts,
            inquiry: answerInquiry
        )
    }

    /// Deposits whatever the live answer bucket holds under `key`. The store drops the entry
    /// when there is nothing worth keeping, so an emptied composer leaves no phantom draft.
    private func parkLiveAnswerFields(under key: AnswerDraftKey) {
        answerDraftStore.save(liveAnswerDraft, for: key)
    }

    /// Puts a taken draft into the live bucket, or empties it when there was none. One method
    /// for both arms: the FOUR fields must move together, and the sites that spelled the set by
    /// hand are how a clip once survived a switch its own text did not.
    private func loadLiveAnswerFields(from draft: AnswerDraft?) {
        answerText = draft?.text ?? ""
        answerAttachments = draft?.attachments ?? []
        answerClippedTexts = [Clip].minting(draft?.clippedTexts ?? [])
        answerInquiry = draft?.inquiry
    }

    private func clearLiveAnswerFields() {
        loadLiveAnswerFields(from: nil)
    }

    /// Empties the answer bucket without touching who owns it or which question is pending.
    ///
    /// For the three controller sites that consume the bucket's content and then leave answer
    /// mode — a submitted answer, a queued chat message, a cancelled draft. Each of them spelled
    /// the set by hand, and each was one field behind the moment the bucket grew a fourth: a
    /// half-filled questionnaire left standing there is parked by `exitAnswerMode` under the
    /// branch whose question was just answered, and offered back as an unsent reply to a
    /// question that no longer exists.
    func clearAnswerFields() {
        clearLiveAnswerFields()
    }

    // MARK: - Test Helpers

    #if DEBUG
    /// Full form-state reset for test isolation, driven by `QuickCaptureController._testReset()`.
    /// `exitAnswerMode()` already clears `pendingAnswer` / `isInAnswerMode` / the answer bucket.
    func _testReset() {
        if isInAnswerMode { exitAnswerMode() }
        title = ""
        supervisorTask = ""
        selectedTeamID = nil
        attachments = []
        clippedTexts = []
        clearAnswerFields()
        answerFieldsOwnerKey = nil
        aimedQuestion = nil
        answerDraftStore.discardAll()
        queuedChatMessages.removeAll()
    }
    #endif
    nonisolated deinit {}
}
