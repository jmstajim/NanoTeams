import Foundation

/// Executes a decoded `AutovisorCommand` for a given `AutovisorActor` and folder lifecycle,
/// returning the canonical NanoTeams JSON envelope.
@MainActor
struct AutovisorCommandExecutor {
    weak var executionService: LLMExecutionService?
    weak var delegate: (any LLMStateDelegate)?

    init(
        executionService: LLMExecutionService? = nil,
        delegate: (any LLMStateDelegate)? = nil
    ) {
        self.executionService = executionService
        self.delegate = delegate
    }

    func execute(
        _ command: AutovisorCommand,
        as actor: AutovisorActor = .builtInManager,
        stepID: String = AutovisorConstants.managerRoleSystemID,
        taskID: Int = 0,
        within lifecycle: WorkFolderLifecycle? = nil,
        now: Date = MonotonicClock.shared.now()
    ) async -> String {
        guard let executionService else {
            return makeErrorEnvelope(
                code: .commandFailed,
                message: LLMExecutionService.autovisorUnavailableMessage
            )
        }
        // Exhaustive on purpose: a new command does not compile until it is routed here, where a
        // chain of `if case` tests would hand it to whichever handler came last.
        switch command {
        case .listTasks:
            return await executionService.handleListTasks(now: now)
        case .taskStatus(let targetTaskID):
            return await executionService.handleTaskStatus(taskID: targetTaskID, now: now)
        case .waitForEvents:
            return await executionService.handleWaitForEvents(stepID: stepID, taskID: taskID)
        case .createManagedTask,
             .controlTask,
             .manageRole,
             .answerTaskQuestion,
             .messageTask,
             .scheduleTask,
             .setWorkFolderContext:
            guard let action = command.autovisorAction else {
                // `AutovisorCommand.autovisorAction` maps every case of this arm to an action;
                // reaching here means the two switches drifted.
                assertionFailure("AutovisorCommandExecutor: \(command) is routed as an action but maps to none")
                return makeErrorEnvelope(
                    code: .commandFailed,
                    message: LLMExecutionService.autovisorUnavailableMessage
                )
            }
            return await executionService.applyAutovisorAction(
                action,
                as: actor,
                within: lifecycle
            )
        }
    }
}
