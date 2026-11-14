import Foundation

nonisolated struct ToolExecutionContext: Hashable {
    var workFolderRoot: URL
    var taskID: Int
    var runID: Int
    /// WHO is calling — the log's attribution (`tool_calls.jsonl`, the network log). For a
    /// step it is the step's role; for a meeting turn it is the SPEAKER's definition id
    /// (`MeetingToolExecutor.turnContext`), which until the evening of 2026-09-11 was the
    /// initiator's for every speaker, so a Diff Reviewer building mid-vote was logged as
    /// the verifier building — `queuedMS` included, in the audit that reads it per role.
    var roleID: String
    /// WHICH STEP's runtime state a call belongs to — the key of every per-step registry
    /// (`stepKey`: `StreamingPreviewManager`, `executionStates`, the build gate's queue).
    /// Equal to `roleID` for a step (`StepExecution.id` is the role id) and to the
    /// INITIATOR's step for a meeting turn: the meeting runs inside that step's tool loop,
    /// and its card is the one that spins while a participant's build waits. Two fields,
    /// because the two answers differ exactly there.
    var stepID: String
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

    /// True when `ask_supervisor_form` is in the set this batch was authorized against.
    ///
    /// Read by `AskSupervisorTool` alone: it refuses a question with the questionnaire's
    /// shape (`SupervisorQuestionShape`) only while the form is there to receive it. Resolver
    /// step 4-bis makes "plain ask ⇒ form" true of every step schema, so in practice the flag
    /// is on wherever the plain ask is — the flag rather than the invariant because a refusal
    /// pointing at a tool the caller lacks is the 2026-07-25 defect, and a context that does
    /// not say the form is there (a handler test, a meeting turn, a future caller) gets the
    /// permissive reading: the numbered list parks — the only shape a role without the form can send.
    /// Per batch for the same reason `isPlanningPhase` is: `allowedToolNames` is a per-iteration
    /// fact and this context is the only channel that carries one down to a handler.
    var questionnaireAvailable: Bool = false

    /// The loopback ports this batch's `bash` commands may neither connect to nor listen on
    /// (`SeatbeltSandbox.guardedLoopbackPorts(externalAgentsPort:mcpServerPorts:llmServerPorts:)`).
    ///
    /// Per batch for the reason `isPlanningPhase` is: a server added, switched on or re-pointed
    /// mid-step is dialled at once, and until 2026-11-08 the list was read at step ENTRY and
    /// baked into `BashTool` — so every later command of the step, and every background command
    /// it started, could stand in for a server configured after the step began. Read by `BashTool`
    /// alone. The default is the floor every profile keeps anyway (the default External Agents
    /// port, `SeatbeltSandbox.effectiveGuardedPorts`): a handler test, or a meeting turn — where
    /// `bash` is excluded — guards no less than that; the step path passes the full list for every
    /// batch that runs `bash` (`LLMExecutionDelegate.seatbeltGuardedLoopbackPorts`), and `BashTool`
    /// adds what was reserved since (`LoopbackPortReservations.ports`).
    var guardedLoopbackPorts: [UInt16] = SeatbeltSandbox.effectiveGuardedPorts([])

    /// The `bash` sandbox settings of THIS batch (`BashPolicy.Sandbox`), read off the live policy
    /// per batch like the ports above: a switch, a grant or the fallback a person changes
    /// mid-step governs the next command, where a handler field baked at step entry carried the
    /// old setting to the task's close in chat mode (review 2026-11-08).
    var bashSandbox: BashPolicy.Sandbox = BashPolicy.Sandbox()

    /// `stepID` defaults to `roleID` — the step shape, and what every handler test builds.
    init(
        workFolderRoot: URL, taskID: Int, runID: Int, roleID: String, stepID: String? = nil,
        expectedArtifacts: [String] = [], isPlanningPhase: Bool = false,
        questionnaireAvailable: Bool = false,
        guardedLoopbackPorts: [UInt16] = SeatbeltSandbox.effectiveGuardedPorts([]),
        bashSandbox: BashPolicy.Sandbox = BashPolicy.Sandbox()
    ) {
        self.workFolderRoot = workFolderRoot
        self.taskID = taskID
        self.runID = runID
        self.roleID = roleID
        self.stepID = stepID ?? roleID
        self.expectedArtifacts = expectedArtifacts
        self.isPlanningPhase = isPlanningPhase
        self.questionnaireAvailable = questionnaireAvailable
        self.guardedLoopbackPorts = guardedLoopbackPorts
        self.bashSandbox = bashSandbox
    }
}

/// Out-of-band signal from a tool handler indicating special processing is needed.
/// Each case carries only the data relevant to that specific tool type.
nonisolated enum ToolSignal: Hashable {
    case supervisorQuestion(String)
    /// A structured questionnaire. Carries the decoded inquiry AND its headline separately —
    /// the headline is what every existing surface renders (banner, chip label, sidebar
    /// preview, dismissal key), and it is also what the dispatcher merges into
    /// `outcome.supervisorQuestion` so those surfaces need to know nothing about forms.
    case supervisorForm(headline: String, inquiry: SupervisorInquiry)
    case teammateConsultation(id: String, question: String, context: String?)
    case teamMeeting(topic: String, participants: [String], context: String?)
    case changeRequest(targetRole: String, changes: String, reasoning: String)
    /// `conclude_meeting` — the coordinator's own end of a meeting. Raised only inside a
    /// meeting tool loop (`MeetingToolExecutor`), where it stops the turn and the meeting;
    /// the tool is `availableToRoles == false`, so a step loop never sees it.
    case concludeMeeting(decision: String, rationale: String?, nextSteps: String?)
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
    /// `roleID` picks one of several roles waiting on the same task; `nil` answers the first.
    case answerTaskQuestion(taskID: Int, answer: String, roleID: String? = nil)
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

/// `Error` so the external surface's guards can return a finished refusal as a `Result`'s
/// failure. Declared here, with the type: `Error` refines `Sendable`, and a `Sendable`
/// conformance written in another file is a retroactive one the compiler warns about.
nonisolated struct ToolExecutionResult: Hashable, Error {
    var providerID: String?     // OpenAI tool_call_id for conversation continuity
    var toolName: String
    var argumentsJSON: String
    var outputJSON: String
    var isError: Bool
    var signal: ToolSignal?
    /// Milliseconds this call spent waiting for `XcodeBuildGate`, when it waited at all.
    ///
    /// Runtime-only, and deliberately NOT in `ToolResultMeta`: meta rides every tool result
    /// into the replayed conversation, and a per-run-varying number there would poison the
    /// stable prompt prefix — the same reason `durationMS` is not in meta. It exists because
    /// `durationMS` is suspend-INCLUSIVE, so without it an audit of
    /// `jq 'select(.durationMS > 500)'` bills a build queue to the compiler.
    var queuedMS: Double?
    /// The parser's note on how it had to read the call (`StepToolCall.argumentRepairNote`,
    /// prompt-taught only), carried onto the result so EVERY branch that builds the model's
    /// tool turn can splice it — until 2026-11-09 only the regular branch did, and a spilled
    /// argument on an exploratory search, a computer-use action or a collaboration call was
    /// recovered without the model ever being told (train-app KNOWN_ISSUES). Runtime-only, never
    /// persisted on its own: it reaches the conversation inside the tool turn.
    var argumentRepairNote: String?

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

    /// Records a non-zero queue wait. Zero stays `nil` so the log carries `queuedMS` only
    /// for calls that actually waited — a field present on every record would read as
    /// "the gate is always in the way".
    func withQueuedTime(_ queued: Duration) -> ToolExecutionResult {
        guard queued > .zero else { return self }
        var copy = self
        copy.queuedMS = queued.milliseconds
        return copy
    }
}

nonisolated extension ToolExecutionContext {
    /// The composite key every per-step runtime registry is keyed by. Built from `stepID`,
    /// not `roleID`: the two differ for a meeting turn, and two tasks on one team share
    /// step-id strings — invariant #5.
    var stepKey: TaskStepKey { TaskStepKey(taskID: taskID, stepID: stepID) }
}

nonisolated final class ToolRegistry: @unchecked Sendable {
    typealias ToolHandler = @Sendable (_ context: ToolExecutionContext, _ args: [String: Any])
        async throws -> ToolExecutionResult

    private var handlers: [String: ToolHandler] = [:]
    private var aliases: [String: String] = [:]
    /// Schemas for tools that have no type in `ToolHandlerRegistry` — today, exactly the
    /// MCP tools an external server publishes. Per REGISTRY rather than static, because a
    /// registry is built per step and the catalogue a step was resolved against is frozen
    /// for its whole life: a process-wide table would let one step's runtime type-check a
    /// call against another step's catalogue.
    private var dynamicSchemas: [String: ToolSchema] = [:]

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
            // `exec` and its shell-flavoured cousins land on `bash`, the tool that runs a
            // command. Until 2026-09-06 `exec` mapped to `run_xcodebuild` (from before `bash`
            // existed): a role holding both got a full Xcode build under a success envelope,
            // its `command` argument silently discarded (`run_xcodebuild` takes none).
            "exec": TN.bash,
            "shell": TN.bash,
            "run_command": TN.bash,
            "execute_command": TN.bash,
            "terminal": TN.bash,
            // Seen live 2026-09-07 (qwen3.8, Engineering under Manual bash with no human):
            // a schema without a shell made the model invent one. As non-aliases these got a
            // bare `tool_not_authorized`; as `bash` the withheld reason says nobody can approve.
            "run_shell": TN.bash,
            "run_shell_command": TN.bash,
            "shell_command": TN.bash,
            "run_bash": TN.bash,
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
    /// known provider prefix (`repo_browser.`, `functions.`), lowercase, then apply the
    /// common-hallucination alias map. Apply at every dispatch boundary so name
    /// resolution is consistent.
    ///
    /// Lowercased WHOLE, not only for the alias lookup: every registered name is
    /// lowercase and the runtime dispatches on `name.lowercased()`, but until the evening
    /// of 2026-09-11 an unaliased `Read_File` came back as `Read_File`, missed the exact
    /// `allowed` set and the exact schema read, and was classified `.unknownToolName` —
    /// "no variant of this name is a tool" — for a tool the role held under one spelling.
    static func resolveToolName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in knownToolNamePrefixes where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        return defaultAliases[name] ?? name
    }

    /// List of all registered tool names
    var registeredToolNames: [String] {
        Array(handlers.keys)
    }

    func register(name: String, handler: @escaping ToolHandler) {
        handlers[name.lowercased()] = handler
    }

    /// Registers a handler together with the schema its arguments are checked against.
    ///
    /// The schema half is what the runtime's argument type gate reads
    /// (`ToolRuntime.executeOne` → `schema(for:)`). Registering a handler WITHOUT one is
    /// still legal and is what every built-in tool does — their schemas live on the type in
    /// `ToolHandlerRegistry`, which is the authority for them.
    func register(name: String, schema: ToolSchema, handler: @escaping ToolHandler) {
        let key = name.lowercased()
        handlers[key] = handler
        dynamicSchemas[key] = schema
    }

    /// The schema for a tool name — the app's own where there is one, else a schema
    /// registered alongside a dynamic handler.
    ///
    /// The two tables cannot collide: a dynamic name is `mcp__<slug>__<tool>` and
    /// `MCPToolNaming.prefix` is in no built-in name. The static side is read first anyway,
    /// because the app's own tools are the answer wherever it has one.
    func schema(for name: String) -> ToolSchema? {
        let canonical = canonicalName(for: name)
        return ToolHandlerRegistry.schema(named: canonical) ?? dynamicSchemas[canonical]
    }

    /// Every dynamically-registered schema, for the seams that must describe tools the
    /// static registry has never heard of — the required-argument hint a failed call
    /// carries back to the model.
    var dynamicToolSchemas: [ToolSchema] {
        dynamicSchemas.keys.sorted().compactMap { dynamicSchemas[$0] }
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
