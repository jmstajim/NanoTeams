import Foundation

// MARK: - Quick Capture Mode Coordinator

/// Pure mode resolution for Quick Capture. Maps the current app state (selected task,
/// engine state, pending Supervisor questions) to a `QuickCaptureMode`. Stateless —
/// extracted from `QuickCaptureController` so the control flow can be unit-tested
/// independently of panel lifecycle, hotkeys, and AppKit.
@MainActor
protocol QuickCaptureModeCoordinator {
    func resolveMode(
        isTaskSelected: Bool,
        activeTask: NTMSTask?,
        engineState: TeamEngineState?,
        isInitializingRun: Bool,
        activeTeam: Team?,
        forceNewTaskMode: Bool
    ) -> QuickCaptureMode
}

// MARK: - Default Implementation

@MainActor
struct DefaultQuickCaptureModeCoordinator: QuickCaptureModeCoordinator {
    func resolveMode(
        isTaskSelected: Bool,
        activeTask: NTMSTask?,
        engineState: TeamEngineState?,
        isInitializingRun: Bool,
        activeTeam: Team?,
        forceNewTaskMode: Bool
    ) -> QuickCaptureMode {
        if forceNewTaskMode { return .overlay }
        guard isTaskSelected, let task = activeTask else {
            return .overlay
        }

        // Pending Supervisor question takes priority over running state.
        //
        // `SupervisorQuestionInbox` and not a local predicate: the local one asked
        // `needsSupervisorInput && effectiveSupervisorAnswer == nil` — the flag alone, so
        // it went silent for the render passes between the ask landing in `toolCalls` and
        // the park writing the flag — read `supervisorQuestion` with no fallback to the
        // call's own arguments, took `steps.first` rather than the earliest ask (with two
        // roles waiting, a different question than the composer's leftmost chip, and the
        // other one unreachable from here), paired with the LAST assistant turn even when
        // the role kept talking after asking, and had no closed-task gate at all — so the
        // panel offered an answer field for a finished task and wrote the answer into a
        // run whose engine had already been torn down.
        //
        // ALL of them, not `.first`. Parallel roles park at once (CLAUDE.md #45), and a panel
        // built from the leading question alone did not merely hide the others — it made them
        // unreachable, so answering the first was the only route to the second. Which of them
        // is on screen is not decided here: this function is a pure map from app state, and
        // the user's pick is a presentation preference the controller applies through
        // `QuickCapturePresentationPolicy.aiming(_:at:)`.
        //
        // The failable init IS the "is anything waiting" gate — an empty session is not a
        // state the panel has.
        let waiting = SupervisorQuestionInbox.pending(in: task).map { question in
            SupervisorAnswerPayload(
                stepID: question.stepID,
                taskID: task.id,
                role: question.role,
                roleDefinition: activeTeam?.findRole(byIdentifier: question.stepID),
                question: question.headline,
                inquiry: question.inquiry,
                askCallID: question.askCallID,
                messageContent: question.paired?.content,
                thinking: question.paired?.thinking,
                isChatMode: task.isChatMode
            )
        }
        if let session = SupervisorAnswerSession(questions: waiting, selectedStepID: nil) {
            return .supervisorAnswer(session: session)
        }

        // Task is running — show the working loader. Role displayed in the title
        // MUST equal the role that `QuickCaptureController.submitQueuedMessageFromForm`
        // targets — both call `firstRunningStepRoleID(in:)` to stay in lockstep.
        if engineState == .running {
            let workingStepRoleID = QuickCaptureController.firstRunningStepRoleID(in: task)
            let workingStep = workingStepRoleID.flatMap { id in
                task.runs.last?.steps.first(where: { $0.effectiveRoleID == id })
            }
            let roleDef = workingStepRoleID.flatMap { activeTeam?.findRole(byIdentifier: $0) }
            // No arbitrary fallback: with no running step the queue target is nil (untargeted),
            // so naming the team's first role told the user their message was going somewhere
            // it was not. Both names below derive from `workingStepRoleID`, which is exactly
            // what `submitQueuedMessageFromForm` targets — an empty name renders as
            // "Thinking…", which is the honest thing to say about a role nobody has picked.
            let roleName = roleDef?.name ?? workingStep?.role.displayName ?? ""
            return .taskWorking(roleName: roleName, isChatMode: task.isChatMode)
        }

        // The run start is claimed but has not reached `engine.start()` yet. Checked
        // AFTER `.running`, because once the engine exists its answer is the better one
        // and the two overlap by a tick (CLAUDE.md #95) — and after the Supervisor
        // question, which outranks both: a task parked for an answer while a NEW start
        // is claimed must still show the question.
        //
        // Before this branch the panel resolved to `.overlay` here, so the post-submit
        // working mode survived exactly until the first `refreshPanelIfVisible` and then
        // flipped back to the new-task composer — the panel telling the user their
        // message went nowhere while the run was in fact starting.
        if isInitializingRun {
            return .taskInitializing(isChatMode: task.isChatMode)
        }

        return .overlay
    }
}

// MARK: - Visual Mode Classification

/// Coarse visual state of the panel — used to decide whether a mode change requires
/// rebuilding the SwiftUI content. Exposed as `internal` (not `private`) so tests in
/// `QuickCaptureTests.swift` can assert against it.
enum QuickCaptureVisualMode: Equatable {
    case newTask
    case answer
    case working

    init(_ mode: QuickCaptureMode) {
        switch mode {
        case .supervisorAnswer: self = .answer
        case .taskWorking, .taskInitializing: self = .working
        case .overlay: self = .newTask
        }
    }
}
