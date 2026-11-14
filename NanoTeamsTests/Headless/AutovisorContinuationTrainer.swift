import Foundation
@testable import NanoTeams

// MARK: - Results

struct AutovisorContinuationTrainerRunResult: Codable, Equatable {
    var provider: String
    var baseURL: String
    var model: String
    var toolCallingMode: String
    var appVersion: String
    var runtimePromptVersion: String
    var runs: Int
    var startedAt: Date
    var elapsedSeconds: Double
    var cases: [AutovisorContinuationCaseResult]
}

struct AutovisorContinuationCaseResult: Codable, Equatable {
    var scenario: AutovisorContinuationScenario
    var arm: AutovisorContinuationArm
    var run: Int
    var systemPromptChars: Int
    var injectedEnvelope: String
    var toolNames: [String]
    var firstArgumentsJSON: String?
    var repeatedSameAction: Bool
    var askedSupervisor: Bool
    var wentIdle: Bool
    var assistantContent: String
    var elapsedSeconds: Double
    var verdict: OneShotPromptVerdict
}

// MARK: - Built Prompt Fixture

struct AutovisorContinuationPromptFixture {
    var scenario: AutovisorContinuationScenario
    var arm: AutovisorContinuationArm
    var roleID: String
    var roleName: String
    var systemPromptChars: Int
    var messages: [ChatMessage]
    var tools: [ToolSchema]
    var targetToolName: String
    var targetArgumentsJSON: String
    var injectedEnvelope: String
}

// MARK: - Trainer

/// Drives the Autovisor Manager (scenarios 1–5) and Coding Agent (scenario 6) from a fixed
/// multi-turn conversation history up to the target tool-result slot, injects either the
/// current envelope (`.before`, Variant A) or the new envelope (`.after`, Variant B), and
/// runs `runs` continuations (default N=2, playbook REC.10) against a configured LLM.
///
/// The two `message_task` scenarios and scenario 6 take every tool result from production's
/// renderers (`+ProductionEnvelopes`, `LLMExecutionService.renderChildPausedEnvelope`); the
/// other three still replay hand-written envelopes.
@MainActor
final class AutovisorContinuationTrainer {
    let config: AutovisorContinuationTrainerConfig
    private let client: any LLMClient
    private let logger: NetworkLogger
    private static let outputCap = 2000

    init(config: AutovisorContinuationTrainerConfig, client: (any LLMClient)? = nil) {
        self.config = config
        self.client = client ?? LLMClientRouter()
        let dir = URL(fileURLWithPath: config.outputPath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.logger = NetworkLogger(logURL: dir.appendingPathComponent("network_log.jsonl"))
        RuntimePromptFingerprint.prime()
    }

    func run() async throws -> AutovisorContinuationTrainerRunResult {
        let started = Date()
        let resolvedMode = await resolveToolCallingMode()
        let llmConfig = config.toLLMConfig(toolCallingMode: resolvedMode)
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "2.0.0"

        var results: [AutovisorContinuationCaseResult] = []
        for scenario in config.resolvedScenarios {
            for arm in config.resolvedVariant.activeArms {
                if arm == .before && !scenario.supportsBeforeArm {
                    continue
                }
                let fixture = try await Self.buildFixture(
                    scenario: scenario,
                    arm: arm,
                    toolCallingMode: resolvedMode
                )
                print("[TRAINER] ▶ \(scenario.rawValue) [\(arm.rawValue)] (system_prompt_chars=\(fixture.systemPromptChars))")
                for runIndex in 1...config.resolvedRuns {
                    let row = await runSingleCase(
                        fixture: fixture,
                        runIndex: runIndex,
                        llmConfig: llmConfig
                    )
                    results.append(row)
                }
            }
        }

        let runResult = AutovisorContinuationTrainerRunResult(
            provider: config.resolvedProvider.rawValue,
            baseURL: config.resolvedBaseURL,
            model: config.resolvedModel,
            toolCallingMode: resolvedMode.rawValue,
            appVersion: appVersion,
            runtimePromptVersion: RuntimePromptFingerprint.current,
            runs: config.resolvedRuns,
            startedAt: started,
            elapsedSeconds: Date().timeIntervalSince(started),
            cases: results
        )
        try write(runResult)
        return runResult
    }

    // MARK: - Mode Resolution & Single Continuation

    private func resolveToolCallingMode() async -> ToolCallingMode {
        let preference = config.resolvedToolCallingPreference
        guard preference == .auto else {
            return ToolCallingModeResolver.resolve(preference: preference, providerSupport: nil)
        }
        let probeConfig = config.toLLMConfig()
        let support = await client.toolCallingSupport(config: probeConfig)
        return ToolCallingModeResolver.resolve(preference: .auto, providerSupport: support)
    }

    private func runSingleCase(
        fixture: AutovisorContinuationPromptFixture,
        runIndex: Int,
        llmConfig: LLMConfig
    ) async -> AutovisorContinuationCaseResult {
        let started = Date()
        let outcome: (content: String, nativeCalls: [StepToolCall], errorNote: String?)? =
            await withTimeout(seconds: config.resolvedCaseTimeout) { [client, logger] in
                do {
                    var content = ""
                    var reasoning = ""
                    var accumulator = ToolCallAccumulator()
                    let stream = client.streamChat(
                        config: llmConfig,
                        messages: fixture.messages,
                        tools: fixture.tools,
                        logger: logger,
                        stepID: fixture.roleID,
                        roleName: fixture.roleName
                    )
                    for try await event in stream {
                        content += event.contentDelta
                        reasoning += event.thinkingDelta
                        if !event.toolCallDeltas.isEmpty {
                            accumulator.absorb(event.toolCallDeltas)
                        }
                    }
                    let effectiveContent = ModelReplyChannels.answer(
                        content: content,
                        reasoning: reasoning,
                        prepare: { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    )
                    return (effectiveContent, accumulator.finalize(), nil)
                } catch {
                    return ("error: \(error)", [], "\(type(of: error))")
                }
            }

        let elapsed = Date().timeIntervalSince(started)
        guard let outcome else {
            let verdict = OneShotPromptVerdict(
                passed: false,
                note: "timeout after \(Int(elapsed))s",
                flags: [.timeout]
            )
            print("[TRAINER]   FAIL \(fixture.scenario.rawValue)/\(fixture.arm.rawValue) run \(runIndex) — \(verdict.note)")
            return AutovisorContinuationCaseResult(
                scenario: fixture.scenario,
                arm: fixture.arm,
                run: runIndex,
                systemPromptChars: fixture.systemPromptChars,
                injectedEnvelope: fixture.injectedEnvelope,
                toolNames: [],
                firstArgumentsJSON: nil,
                repeatedSameAction: false,
                askedSupervisor: false,
                wentIdle: false,
                assistantContent: "",
                elapsedSeconds: elapsed,
                verdict: verdict
            )
        }

        if let errorNote = outcome.errorNote {
            let verdict = OneShotPromptVerdict(passed: false, note: errorNote, flags: [.error])
            print("[TRAINER]   FAIL \(fixture.scenario.rawValue)/\(fixture.arm.rawValue) run \(runIndex) — \(verdict.note)")
            return AutovisorContinuationCaseResult(
                scenario: fixture.scenario,
                arm: fixture.arm,
                run: runIndex,
                systemPromptChars: fixture.systemPromptChars,
                injectedEnvelope: fixture.injectedEnvelope,
                toolNames: [],
                firstArgumentsJSON: nil,
                repeatedSameAction: false,
                askedSupervisor: false,
                wentIdle: false,
                assistantContent: String(outcome.content.prefix(Self.outputCap)),
                elapsedSeconds: elapsed,
                verdict: verdict
            )
        }

        let classified = Self.classify(
            scenario: fixture.scenario,
            arm: fixture.arm,
            content: outcome.content,
            nativeCalls: outcome.nativeCalls,
            advertisedTools: fixture.tools,
            targetToolName: fixture.targetToolName,
            targetArgumentsJSON: fixture.targetArgumentsJSON
        )
        print(
            "[TRAINER]   \(classified.verdict.passed ? "PASS" : "FAIL") "
            + "\(fixture.scenario.rawValue)/\(fixture.arm.rawValue) run \(runIndex) — "
            + "tools=\(classified.toolNames) repeat=\(classified.repeatedSameAction) "
            + "idle=\(classified.wentIdle) (\(classified.verdict.note), \(Int(elapsed))s)"
        )
        return AutovisorContinuationCaseResult(
            scenario: fixture.scenario,
            arm: fixture.arm,
            run: runIndex,
            systemPromptChars: fixture.systemPromptChars,
            injectedEnvelope: fixture.injectedEnvelope,
            toolNames: classified.toolNames,
            firstArgumentsJSON: classified.firstArgumentsJSON,
            repeatedSameAction: classified.repeatedSameAction,
            askedSupervisor: classified.askedSupervisor,
            wentIdle: classified.wentIdle,
            assistantContent: String(outcome.content.prefix(Self.outputCap)),
            elapsedSeconds: elapsed,
            verdict: classified.verdict
        )
    }

    // MARK: - Fixture Construction

    static func buildFixture(
        scenario: AutovisorContinuationScenario,
        arm: AutovisorContinuationArm,
        toolCallingMode: ToolCallingMode = .promptTaught
    ) async throws -> AutovisorContinuationPromptFixture {
        switch scenario {
        case .delegationChildPausedTimeout:
            return buildDelegationFixture(arm: arm, toolCallingMode: toolCallingMode)
        case .pauseNoEngine, .repeatedClose, .messageTaskInReview, .messageTaskOnPaused, .rosterTwoQuestions:
            return try await buildManagerFixture(scenario: scenario, arm: arm, toolCallingMode: toolCallingMode)
        }
    }

    private static func buildManagerFixture(
        scenario: AutovisorContinuationScenario,
        arm: AutovisorContinuationArm,
        toolCallingMode: ToolCallingMode
    ) async throws -> AutovisorContinuationPromptFixture {
        var teams: [Team] = [
            TeamTemplateFactory.codingAssistant(),
            TeamTemplateFactory.codingAgent(),
            TeamTemplateFactory.engineering(),
            TeamTemplateFactory.autovisor(),
        ]
        _ = TeamManagementService.syncAutovisorTeamToTemplate(teams: &teams)
        let autovisorTeam = teams.first(where: { $0.templateID == AutovisorConstants.teamTemplateID })!
        let roleDef = autovisorTeam.roles.first(where: { $0.systemRoleID == Role.autovisor.baseID })!
        let role = Role.fromDefinition(roleDef)
        let step = StepExecution.make(for: roleDef)
        let run = Run(id: 0, steps: [step], teamID: autovisorTeam.id)

        let goalBrief: String
        switch scenario {
        case .pauseNoEngine:
            goalBrief = "Check Task #2 ('Fix login crash'). Make sure it is paused, then send a correction to software_engineer to use async/await."
        case .repeatedClose:
            goalBrief = "Close finished Task #3 ('Update README'), then park with wait_for_events."
        case .messageTaskInReview:
            goalBrief = "Review Task #4 ('Add unit tests'). Have software_engineer add unit tests covering negative inputs before you accept the task."
        case .messageTaskOnPaused:
            goalBrief = "Task #5 ('Refactor networking') is paused. Send it a message to keep URLSessionConfiguration injection intact so it continues working, then wait for events."
        case .rosterTwoQuestions:
            goalBrief = "Answer all pending supervisor questions on Task #6 ('Migrate database schema') in this pass, then park with wait_for_events."
        case .delegationChildPausedTimeout:
            goalBrief = ""
        }

        let task = NTMSTask(
            id: 1,
            title: "Autovisor",
            supervisorTask: goalBrief,
            runs: [run],
            preferredTeamID: autovisorTeam.id
        )

        let projection = WorkFolderProjection(
            state: WorkFolderState(name: "TrainerProject"),
            settings: ProjectSettings(),
            teams: teams
        )
        let rawSchemas = LLMExecutionService.resolveToolSchemas(
            for: role,
            team: autovisorTeam,
            allTeams: teams,
            selectedScheme: nil,
            isVisionConfigured: false,
            approval: ToolApprovalAvailability(
                bashMode: .off,
                computerUseMode: .off,
                humanPresent: false
            ),
            autovisorTeamPolicy: AutovisorTeamPolicy(settings: projection.settings)
        )
        let toolSchemas = LLMExecutionService.filterForDefaultStorage(rawSchemas, isDefaultStorage: false)

        let context = PromptBuilder.Context(
            task: task,
            step: step,
            stepIndex: 0,
            run: run,
            workFolder: projection,
            artifactReader: { _ in nil },
            activeTeam: autovisorTeam,
            roleDefinition: roleDef,
            globalContext: AppDefaults.globalContext,
            agentInstructions: nil,
            attachedSkills: [],
            toolCallingMode: toolCallingMode
        )
        var messages = PromptBuilder.buildChatMessages(context: context, tools: toolSchemas)
        let systemPromptChars = messages.first(where: { $0.role == MessageRole.system })?.content?.count ?? 0

        let (history, targetToolName, targetArgs, injectedEnvelope) = try await managerHistory(
            scenario: scenario,
            arm: arm
        )
        messages.append(contentsOf: history)

        return AutovisorContinuationPromptFixture(
            scenario: scenario,
            arm: arm,
            roleID: roleDef.id,
            roleName: roleDef.name,
            systemPromptChars: systemPromptChars,
            messages: messages,
            tools: toolSchemas,
            targetToolName: targetToolName,
            targetArgumentsJSON: targetArgs,
            injectedEnvelope: injectedEnvelope
        )
    }

    private static func managerHistory(
        scenario: AutovisorContinuationScenario,
        arm: AutovisorContinuationArm
    ) async throws -> (messages: [ChatMessage], targetToolName: String, targetArgs: String, injectedEnvelope: String) {
        switch scenario {
        case .pauseNoEngine:
            let call1ID = "call_list_1"
            let listEnvelope = #"{"data":{"tasks":[{"chat_mode":false,"id":2,"status":"paused","title":"Fix login crash","updated_seconds_ago":45}]},"ok":true}"#
            let call2ID = "call_pause_2"
            let targetArgs = #"{"action":"pause","task_id":2}"#
            let injected: String
            switch arm {
            case .before:
                injected = #"{"data":{"message":"Paused task #2.","status":"ok"},"ok":true}"#
            case .after:
                injected = #"{"error":{"code":"COMMAND_FAILED","message":"Could not pause task #2 — it is already paused."},"ok":false}"#
            }
            let turns: [ChatMessage] = [
                ChatMessage(role: .assistant, toolCalls: [
                    ChatToolCall(id: call1ID, name: ToolNames.listTasks, argumentsJSON: "{}")
                ]),
                ChatMessage(role: .tool, content: listEnvelope, toolCallID: call1ID),
                ChatMessage(role: .assistant, toolCalls: [
                    ChatToolCall(id: call2ID, name: ToolNames.controlTask, argumentsJSON: targetArgs)
                ]),
                ChatMessage(role: .tool, content: injected, toolCallID: call2ID),
            ]
            return (turns, ToolNames.controlTask, targetArgs, injected)

        case .repeatedClose:
            let call1ID = "call_list_1"
            let listEnvelope = #"{"data":{"tasks":[{"chat_mode":false,"id":3,"status":"done","title":"Update README","updated_seconds_ago":180}]},"ok":true}"#
            let call2ID = "call_close_2"
            let targetArgs = #"{"action":"close","task_id":3}"#
            let injected: String
            switch arm {
            case .before:
                injected = #"{"data":{"message":"Closed task #3.","status":"ok"},"ok":true}"#
            case .after:
                injected = #"{"error":{"code":"COMMAND_FAILED","message":"Task #3 is already closed."},"ok":false}"#
            }
            let turns: [ChatMessage] = [
                ChatMessage(role: .assistant, toolCalls: [
                    ChatToolCall(id: call1ID, name: ToolNames.listTasks, argumentsJSON: "{}")
                ]),
                ChatMessage(role: .tool, content: listEnvelope, toolCallID: call1ID),
                ChatMessage(role: .assistant, toolCalls: [
                    ChatToolCall(id: call2ID, name: ToolNames.controlTask, argumentsJSON: targetArgs)
                ]),
                ChatMessage(role: .tool, content: injected, toolCallID: call2ID),
            ]
            return (turns, ToolNames.controlTask, targetArgs, injected)

        case .messageTaskInReview:
            return try await messageScenarioTurns(
                scenario: scenario,
                arm: arm,
                statusArgs: #"{"task_id":4}"#,
                targetArgs: #"{"message":"Please also add unit tests covering negative inputs.","task_id":4}"#
            )

        case .messageTaskOnPaused:
            return try await messageScenarioTurns(
                scenario: scenario,
                arm: arm,
                statusArgs: #"{"task_id":5}"#,
                targetArgs: #"{"message":"Keep URLSessionConfiguration injection intact.","task_id":5}"#
            )

        case .rosterTwoQuestions:
            let call1ID = "call_list_1"
            let listEnvelope: String
            let statusEnvelope: String
            switch arm {
            case .before:
                listEnvelope = #"{"data":{"tasks":[{"chat_mode":false,"id":6,"status":"running","title":"Migrate database schema","updated_seconds_ago":12,"waiting_for_supervisor":true}]},"ok":true}"#
                statusEnvelope = #"{"data":{"artifacts":[],"chat_mode":false,"elapsed_seconds":40,"pending_question":"Should the migration keep the legacy v1 table as a backup?","status":"running","steps":[{"elapsed_seconds":40,"message_count":2,"role_id":"software_engineer","role_kind":"producing","status":"needsSupervisorInput","tool_call_count":3},{"elapsed_seconds":38,"message_count":2,"role_id":"qa_engineer","role_kind":"producing","status":"needsSupervisorInput","tool_call_count":2}],"task_id":6,"timed_out":false,"title":"Migrate database schema"},"ok":true}"#
            case .after:
                listEnvelope = #"{"data":{"tasks":[{"chat_mode":false,"id":6,"pending_question_count":2,"status":"running","title":"Migrate database schema","updated_seconds_ago":12,"waiting_for_supervisor":true}]},"ok":true}"#
                statusEnvelope = #"{"data":{"artifacts":[],"chat_mode":false,"elapsed_seconds":40,"pending_question":"Should the migration keep the legacy v1 table as a backup?","pending_questions":[{"question":"Should the migration keep the legacy v1 table as a backup?","role_id":"software_engineer"},{"question":"Which SQLite fixtures should the migration test suite run against?","role_id":"qa_engineer"}],"status":"running","steps":[{"elapsed_seconds":40,"message_count":2,"role_id":"software_engineer","role_kind":"producing","status":"needsSupervisorInput","tool_call_count":3},{"elapsed_seconds":38,"message_count":2,"role_id":"qa_engineer","role_kind":"producing","status":"needsSupervisorInput","tool_call_count":2}],"task_id":6,"timed_out":false,"title":"Migrate database schema"},"ok":true}"#
            }
            let call2ID = "call_status_2"
            let statusArgs = #"{"task_id":6}"#
            let call3ID = "call_answer_3"
            let targetArgs = #"{"answer":"Yes, keep the legacy v1 table as a read-only backup until v2 is verified.","task_id":6}"#
            let answerEnvelope = #"{"data":{"message":"Answered task #6.","status":"ok"},"ok":true}"#
            let turns: [ChatMessage] = [
                ChatMessage(role: .assistant, toolCalls: [
                    ChatToolCall(id: call1ID, name: ToolNames.listTasks, argumentsJSON: "{}")
                ]),
                ChatMessage(role: .tool, content: listEnvelope, toolCallID: call1ID),
                ChatMessage(role: .assistant, toolCalls: [
                    ChatToolCall(id: call2ID, name: ToolNames.taskStatus, argumentsJSON: statusArgs)
                ]),
                ChatMessage(role: .tool, content: statusEnvelope, toolCallID: call2ID),
                ChatMessage(role: .assistant, toolCalls: [
                    ChatToolCall(id: call3ID, name: ToolNames.answerTaskQuestion, argumentsJSON: targetArgs)
                ]),
                ChatMessage(role: .tool, content: answerEnvelope, toolCallID: call3ID),
            ]
            return (turns, ToolNames.answerTaskQuestion, targetArgs, listEnvelope + "\n" + statusEnvelope)

        case .delegationChildPausedTimeout:
            return ([], "", "", "")
        }
    }

    /// `task_status` on the target task, then `message_task` to it — both answered with the bytes
    /// production renders for the scenario's state; only the `message_task` answer differs by arm.
    private static func messageScenarioTurns(
        scenario: AutovisorContinuationScenario,
        arm: AutovisorContinuationArm,
        statusArgs: String,
        targetArgs: String
    ) async throws -> (messages: [ChatMessage], targetToolName: String, targetArgs: String, injectedEnvelope: String) {
        guard let statusEnvelope = messageScenarioTaskStatusEnvelope(scenario: scenario) else {
            throw AutovisorContinuationFixtureError.notAMessageTaskScenario(scenario)
        }
        let injected = try await messageTaskEnvelope(scenario: scenario, arm: arm, argumentsJSON: targetArgs)
        let statusCallID = "call_status_1"
        let messageCallID = "call_msg_2"
        let turns: [ChatMessage] = [
            ChatMessage(role: .assistant, toolCalls: [
                ChatToolCall(id: statusCallID, name: ToolNames.taskStatus, argumentsJSON: statusArgs)
            ]),
            ChatMessage(role: .tool, content: statusEnvelope, toolCallID: statusCallID),
            ChatMessage(role: .assistant, toolCalls: [
                ChatToolCall(id: messageCallID, name: ToolNames.messageTask, argumentsJSON: targetArgs)
            ]),
            ChatMessage(role: .tool, content: injected, toolCallID: messageCallID),
        ]
        return (turns, ToolNames.messageTask, targetArgs, injected)
    }

    private static func buildDelegationFixture(
        arm: AutovisorContinuationArm,
        toolCallingMode: ToolCallingMode
    ) -> AutovisorContinuationPromptFixture {
        let codingAgentTeam = TeamTemplateFactory.codingAgent()
        let engineeringTeam = TeamTemplateFactory.engineering()
        let startupTeam = TeamTemplateFactory.startup()
        let teams = [codingAgentTeam, engineeringTeam, startupTeam]

        let roleDef = codingAgentTeam.roles.first(where: { $0.systemRoleID == Role.codingAgent.baseID })!
        let role = Role.fromDefinition(roleDef)
        let step = StepExecution.make(for: roleDef)
        let run = Run(id: 0, steps: [step], teamID: codingAgentTeam.id)
        let task = NTMSTask(
            id: 10,
            title: "Auth Token Refresh",
            supervisorTask: "Delegate the authentication token refresh pipeline implementation to the Engineering Team and oversee it to completion.",
            runs: [run],
            preferredTeamID: codingAgentTeam.id
        )

        let projection = WorkFolderProjection(
            state: WorkFolderState(name: "TrainerProject"),
            settings: ProjectSettings(),
            teams: teams
        )
        let rawSchemas = LLMExecutionService.resolveToolSchemas(
            for: role,
            team: codingAgentTeam,
            allTeams: teams,
            selectedScheme: nil,
            isVisionConfigured: false,
            approval: ToolApprovalAvailability(
                bashMode: .off,
                computerUseMode: .off,
                humanPresent: true
            ),
            autovisorTeamPolicy: AutovisorTeamPolicy(settings: projection.settings)
        )
        let toolSchemas = LLMExecutionService.filterForDefaultStorage(rawSchemas, isDefaultStorage: false)

        let context = PromptBuilder.Context(
            task: task,
            step: step,
            stepIndex: 0,
            run: run,
            workFolder: projection,
            artifactReader: { _ in nil },
            activeTeam: codingAgentTeam,
            roleDefinition: roleDef,
            globalContext: AppDefaults.globalContext,
            agentInstructions: nil,
            attachedSkills: [],
            toolCallingMode: toolCallingMode
        )
        var messages = PromptBuilder.buildChatMessages(context: context, tools: toolSchemas)
        let systemPromptChars = messages.first(where: { $0.role == MessageRole.system })?.content?.count ?? 0

        let callID = "call_delegate_1"
        let targetArgs = #"{"task_brief":"Implement the authentication token refresh pipeline with retry backoff and unit tests.","team_id":"engineering_team"}"#
        let injected = LLMExecutionService.renderChildPausedEnvelope(
            childTID: 7,
            targetTeamName: "Engineering Team",
            reason: .runTimedOut(seconds: 0)
        )

        messages.append(ChatMessage(role: .assistant, toolCalls: [
            ChatToolCall(id: callID, name: ToolNames.delegateToTeam, argumentsJSON: targetArgs)
        ]))
        messages.append(ChatMessage(role: .tool, content: injected, toolCallID: callID))

        return AutovisorContinuationPromptFixture(
            scenario: .delegationChildPausedTimeout,
            arm: arm,
            roleID: roleDef.id,
            roleName: roleDef.name,
            systemPromptChars: systemPromptChars,
            messages: messages,
            tools: toolSchemas,
            targetToolName: ToolNames.delegateToTeam,
            targetArgumentsJSON: targetArgs,
            injectedEnvelope: injected
        )
    }

    // MARK: - Classification

    static func classify(
        scenario: AutovisorContinuationScenario,
        arm: AutovisorContinuationArm,
        content: String,
        nativeCalls: [StepToolCall],
        advertisedTools: [ToolSchema],
        targetToolName: String,
        targetArgumentsJSON: String
    ) -> (
        toolNames: [String],
        firstArgumentsJSON: String?,
        repeatedSameAction: Bool,
        askedSupervisor: Bool,
        wentIdle: Bool,
        verdict: OneShotPromptVerdict
    ) {
        let resolution = FinishedReplyToolCallResolver.resolve(
            content: content,
            nativeCalls: nativeCalls,
            advertised: advertisedTools
        )
        let canonicalCalls = resolution.toolCalls.map { call -> StepToolCall in
            var copy = call
            copy.name = ToolRegistry.resolveToolName(call.name)
            return copy
        }
        let toolNames = canonicalCalls.map(\.name)
        let firstArgs = canonicalCalls.first?.argumentsJSON
        let repeatedSameAction = isRepeatedAction(
            scenario: scenario,
            firstCall: canonicalCalls.first,
            targetToolName: targetToolName,
            targetArgumentsJSON: targetArgumentsJSON
        )
        let askedSupervisor = toolNames.contains(where: { ToolNames.supervisorAskTools.contains($0) })
            || (toolNames.isEmpty && resolution.content.contains("?"))
        let wentIdle = toolNames.contains(ToolNames.waitForEvents)

        let verdict = evaluateVerdict(
            scenario: scenario,
            arm: arm,
            calls: canonicalCalls,
            repeatedSameAction: repeatedSameAction,
            askedSupervisor: askedSupervisor,
            wentIdle: wentIdle
        )
        return (toolNames, firstArgs, repeatedSameAction, askedSupervisor, wentIdle, verdict)
    }

    private static func isRepeatedAction(
        scenario: AutovisorContinuationScenario,
        firstCall: StepToolCall?,
        targetToolName: String,
        targetArgumentsJSON: String
    ) -> Bool {
        guard let firstCall, firstCall.name == targetToolName else { return false }
        let firstDict = parseJSONObject(firstCall.argumentsJSON)
        let targetDict = parseJSONObject(targetArgumentsJSON)

        switch scenario {
        case .pauseNoEngine, .repeatedClose:
            return (firstDict?["task_id"] as? Int) == (targetDict?["task_id"] as? Int)
                && (firstDict?["action"] as? String) == (targetDict?["action"] as? String)
        case .messageTaskInReview, .messageTaskOnPaused:
            return (firstDict?["task_id"] as? Int) == (targetDict?["task_id"] as? Int)
        case .rosterTwoQuestions:
            // Answering the SAME question verbatim is a repeat; answering the second question is not.
            return (firstDict?["task_id"] as? Int) == (targetDict?["task_id"] as? Int)
                && (firstDict?["answer"] as? String) == (targetDict?["answer"] as? String)
        case .delegationChildPausedTimeout:
            // Calling delegate_to_team again when a child is already paused on the step is a repeat.
            return true
        }
    }

    private static func evaluateVerdict(
        scenario: AutovisorContinuationScenario,
        arm _: AutovisorContinuationArm,
        calls: [StepToolCall],
        repeatedSameAction: Bool,
        askedSupervisor: Bool,
        wentIdle: Bool
    ) -> OneShotPromptVerdict {
        if repeatedSameAction {
            return OneShotPromptVerdict(
                passed: false,
                note: "repeated same \(calls.first?.name ?? "tool") action"
            )
        }
        guard let first = calls.first else {
            return OneShotPromptVerdict(
                passed: false,
                note: askedSupervisor ? "no tool call (plain-text question)" : "no tool call"
            )
        }

        let args = parseJSONObject(first.argumentsJSON)
        switch scenario {
        case .pauseNoEngine:
            // After learning #2 is already paused (or after pause), manager should proceed with
            // manage_role(correct) or task_status/wait_for_events without re-pausing.
            let valid: Set<String> = [
                ToolNames.manageRole,
                ToolNames.taskStatus,
                ToolNames.waitForEvents,
                ToolNames.listTasks,
            ]
            let passed = valid.contains(first.name)
            return OneShotPromptVerdict(
                passed: passed,
                note: passed ? "proceeded with \(first.name)" : "unexpected tool \(first.name)"
            )

        case .repeatedClose:
            let valid: Set<String> = [
                ToolNames.waitForEvents,
                ToolNames.listTasks,
                ToolNames.taskStatus,
            ]
            let passed = valid.contains(first.name)
            return OneShotPromptVerdict(
                passed: passed,
                note: passed ? "moved on with \(first.name)" : "unexpected tool \(first.name)"
            )

        case .messageTaskInReview:
            // A task in Review cannot accept queued chat messages: the manager must use
            // manage_role (request_changes / accept) or control_task (close). Going idle via
            // wait_for_events means the model believed the message was queued for an active run.
            if wentIdle {
                return OneShotPromptVerdict(
                    passed: false,
                    note: "parked at wait_for_events assuming message queued on Review task"
                )
            }
            let valid: Set<String> = [ToolNames.manageRole, ToolNames.controlTask, ToolNames.taskStatus]
            let passed = valid.contains(first.name)
            return OneShotPromptVerdict(
                passed: passed,
                note: passed ? "handled Review task via \(first.name)" : "unexpected tool \(first.name)"
            )

        case .messageTaskOnPaused:
            // Messaging a paused task resumes its existing run; a follow-up control_task
            // resume/start is redundant and shows the reply hid the auto-resume.
            if first.name == ToolNames.controlTask,
               let action = args?["action"] as? String,
               action == "resume" || action == "start"
            {
                return OneShotPromptVerdict(
                    passed: false,
                    note: "redundant control_task \(action) after message_task on paused task"
                )
            }
            let valid: Set<String> = [ToolNames.waitForEvents, ToolNames.taskStatus, ToolNames.listTasks]
            let passed = valid.contains(first.name)
            return OneShotPromptVerdict(
                passed: passed,
                note: passed ? "continued cleanly with \(first.name)" : "unexpected tool \(first.name)"
            )

        case .rosterTwoQuestions:
            // Task #6 had TWO roles waiting on ask_supervisor, and only one was answered so far.
            // Going idle via wait_for_events leaves the second question unanswered in this pass.
            if wentIdle {
                return OneShotPromptVerdict(
                    passed: false,
                    note: "went idle via wait_for_events with 2nd question still waiting on task #6"
                )
            }
            let valid: Set<String> = [ToolNames.answerTaskQuestion, ToolNames.taskStatus, ToolNames.listTasks]
            let passed = valid.contains(first.name)
            return OneShotPromptVerdict(
                passed: passed,
                note: passed ? "addressed remaining question via \(first.name)" : "unexpected tool \(first.name)"
            )

        case .delegationChildPausedTimeout:
            let valid: Set<String> = [
                ToolNames.resumeDelegation,
                ToolNames.forwardToTeam,
                ToolNames.cancelDelegation,
                ToolNames.askSupervisor,
                ToolNames.askSupervisorForm,
            ]
            let passed = valid.contains(first.name)
            return OneShotPromptVerdict(
                passed: passed,
                note: passed ? "handled child pause via \(first.name)" : "unexpected tool \(first.name)"
            )
        }
    }

    private static func parseJSONObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return dict
    }

    // MARK: - Plumbing

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @MainActor @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func write(_ result: AutovisorContinuationTrainerRunResult) throws {
        let encoder = JSONCoderFactory.makeExportEncoder()
        let data = try encoder.encode(result)
        try data.write(to: URL(fileURLWithPath: config.outputPath), options: .atomic)
        print("[TRAINER] Results written to \(config.outputPath)")
    }
}
