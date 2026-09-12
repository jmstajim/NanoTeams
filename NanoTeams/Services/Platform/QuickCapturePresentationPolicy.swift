import Foundation

// MARK: - Quick Capture Presentation Policy

/// The two routing decisions `QuickCaptureController` makes while driving the
/// overlay, split out of the methods that apply them.
///
/// Both were previously expressible only by reading the method body, and both
/// are the kind of rule that goes wrong silently: a toggle that takes the cold
/// path when a work folder IS open adds a Task hop to the hot keyboard-shortcut
/// path, and a submit action wired to the wrong mode makes the panel's send
/// button either do nothing or send to the wrong destination — neither throws,
/// neither logs.
///
/// Same shape as the sibling classifiers this file sits beside
/// (`QuickCaptureModeCoordinator`, `QuickCapturePanel.ResizeDecision`,
/// `QuickCapturePanel.FocusRetryDecision`): the policy CLASSIFIES, the caller
/// APPLIES.
///
/// `nonisolated` — `QuickCaptureMode` and the two result enums are plain value
/// types, so tests reach them without crossing the main actor.
nonisolated enum QuickCapturePresentationPolicy {

    // MARK: - Toggle routing

    /// What `togglePanel()` should do.
    enum ToggleRoute: Equatable, Sendable {
        /// Panel is on screen — hide it.
        case dismiss
        /// Work folder already open: present on the caller's turn, with no
        /// `Task` hop. This is the ⌃⌥⌘0 hot path; an await here is perceptible.
        case presentSynchronously
        /// No work folder yet — default storage has to be bootstrapped first,
        /// which is async.
        case bootstrapThenPresent
    }

    static func toggleRoute(isPanelVisible: Bool, hasOpenWorkFolder: Bool) -> ToggleRoute {
        if isPanelVisible { return .dismiss }
        return hasOpenWorkFolder ? .presentSynchronously : .bootstrapThenPresent
    }

    // MARK: - Submit routing

    /// Which submission path the panel's send button is wired to for a mode.
    ///
    /// `disabled` is a real, intended state — non-chat working mode renders a
    /// loader with no composer, so there is nothing to send. It is spelled as
    /// its own case rather than an optional so "we forgot to wire this mode"
    /// and "this mode deliberately sends nothing" stay distinguishable.
    enum SubmitAction: Equatable, Sendable {
        case submitSupervisorAnswer
        case queueChatMessage
        case disabled
        case createTask
    }

    static func submitAction(for mode: QuickCaptureMode) -> SubmitAction {
        switch mode {
        case .supervisorAnswer:
            return .submitSupervisorAnswer
        case .taskWorking(_, let isChatMode), .taskInitializing(let isChatMode):
            // Chat-mode working lets the user queue a message for the next
            // prompt — and during `.taskInitializing` that next prompt is the
            // FIRST one, which is the most useful moment to line something up.
            // Non-chat working is loader-only.
            return isChatMode ? .queueChatMessage : .disabled
        case .overlay:
            return .createTask
        }
    }

    // MARK: - Composer hand-off across a task switch

    /// What the live composer fields owe when the panel re-resolves onto a different task.
    ///
    /// Chat-mode `.taskWorking` and `.supervisorAnswer` bind the SAME three fields
    /// (`QuickCaptureMode.composerBindsAnswerBuckets`), and the send button reads them
    /// against `store.activeTaskID`. Re-resolving onto another task therefore re-aims the
    /// button without moving what is in the fields — so a half-typed message for one task is
    /// queued to another. `applyAnswerModeTransition` had three branches (enter answer mode,
    /// leave it, switch payload inside it) and none of them matched a working→working
    /// transition, so on that path nothing moved at all.
    enum ChatComposerHandoff: Equatable, Sendable {
        case none
        /// Park the live fields as `from`'s draft and clear them, then take `to`'s.
        case reassign(from: AnswerDraftKey, to: AnswerDraftKey)
    }

    /// - Parameter liveFieldsOwnerKey: which conversation branch the live answer bucket
    ///   currently holds content for (`QuickCaptureFormState.answerFieldsOwnerKey`), or nil when
    ///   unclaimed. The destination is a chat-mode task by the first guard, so its branch is
    ///   the task itself (`AnswerDraftKey.taskChat`).
    ///
    /// This used to ask instead whether the surface being REPLACED was the working one — a
    /// proxy that agrees only while the panel goes straight from one chat task to the next.
    /// Every other route leaves the content sitting in the bucket with the previous visual mode
    /// reading `.newTask`: navigate to Watchtower and back, or press ⌃⌥⌘0 from the new-task
    /// form, and the hand-off declined while the fields still belonged to the earlier task.
    /// Ownership is the question; the previous mode was only ever a stand-in for it.
    ///
    /// `.overlay` destinations are deliberately excluded: that surface binds the OTHER
    /// composer entirely (its own text field and its own attachment/clip pair), so nothing it
    /// shows can be confused with the answer bucket. `.supervisorAnswer` destinations are
    /// excluded because `enterAnswerMode` loads the arriving task's draft itself — the capture
    /// there is the caller's business.
    static func chatComposerHandoff(
        liveFieldsOwnerKey: AnswerDraftKey?,
        resolvedMode: QuickCaptureMode,
        newTaskID: Int?
    ) -> ChatComposerHandoff {
        guard resolvedMode.liveTaskChatMode == true,
              let from = liveFieldsOwnerKey,
              let to = newTaskID.map(AnswerDraftKey.taskChat),
              from != to
        else { return .none }
        return .reassign(from: from, to: to)
    }

    // MARK: - Render identity

    /// Everything `QuickCaptureFormView` renders out of its **by-value** `mode`, collapsed
    /// into one comparable value. The panel's rebuild decision compares THIS.
    ///
    /// It used to compare `QuickCaptureVisualMode`, which answers a different question:
    /// that enum is a deliberately coarse three-case classification (`.newTask` / `.answer`
    /// / `.working`) for "which surface is this", and it discards the supervisor payload
    /// and `taskWorking`'s `roleName` — the very fields the view prints. Two materially
    /// different contents therefore compared equal, the hosting view was left alone, and
    /// the panel showed a question the user was not answering (`submitAnswer` reads the
    /// FRESH `formState.pendingAnswer`, so the display went stale while the destination did
    /// not) or named a role that had already handed off.
    ///
    /// A string rather than `Equatable` conformance on `QuickCaptureMode`: the payload
    /// carries a `TeamRoleDefinition`, and making that Equatable to serve a panel-rebuild
    /// decision would put a wide Domain conformance behind a UI concern. This is the same
    /// fingerprint idiom the codebase already uses for exactly this shape of decision
    /// (`TimelineFingerprint`, `BadgeFingerprint`, `ResidencySettingsFingerprint`).
    ///
    /// Fields are `\u{1F}`-separated so two different splits of the same characters cannot
    /// smear into one identity.
    static func renderIdentity(of mode: QuickCaptureMode) -> String {
        let sep = "\u{1F}"
        switch mode {
        case .overlay:
            // The new-task surface renders nothing out of `mode` — everything it shows is
            // read live through `formState` or the injected store.
            return "overlay"
        case .supervisorAnswer(let session):
            let p = session.selected
            return ([
                "answer",
                // The ROW, ordered, and then the selection. Both are needed and neither
                // implies the other: a second role parking a question changes the row while
                // the selected question is untouched, and tapping another chip changes the
                // selection while the row is untouched. The panel prints both, so a rebuild
                // decision blind to either shows a stale one — which for the row means the
                // chip the user is reaching for is not on screen yet.
                //
                // A record separator inside a unit-separated field: joining ids with the same
                // character the fields use would let a row of two smear into one field of a
                // different shape.
                session.stepIDs.joined(separator: "\u{1E}"),
                p.stepID,
                String(p.taskID),
                p.role.baseID,
                p.roleDefinition?.id ?? "",
                p.question,
                // Structural, from the Domain (`SupervisorInquiry.identity`) rather than a fold
                // spelled here: the card compares the SAME string to decide whether the ticks
                // in hand answer the form on screen, and two spellings of "which questionnaire
                // is this" would let the panel rebuild for one and the card for the other.
                p.inquiry?.identity ?? "",
                p.messageContent ?? "",
                p.thinking ?? "",
                p.isChatMode ? "1" : "0",
            ] as [String]).joined(separator: sep)
        case .taskWorking(let roleName, let isChatMode):
            return (["working", roleName, isChatMode ? "1" : "0"] as [String]).joined(separator: sep)
        case .taskInitializing(let isChatMode):
            // A separate identity from "working with no role name", not a synonym: the
            // two render different captions, so collapsing them would leave the panel
            // showing `Initializing…` after the engine came up.
            return (["initializing", isChatMode ? "1" : "0"] as [String]).joined(separator: sep)
        }
    }

    // MARK: - Aim

    /// Re-points an answer mode at the question the user picked.
    ///
    /// Split from `QuickCaptureModeCoordinator` deliberately. That one is a pure map from APP
    /// state — which questions are waiting — and the answer to "which of them am I looking at"
    /// is not app state: it is a preference the user expresses by tapping a chip, held in
    /// `QuickCaptureFormState` and applied here, beside the other two routing decisions the
    /// panel makes out of a resolved mode.
    ///
    /// Every other mode passes through untouched, and so does an aim at a question that is no
    /// longer waiting — `SupervisorAnswerSession`'s init resolves the preference against the
    /// row it is given, so a selection left over from an answered round decays to the leading
    /// question instead of pinning the panel to nothing.
    ///
    /// The aim carries its TASK, and an aim naming another task is ignored outright rather than
    /// resolved. `StepExecution.id` is the role id (invariant #5), so two tasks on one team
    /// carry byte-identical step ids: a bare id picked on task A would not decay on task B, it
    /// would match, and the panel would open aimed at a role the Supervisor never picked there.
    static func aiming(_ mode: QuickCaptureMode, at aim: TaskStepKey?) -> QuickCaptureMode {
        guard case .supervisorAnswer(let session) = mode else { return mode }
        let wanted = aim.flatMap { $0.taskID == session.selected.taskID ? $0.stepID : nil }
        guard let aimed = SupervisorAnswerSession(
            questions: session.questions, selectedStepID: wanted)
        else { return mode }
        return .supervisorAnswer(session: aimed)
    }

    /// A mode that renders a composer must have somewhere to send to, and a
    /// mode with no composer must not claim a live send button. Both facts are
    /// already encoded — one on `QuickCaptureMode.expectsFocusableField`
    /// (which drives the panel's focus-retry banner) and one here — so they
    /// have to be derived from the same split or the banner fires on a panel
    /// that legitimately has no field.
    /// `@MainActor` only because `QuickCaptureMode.expectsFocusableField` is
    /// declared in a view file and inherits the app target's default isolation.
    @MainActor
    static func agreesWithFocusExpectation(_ mode: QuickCaptureMode) -> Bool {
        (submitAction(for: mode) == .disabled) != mode.expectsFocusableField
    }
}
