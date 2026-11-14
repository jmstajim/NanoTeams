import Foundation

/// Typed command for the Autovisor control plane, shared by the in-app Manager role
/// (`ToolSignal` → `LLMExecutionService+ToolResultDispatching`) and the hosted MCP server
/// (`AutovisorToolDecoding` → `AutovisorCommandExecutor`).
nonisolated enum AutovisorCommand: Hashable, Sendable {
    case listTasks
    case taskStatus(taskID: Int)
    case createManagedTask(title: String, brief: String, teamID: String?)
    case controlTask(taskID: Int, verb: ControlVerb)
    case manageRole(taskID: Int, roleID: String, verb: RoleVerb)
    case answerTaskQuestion(taskID: Int, answer: String, roleID: String?)
    case messageTask(taskID: Int, text: String, roleID: String?)
    case scheduleTask(taskID: Int, intervalMinutes: Int)
    case setWorkFolderContext(content: String)
    case waitForEvents

    init?(signal: ToolSignal?) {
        switch signal {
        case .listTasks:
            self = .listTasks
        case .taskStatus(let taskID):
            self = .taskStatus(taskID: taskID)
        case .createManagedTask(let title, let brief, let teamID):
            self = .createManagedTask(title: title, brief: brief, teamID: teamID)
        case .controlTask(let taskID, let verb):
            self = .controlTask(taskID: taskID, verb: verb)
        case .manageRole(let taskID, let roleID, let verb):
            self = .manageRole(taskID: taskID, roleID: roleID, verb: verb)
        case .answerTaskQuestion(let taskID, let answer, let roleID):
            self = .answerTaskQuestion(taskID: taskID, answer: answer, roleID: roleID)
        case .messageTask(let taskID, let text, let roleID):
            self = .messageTask(taskID: taskID, text: text, roleID: roleID)
        case .scheduleTask(let taskID, let intervalMinutes):
            self = .scheduleTask(taskID: taskID, intervalMinutes: intervalMinutes)
        case .setWorkFolderContext(let content):
            self = .setWorkFolderContext(content: content)
        case .waitForEvents:
            self = .waitForEvents
        default:
            return nil
        }
    }

    var toolSignal: ToolSignal {
        switch self {
        case .listTasks:
            .listTasks
        case .taskStatus(let taskID):
            .taskStatus(taskID: taskID)
        case .createManagedTask(let title, let brief, let teamID):
            .createManagedTask(title: title, brief: brief, teamID: teamID)
        case .controlTask(let taskID, let verb):
            .controlTask(taskID: taskID, verb: verb)
        case .manageRole(let taskID, let roleID, let verb):
            .manageRole(taskID: taskID, roleID: roleID, verb: verb)
        case .answerTaskQuestion(let taskID, let answer, let roleID):
            .answerTaskQuestion(taskID: taskID, answer: answer, roleID: roleID)
        case .messageTask(let taskID, let text, let roleID):
            .messageTask(taskID: taskID, text: text, roleID: roleID)
        case .scheduleTask(let taskID, let intervalMinutes):
            .scheduleTask(taskID: taskID, intervalMinutes: intervalMinutes)
        case .setWorkFolderContext(let content):
            .setWorkFolderContext(content: content)
        case .waitForEvents:
            .waitForEvents
        }
    }

    var autovisorAction: AutovisorAction? {
        switch self {
        case .createManagedTask(let title, let brief, let teamID):
            .createManagedTask(title: title, brief: brief, teamID: teamID)
        case .controlTask(let taskID, let verb):
            .controlTask(taskID: taskID, verb: verb)
        case .manageRole(let taskID, let roleID, let verb):
            .manageRole(taskID: taskID, roleID: roleID, verb: verb)
        case .answerTaskQuestion(let taskID, let answer, let roleID):
            .answerTaskQuestion(taskID: taskID, answer: answer, roleID: roleID)
        case .messageTask(let taskID, let text, let roleID):
            .messageTask(taskID: taskID, text: text, roleID: roleID)
        case .scheduleTask(let taskID, let intervalMinutes):
            .scheduleTask(taskID: taskID, intervalMinutes: intervalMinutes)
        case .setWorkFolderContext(let content):
            .setWorkFolderContext(content: content)
        case .listTasks, .taskStatus, .waitForEvents:
            nil
        }
    }
}
