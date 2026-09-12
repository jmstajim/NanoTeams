import Foundation

// MARK: - Answer Draft Key

/// Which conversation branch an unsent Supervisor draft belongs to.
///
/// ## Why the branch and not the question
///
/// The obvious identity for "a half-typed answer" is the question being answered, and it is
/// the wrong one twice over. On the escalation branch a question has no persisted call at all
/// (`SupervisorQuestionInbox.PendingQuestion.askCallID` is nil there by design), so there is
/// nothing to key on; and on the ask branch the identity dies the moment the role is answered
/// and asks again — which is precisely when the human is most likely to have text in flight.
/// A branch outlives every question asked on it.
///
/// ## Why `.role` covers both an ANSWER and a MESSAGE
///
/// `StepExecution.id == effectiveRoleID == roleID`, so the composer's `.answer(stepID: X)` and
/// `.role(id: X)` chips address one role and one conversation —
/// `TeamActivityComposer.remapEquivalentRecipient` already retargets between the two shapes
/// rather than treating them as different destinations. Giving them one key makes that
/// agreement structural instead of a convention two call sites happen to share.
///
/// ## What `.taskChat` is — and what it is NOT
///
/// It is Quick Capture's chat-working composer, which queues to the TASK and names no role:
/// there is no role to key on, so the task is the branch. It is NOT "a chat-mode task's
/// drafts". An earlier draft of this type collapsed every recipient of a chat task onto it,
/// and Quest Party is a chat team with FIVE roles — so a reply parked for the Lore Master and
/// a reply parked for the NPC Creator landed on one key, and the second destroyed the first
/// with no signal but a changed one-line preview.
///
/// The two shapes still describe ONE conversation when they name the same task — the chat
/// composer and the question that chat then asks are the same thread — which is what
/// `continues(into:)` says, and why the panel's working↔answer flip moves no draft at all.
nonisolated enum AnswerDraftKey: Hashable, Sendable {
    /// One role's branch: its answer, and a message queued to it.
    case role(TaskStepKey)
    /// A task's chat thread, addressed to no particular role.
    case taskChat(Int)

    var taskID: Int {
        switch self {
        case .role(let key): key.taskID
        case .taskChat(let id): id
        }
    }

    /// The role this branch addresses, or nil for a task-wide chat thread.
    var roleID: String? {
        switch self {
        case .role(let key): key.stepID
        case .taskChat: nil
        }
    }

    /// Whether content held for THIS branch is still the same conversation at `destination`,
    /// so it should follow the composer rather than be parked.
    ///
    /// One rule, three cases:
    /// - different task → never. A reply to task A is not a reply to task B.
    /// - two different roles of one task → never. This is the case a task-id comparison got
    ///   wrong: parallel roles park at once (CLAUDE.md #45), so a role answered from another
    ///   surface hands the panel the NEXT role's question under the same task id, and the
    ///   reply written to the Product Manager was left sitting in the Tech Lead's box.
    /// - a task's chat thread on either side → always. The panel's chat composer and the
    ///   question that chat then asks are one thread: the user was writing to the role that is
    ///   now asking. This is why the working↔answer flip parks nothing — the live fields are
    ///   simply re-labelled.
    func continues(into destination: AnswerDraftKey) -> Bool {
        guard taskID == destination.taskID else { return false }
        guard let mine = roleID, let theirs = destination.roleID else { return true }
        return mine == theirs
    }
}

// MARK: - Answer Draft

/// One unsent reply: what the human typed, attached, clipped and filled in.
///
/// `inquiry` rides along so a half-filled `ask_supervisor_form` survives whatever the prose
/// beside it survives. It is deliberately in the SAME record rather than a parallel map: a form
/// and the prose typed beside it are one reply, and two stores would let one half be parked
/// while the other is not. Both park sites carry all four members — `grep -n "AnswerDraft("
/// NanoTeams` finds them.
///
/// It is a `SupervisorInquiryDraft`, not a bare answer, because a set of ticks means nothing
/// beside a different set of questions. The prose in this record can legitimately be handed to
/// another composer (a sentence you were writing is still yours); the ticks cannot, and the
/// questionnaire id is what lets every reader tell the two apart instead of discovering it by
/// rendering someone else's decisions as blank.
nonisolated struct AnswerDraft: Equatable {
    var text: String
    var attachments: [StagedAttachment]
    var clippedTexts: [String]
    var inquiry: SupervisorInquiryDraft?

    init(
        text: String = "",
        attachments: [StagedAttachment] = [],
        clippedTexts: [String] = [],
        inquiry: SupervisorInquiryDraft? = nil
    ) {
        self.text = text
        self.attachments = attachments
        self.clippedTexts = clippedTexts
        self.inquiry = inquiry
    }

    /// Nothing worth keeping. Text is trimmed (whitespace is not a draft); the two buckets are
    /// judged by array emptiness, which is the contract the composer's own submit gate uses;
    /// a form with no decision in it counts as absent (`SupervisorInquiryDraft.isEmpty`).
    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && attachments.isEmpty
            && clippedTexts.isEmpty
            && (inquiry?.isEmpty ?? true)
    }
}

// MARK: - Supervisor Answer Draft Store

/// Every unsent Supervisor draft that no composer is currently holding.
///
/// ## Take-and-return, not read-and-copy
///
/// `save` deposits a draft for a branch nobody is editing (or REMOVES the entry when the draft
/// is empty); `take` hands it back and removes it. So the store never holds an entry under the
/// key a composer is editing, and "does this chip have an unfinished reply?" has exactly one
/// answer — the presence of the entry — instead of two that can disagree (the map said yes,
/// the live fields already held the same text).
///
/// The corollary that matters for cost: there is no write per keystroke. A draft moves only
/// when the human retargets, when a surface hands the fields to another branch, or when a
/// chip disappears from under a half-typed reply. That is why the map may be OBSERVED — the
/// parked-draft row renders straight off it — where the per-task map it replaces had to be
/// `@ObservationIgnored` to keep save-on-every-transition from churning the panel.
@Observable @MainActor
final class SupervisorAnswerDraftStore {
    private var drafts: [AnswerDraftKey: AnswerDraft] = [:]

    /// Deposits `draft` under `key`, or removes the entry when there is nothing worth keeping.
    /// The removal arm is what keeps an emptied composer from leaving a phantom draft dot.
    func save(_ draft: AnswerDraft, for key: AnswerDraftKey) {
        if draft.isEmpty {
            drafts.removeValue(forKey: key)
        } else {
            drafts[key] = draft
        }
    }

    /// Hands the draft back AND removes it — the caller now owns the content.
    func take(for key: AnswerDraftKey) -> AnswerDraft? {
        drafts.removeValue(forKey: key)
    }

    /// Reads without removing. For rendering only (a row's preview, a chip's dot); anything
    /// that puts the content back into a composer must `take`, or the store and the live
    /// fields hold the same draft twice.
    func peek(for key: AnswerDraftKey) -> AnswerDraft? {
        drafts[key]
    }

    /// Drops the draft unconditionally — an explicit "discard", or a delivered answer.
    func discard(for key: AnswerDraftKey) {
        drafts.removeValue(forKey: key)
    }

    /// Every branch of `taskID` holding an unsent draft, in a stable order.
    ///
    /// Ordered because the parked-draft rows are a `ForEach`: a `Dictionary.keys` order is
    /// unspecified and varies per process, so rows would shuffle between body passes.
    func keys(forTask taskID: Int) -> [AnswerDraftKey] {
        drafts.keys
            .filter { $0.taskID == taskID }
            .sorted { ($0.roleID ?? "") < ($1.roleID ?? "") }
    }

    /// Folder switch: task ids are allocated per work folder, so every key in here names a
    /// task in the folder being left (see `QuickCaptureFormState.discardFolderScopedState`).
    func discardAll() {
        drafts.removeAll()
    }

    #if DEBUG
    var _testDraftCount: Int { drafts.count }
    #endif
}
