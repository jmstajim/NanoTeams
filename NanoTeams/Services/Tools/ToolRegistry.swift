import Foundation

nonisolated struct ToolExecutionContext: Hashable {
    var workFolderRoot: URL
    var taskID: Int
    var runID: Int
    var roleID: String
    /// Names the role is expected to produce via `create_artifact`. Sourced from
    /// `step.expectedArtifacts`. Used by `CreateArtifactTool` to give the model a
    /// concrete fix-up list when it submits a wrong-shaped name (e.g. "index.html"
    /// instead of "Спецификация калькулятора"). Empty for roles without
    /// declared deliverables (advisory/chat roles).
    var expectedArtifacts: [String] = []
    /// True only while the owning step is in its PLANNING phase.
    ///
    /// Per-CALL, and that is forced rather than chosen: the phase flips in the MIDDLE of a step,
    /// while a handler's own dependencies are baked ONCE per step by
    /// `ToolHandlerRegistry.buildHandlers` (driven from `+StepLifecycle`). This context is built
    /// per tool BATCH, so it is the only channel that can carry a per-iteration fact down to a
    /// `ToolHandler`.
    ///
    /// Read by `BashTool` alone — to narrow its Seatbelt profile to "no writes" for the duration
    /// of the phase, which is what lets `PlanningPhasePolicy` admit `bash` at all. Every other
    /// handler ignores it. Defaults `false`: meetings build their own context and never enter
    /// the phase, and the default keeps the tool-handler test corpus compiling unchanged.
    var isPlanningPhase: Bool = false
}

/// Out-of-band signal from a tool handler indicating special processing is needed.
/// Each case carries only the data relevant to that specific tool type.
nonisolated enum ToolSignal: Hashable {
    case supervisorQuestion(String)
    case teammateConsultation(id: String, question: String, context: String?)
    case teamMeeting(topic: String, participants: [String], context: String?)
    case changeRequest(targetRole: String, changes: String, reasoning: String)
    case artifact(name: String, content: String, format: String?)
    case visionAnalysis(imagePath: String, prompt: String)
    case teamCreation(config: GeneratedTeamConfig)
    case exploratorySearch(ExploratorySearchPayload)
    /// `delegate_to_team` invocation: handler awaits child task completion synchronously.
    /// `teamID` is the raw string from tool args (a UUID for an existing team or the
    /// `DelegationConstants.generatedTeamSentinel` marker for on-the-fly generation).
    case delegateToTeam(teamID: String, taskBrief: String)
    /// Companion to `delegate_to_team` — auto-injected when the role has
    /// `delegate_to_team` in its toolset. Used by the role to abort a
    /// delegation paused via `parentMessageQueued` (Supervisor interrupt).
    /// Stops the child engine, clears delegation fields on the parent step.
    case cancelDelegation(childTaskID: Int, reason: String?)
    /// Companion to `delegate_to_team`. Un-pauses a paused child engine and
    /// re-enters the awaiter loop, blocking until the child reaches a
    /// terminal state (or another Supervisor interrupt fires). Returns the
    /// same envelope shape as the original `delegate_to_team` call.
    case resumeDelegation(childTaskID: Int)
    /// Companion to `delegate_to_team`. Forwards a Supervisor message into
    /// the child team's Supervisor-input flow (e.g. as guidance / corrections),
    /// un-pauses, and re-enters the awaiter loop.
    case forwardToTeam(childTaskID: Int, message: String)

    // MARK: - Autovisor (10)
    // Management tools for the per-folder automated Supervisor. All route through
    // the collaboration deferred-handler path (sandbox handlers can't reach the
    // orchestrator). Reads carry only their args; writes are translated to a
    // `AutovisorAction` by their async handler and applied via the single
    // `performAutovisorAction` delegate hook.
    case listTasks
    case taskStatus(taskID: Int)
    case createManagedTask(title: String, brief: String, teamID: String?)
    case controlTask(taskID: Int, verb: ControlVerb)
    case manageRole(taskID: Int, roleID: String, verb: RoleVerb)
    case answerTaskQuestion(taskID: Int, answer: String)
    case messageTask(taskID: Int, text: String, roleID: String?)
    case scheduleTask(taskID: Int, intervalMinutes: Int)
    case setWorkFolderContext(content: String)
    /// `wait_for_events` — the manager declares it has nothing left to do this
    /// pass. Routes to a handler that flips the step's `parkForEventsRequested`
    /// flag so the tool loop parks the step at `.needsSupervisorInput` (session
    /// preserved — a human message continues the conversation) at the next
    /// iteration boundary.
    /// Not a `AutovisorAction` — it mutates execution state, not task state.
    case waitForEvents

    /// Computer-use action (screenshot / click / type / key / scroll). The handler
    /// only validates args + emits this signal; the real OS work runs in the service
    /// finalizer (`LLMExecutionService+ComputerUse.swift`), which has the per-step
    /// state a detached `ToolHandler` cannot reach (last-capture conversion metadata).
    case computerUse(ComputerUseAction)
}

/// Payload for a `exploratory: true` call on `SearchTool`. Threaded through
/// `ToolSignal.exploratorySearch` so the processor gets every argument the handler
/// parsed, without 8 positional fields on the enum case. `mode` is stored as
/// the strongly-typed enum so the processor doesn't re-parse a raw string.
///
/// Invariants enforced by the throwing init:
/// - `query` must be non-empty after trimming (empty queries would reach the
///   executor and never match anything — the LLM gets nothing back and
///   can't tell why).
/// - Numeric fields (`maxResults`, `offset`, context lines) are
///   clamped to sane ranges so a misbehaving LLM that emits `Int.max` or
///   negative values can't crash the executor budget math.
/// - `paths` is normalized: empty arrays collapse to `nil` so consumers
///   don't have to branch on both "unset" and "set but empty".
nonisolated struct ExploratorySearchPayload: Hashable {
    let query: String
    let mode: SearchMode
    let paths: [String]?
    let fileGlob: String?
    let contextBefore: Int
    let contextAfter: Int
    let maxResults: Int
    let offset: Int

    /// Upper bound on `maxResults`, i.e. the largest page a caller can request.
    ///
    /// Single source of truth, deliberately aliased to `AppDefaults.searchMaxResultsMax` so the
    /// Settings stepper range, the `search` tool description and the runtime clamp cannot drift.
    /// They had already drifted once: Settings capped the user's default at 500, the schema told
    /// the model 500, and the executor enforced 1000 — so a model asking for 800 got 800 while
    /// being told it could not.
    ///
    /// Do not restate the value in prose here. This doc block previously said "max 500" while the
    /// constant read 300 — an anti-drift comment that had itself drifted. The schema string
    /// interpolates the constant for the same reason.
    static let maxAllowedResults = AppDefaults.searchMaxResultsMax
    /// Upper bound on `contextBefore`/`contextAfter` — a handful of lines
    /// either side is all any sensible review flow needs; wider only bloats
    /// the envelope.
    static let maxAllowedContextLines = 100

    enum ValidationError: Error, Equatable {
        case emptyQuery
    }

    init(
        query: String,
        mode: SearchMode,
        paths: [String]?,
        fileGlob: String?,
        contextBefore: Int,
        contextAfter: Int,
        maxResults: Int,
        offset: Int = 0
    ) throws {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.emptyQuery }
        self.query = query  // preserve original casing/spacing for display
        self.mode = mode
        // Normalize empty arrays to nil so the consumer switches on one
        // shape, not two.
        if let paths, !paths.isEmpty {
            self.paths = paths
        } else {
            self.paths = nil
        }
        self.fileGlob = fileGlob
        self.contextBefore = max(0, min(contextBefore, Self.maxAllowedContextLines))
        self.contextAfter = max(0, min(contextAfter, Self.maxAllowedContextLines))
        self.maxResults = max(1, min(maxResults, Self.maxAllowedResults))
        self.offset = max(0, offset)
    }
}

nonisolated struct ToolExecutionResult: Hashable {
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

nonisolated final class ToolRegistry: @unchecked Sendable {
    typealias ToolHandler = @Sendable (_ context: ToolExecutionContext, _ args: [String: Any])
        async throws -> ToolExecutionResult

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

    /// Provider / training-set prefixes some models prepend to tool names.
    /// Known examples: `openai/gpt-oss-*` emits `functions.*` (Harmony protocol)
    /// and `repo_browser.*` (reflecting Anthropic's Code-Execution tool namespace
    /// that leaked into training data). Stripped before alias lookup and dispatch.
    static let knownToolNamePrefixes: [String] = ["repo_browser.", "functions."]

    /// Canonicalize a raw tool name emitted by an LLM: trim whitespace, strip a
    /// known provider prefix (`repo_browser.`, `functions.`), then apply the
    /// common-hallucination alias map. Apply at every dispatch boundary so
    /// name resolution is consistent.
    static func resolveToolName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = name.lowercased()
        for prefix in knownToolNamePrefixes where lower.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        return defaultAliases[name.lowercased()] ?? name
    }

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
