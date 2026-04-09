import Foundation

struct ToolExecutionContext: Hashable {
    var workFolderRoot: URL
    var taskID: Int
    var runID: Int
    var roleID: String
}

/// Out-of-band signal from a tool handler indicating special processing is needed.
/// Each case carries only the data relevant to that specific tool type.
enum ToolSignal: Hashable {
    case supervisorQuestion(String)
    case teammateConsultation(id: String, question: String, context: String?)
    case teamMeeting(topic: String, participants: [String], context: String?)
    case changeRequest(targetRole: String, changes: String, reasoning: String)
    case artifact(name: String, content: String, format: String?)
    case visionAnalysis(imagePath: String, prompt: String)
}

struct ToolExecutionResult: Hashable {
    var providerID: String?     // OpenAI tool_call_id for conversation continuity
    var toolName: String
    var argumentsJSON: String
    var outputJSON: String
    var isError: Bool
    var signal: ToolSignal?

    init(
        toolName: String,
        argumentsJSON: String,
        outputJSON: String,
        isError: Bool,
        signal: ToolSignal? = nil
    ) {
        self.providerID = nil
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        self.outputJSON = outputJSON
        self.isError = isError
        self.signal = signal
    }

    init(
        providerID: String?,
        toolName: String,
        argumentsJSON: String,
        outputJSON: String,
        isError: Bool,
        signal: ToolSignal? = nil
    ) {
        self.providerID = providerID
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        self.outputJSON = outputJSON
        self.isError = isError
        self.signal = signal
    }
}

final class ToolRegistry {
    typealias ToolHandler = (_ context: ToolExecutionContext, _ args: [String: Any]) throws ->
        ToolExecutionResult

    private var handlers: [String: ToolHandler] = [:]
    private var aliases: [String: String] = [:]

    /// Common tool name aliases that LLMs hallucinate.
    /// Maps alternate name → canonical registered name.
    static let defaultAliases: [String: String] = {
        typealias TN = ToolNames
        return [
            "grep": TN.search,
            "find": TN.search,
            "cat": TN.readFile,
            "read": TN.readFile,
            "print_tree": TN.listFiles,
            "tree": TN.listFiles,
            "ls": TN.listFiles,
            "list_directory": TN.listFiles,
            "create_file": TN.writeFile,
            "touch": TN.writeFile,
            "rm": TN.deleteFile,
            "remove": TN.deleteFile,
            "exec": TN.runXcodebuild,
            "build": TN.runXcodebuild,
            "test": TN.runXcodetests,
            "submit_artifact": TN.createArtifact,
            "save_artifact": TN.createArtifact,
            "creat_artifact": TN.createArtifact,
            "describe_image": TN.analyzeImage,
            "vision": TN.analyzeImage,
        ]
    }()

    /// List of all registered tool names
    var registeredToolNames: [String] {
        Array(handlers.keys)
    }

    func register(name: String, handler: @escaping ToolHandler) {
        handlers[name.lowercased()] = handler
    }

    /// Register an alias so that `alias` resolves to the handler for `canonicalName`.
    func registerAlias(_ alias: String, for canonicalName: String) {
        aliases[alias.lowercased()] = canonicalName.lowercased()
    }

    /// Returns the canonical tool name, resolving aliases.
    func canonicalName(for name: String) -> String {
        let lower = name.lowercased()
        return aliases[lower] ?? lower
    }

    func handler(for name: String) -> ToolHandler? {
        let resolved = canonicalName(for: name)
        return handlers[resolved]
    }
    nonisolated deinit {}
}
