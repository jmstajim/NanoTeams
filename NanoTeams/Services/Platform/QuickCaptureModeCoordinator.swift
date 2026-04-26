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
        activeTeam: Team?,
        forceNewTaskMode: Bool
    ) -> QuickCaptureMode {
        if forceNewTaskMode { return .overlay }
        guard isTaskSelected, let task = activeTask else {
            return .overlay
        }

        // Pending Supervisor question takes priority over running state.
        if let run = task.runs.last,
           let step = run.steps.first(where: { $0.needsSupervisorInput && $0.effectiveSupervisorAnswer == nil }),
           let question = step.supervisorQuestion {
            let roleDef = activeTeam?.findRole(byIdentifier: step.effectiveRoleID)
            let lastAssistant = step.llmConversation.last(where: { $0.role == .assistant })
            return .supervisorAnswer(payload: SupervisorAnswerPayload(
                stepID: step.id,
                taskID: task.id,
                role: step.role,
                roleDefinition: roleDef,
                question: question,
                messageContent: lastAssistant?.content,
                thinking: lastAssistant?.thinking,
                isChatMode: task.isChatMode
            ))
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
            let fallbackName = activeTeam?.nonSupervisorRoles.first?.name ?? ""
            let roleName = roleDef?.name ?? workingStep?.role.displayName ?? fallbackName
            return .taskWorking(roleName: roleName, isChatMode: task.isChatMode)
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
        case .taskWorking: self = .working
        case .overlay, .sheet: self = .newTask
        }
    }
}
