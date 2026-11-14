import Foundation

/// Every model-facing text the app composes at RUNTIME — outside the bundled templates,
/// role prompts and tool schemas that `BundledContentFingerprint` covers — rendered with
/// fixed sample inputs so the bytes are a function of the code alone.
///
/// Two consumers: `RuntimePromptFingerprint` folds the renderings into the
/// `runtimePromptVersion` field of every provenance record, and
/// `PromptFormatConventionsTests` sweeps every entry with the format invariants (no
/// ALL-CAPS labels, no bold, one marker family, no "please"). Until 2026-09-07 the
/// nudges, the Harmony preamble, the error-note policy and the eight one-shot prompts had
/// no version at all: two headless runs of one bundle with different nudge text recorded
/// identical provenance (`git diff --stat bbf1f853..HEAD -- +StepFlowControl` was +130/−4
/// under an unchanged `ad6c4b67d375d0ca`; playbook REC.9 / R4.6.2).
///
/// An entry is a NAME and a renderer. A renderer takes no arguments: where the text is a
/// function of runtime values it renders a fixed sample (`read_file` as the allowed tool,
/// turn 2 of 6, one missing deliverable…), which is enough for the fingerprint to move
/// when the WORDING moves and to stay when only the sample would. Adding a model-facing
/// composer means adding a row here; `PromptFormatConventionsTests` scans the tree for
/// one-shot system prompts it does not know.
///
/// Main-actor by the app default: the composers are main-actor code. The value crosses to
/// the logger's stream task once, through `RuntimePromptFingerprint.prime()`.
enum RuntimePromptRegistry {

    /// Who reads a registered runtime text: the in-app local model (`.localModel`) or an
    /// external MCP agent driving the folder (`.externalAgent`). Keeping the two audiences
    /// apart on the same registry lets `RuntimePromptCensusPinTests` enforce registration
    /// across the whole tree while `RuntimePromptFingerprint.current` (provenance for local
    /// model runs) and `PromptFormatConventionsTests` (local-model house style) filter to
    /// `.localModel`.
    nonisolated enum Audience: String, Sendable, Hashable, CaseIterable {
        case localModel
        case externalAgent
    }

    /// `nonisolated` so the rows can be built from a nested helper; the renderer itself
    /// is main-actor code, which the closure type says.
    nonisolated struct Entry {
        let name: String
        let audience: Audience
        let render: @MainActor () -> String

        init(
            name: String,
            audience: Audience = .localModel,
            render: @escaping @MainActor () -> String
        ) {
            self.name = name
            self.audience = audience
            self.render = render
        }
    }

    /// A one-shot service's system prompt: `file` is the source the census scan matches,
    /// `label` the entry name.
    nonisolated struct OneShotPrompt {
        let file: String
        let label: String
        let render: @MainActor () -> String
    }

    // MARK: - Samples

    private static let sampleTools: Set<String> = [ToolNames.readFile, ToolNames.createArtifact, ToolNames.askSupervisor]
    private static let sampleArtifacts = ["Engineering Notes"]
    /// One of each kind, so the sample renders every hint and the recommendation tag.
    ///
    /// The `recommendedOptionID` is load-bearing here, not decoration: `recommendedTag` is
    /// model-facing wire text, and it appears in the rendered questionnaire ONLY for a question
    /// that carries a recommendation. A sample recommending nothing — which is what this was
    /// between 2026-09-12 and 2026-09-13, when the tag stopped being `options[0]` — leaves that
    /// text covered by no registry row at all, so an edit to it would ship without moving
    /// `RuntimePromptFingerprint` or the provenance line.
    private static let sampleInquiry = SupervisorInquiry(
        headline: "Which build settings should I use?",
        questions: [
            SupervisorInquiryQuestion(
                id: "scheme", prompt: "Which scheme should I build?", kind: .singleChoice,
                options: [
                    SupervisorInquiryOption(id: "debug", label: "Debug", detail: "what CI uses"),
                    SupervisorInquiryOption(id: "release", label: "Release"),
                ],
                recommendedOptionID: "debug"),
            SupervisorInquiryQuestion(
                id: "targets", prompt: "Which targets should I run?", kind: .multiChoice,
                options: [
                    SupervisorInquiryOption(id: "unit", label: "Unit"),
                    SupervisorInquiryOption(id: "ui", label: "UI"),
                ]),
            SupervisorInquiryQuestion(
                id: "notes", prompt: "Anything else I should know?", kind: .freeText),
        ])
    private static let sampleSchema = ToolSchema(
        name: "sample_tool",
        description: "A sample tool.",
        parameters: JSONSchema(type: "object", properties: ["path": JSONSchema.string("A path.")], required: ["path"]))
    /// One external tool, so the marker and the second boundary both render. The slug is
    /// short and the description plain: what the row pins is this app's own two texts, not
    /// a server's.
    private static let sampleMCPSchema = ToolSchema(
        name: "mcp__design__get_metadata",
        description: "Reads a node's metadata.",
        parameters: JSONSchema(type: "object", properties: ["node": JSONSchema.string("A node id.")], required: ["node"]))
    private static let sampleRole = TeamRoleDefinition(
        id: "swe", name: "Software Engineer", prompt: "", toolIDs: [], usePlanningPhase: false,
        dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: sampleArtifacts))

    /// One sample per `AutovisorReply` case — the builder of every text the Autovisor's manager
    /// is told about its own actions and its folder. A case with no sample here would ship its
    /// wording under a fingerprint that never covered it; `AutovisorReplyTests` checks that every
    /// case is sampled. The optional-reason cases are sampled both ways, since the fallback
    /// wording is the builder's own.
    static let autovisorReplySamples: [(name: String, reply: AutovisorReply)] = {
        let triggers = NTMSOrchestrator.AutovisorAttentionTrigger.allCases
        let items = triggers.map { NTMSOrchestrator.AutovisorAttentionItem(taskID: 3, title: "Fix login", trigger: $0) }
        var rows: [(name: String, reply: AutovisorReply)] = []
        rows.append(("drivenByExternalAgent", .drivenByExternalAgent))
        rows.append(("ownTask", .ownTask(taskID: 1)))
        rows.append(("taskNotFound", .taskNotFound(taskID: 9)))
        rows.append(("tooManyRunning", .tooManyRunning(count: 3)))
        rows.append(("creationLimitReached", .creationLimitReached(limit: 2)))
        rows.append(("openTaskLimitReached", .openTaskLimitReached(count: 3, limit: 3)))
        rows.append(("creationWindowLimitReached", .creationWindowLimitReached(limit: 5, windowMinutes: 15)))
        rows.append(("creationFailed", .creationFailed))
        rows.append(("createdNotStarted", .createdNotStarted(taskID: 3, title: "Fix login", reason: nil)))
        rows.append(("createdNotStarted/reason", .createdNotStarted(taskID: 3, title: "Fix login", reason: "The model is not loaded.")))
        rows.append(("createdAndStarted", .createdAndStarted(taskID: 3, title: "Fix login")))
        rows.append(("createdScheduled", .createdScheduled(taskID: 3, title: "Fix login", runAt: Date(timeIntervalSince1970: 1700000000))))
        rows.append(("notWaitingForInput", .notWaitingForInput(taskID: 3)))
        rows.append(("notWaitingForInputExternal", .notWaitingForInputExternal(taskID: 3)))
        rows.append(("roleNotWaiting", .roleNotWaiting(taskID: 3, roleID: "qa", waitingRoleIDs: ["swe"])))
        rows.append(("roleNotWaiting/none", .roleNotWaiting(taskID: 3, roleID: "qa", waitingRoleIDs: [])))
        rows.append(("answered", .answered(taskID: 3)))
        rows.append(("answeredWhilePausedInTheApp", .answeredWhilePausedInTheApp(taskID: 3)))
        rows.append(("answerNotDelivered", .answerNotDelivered(taskID: 3)))
        rows.append(("messageNotQueued", .messageNotQueued(taskID: 3)))
        rows.append(("messageDiscardedTaskFinished", .messageDiscardedTaskFinished(taskID: 3)))
        rows.append(("messageQueued", .messageQueued(taskID: 3)))
        rows.append(("messageQueuedAndResumed", .messageQueuedAndResumed(taskID: 3)))
        rows.append(("messageQueuedWhilePausedInTheApp", .messageQueuedWhilePausedInTheApp(taskID: 3)))
        rows.append(("decisionWaitsForThePersonsResume", .decisionWaitsForThePersonsResume(taskID: 3)))
        rows.append(("scheduleNotCleared", .scheduleNotCleared(taskID: 3)))
        rows.append(("scheduleCleared", .scheduleCleared(taskID: 3)))
        rows.append(("scheduleNotStored", .scheduleNotStored(taskID: 3)))
        rows.append(("scheduled", .scheduled(taskID: 3, minutes: 30)))
        rows.append(("workFolderContextUpdated", .workFolderContextUpdated))
        rows.append(("workFolderContextChangedSinceRead", .workFolderContextChangedSinceRead))
        rows.append(("alreadyRunning", .alreadyRunning(taskID: 3)))
        rows.append(("started", .started(taskID: 3)))
        rows.append(("couldNotStart", .couldNotStart(taskID: 3)))
        rows.append(("paused", .paused(taskID: 3)))
        for reason in AutovisorReply.PauseFailureReason.allCases {
            rows.append(("couldNotPause/\(reason)", .couldNotPause(taskID: 3, reason: reason.rawValue)))
        }
        rows.append(("closedNotResumable", .closedNotResumable(taskID: 3)))
        rows.append(("noRunToResume", .noRunToResume(taskID: 3)))
        rows.append(("pausedByThePerson", .pausedByThePerson(taskID: 3)))
        rows.append(("resumed", .resumed(taskID: 3)))
        rows.append(("stopped", .stopped(taskID: 3)))
        rows.append(("closed", .closed(taskID: 3)))
        rows.append(("closeFailed", .closeFailed(taskID: 3)))
        rows.append(("deleted", .deleted(taskID: 3)))
        rows.append(("renamed", .renamed(taskID: 3, title: "Fix login")))
        rows.append(("timeoutCleared", .timeoutCleared(taskID: 3)))
        rows.append(("timeoutSet", .timeoutSet(taskID: 3)))
        rows.append(("noSuchRole", .noSuchRole(taskID: 3, roleID: "swe")))
        rows.append(("generationIsNotARole", .generationIsNotARole(roleID: "team_generation_1", verb: "accept")))
        rows.append(("restartWouldDiscard", .restartWouldDiscard(taskID: 3, roleID: "swe", toolCalls: 4)))
        rows.append(("restartWouldOrphanChild", .restartWouldOrphanChild(taskID: 3, roleID: "swe", childTaskID: 7)))
        rows.append(("restarted", .restarted(taskID: 3, roleID: "swe")))
        rows.append(("changesRequested", .changesRequested(taskID: 3, roleID: "swe")))
        rows.append(("correctNeedsPause", .correctNeedsPause(taskID: 3)))
        rows.append(("corrected", .corrected(taskID: 3, roleID: "swe")))
        rows.append(("alreadyClosed", .alreadyClosed(taskID: 3)))
        rows.append(("finishAdvisoryOnProducingRole", .finishAdvisoryOnProducingRole(taskID: 3, roleID: "swe")))
        rows.append(("noActiveRun", .noActiveRun(taskID: 3)))
        rows.append(("accepted", .accepted(taskID: 3, roleID: "swe")))
        rows.append(("acceptFailed", .acceptFailed(roleID: "swe")))
        rows.append(("acceptRejected", .acceptRejected(reason: "Role already completed", remedy: nil)))
        rows.append(("acceptRejected/remedy", .acceptRejected(reason: "Role already completed", remedy: "call task_status")))
        rows.append(("finishFailed", .finishFailed(taskID: 3, roleID: "swe")))
        rows.append(("advisoryFinished", .advisoryFinished(taskID: 3, roleID: "swe")))
        rows.append(("chatRoleFinished", .chatRoleFinished(taskID: 3, roleID: "swe", stillActive: ["Reviewer", "Writer"])))
        rows.append(("chatRoleFinishedAndClosed", .chatRoleFinishedAndClosed(taskID: 3, roleID: "swe")))
        rows.append(("chatRoleFinishedCloseFailed", .chatRoleFinishedCloseFailed(taskID: 3, roleID: "swe", reason: nil)))
        rows.append(("chatRoleFinishedCloseFailed/reason", .chatRoleFinishedCloseFailed(taskID: 3, roleID: "swe", reason: "The disk is full.")))
        rows.append(("noPendingGeneration", .noPendingGeneration(taskID: 3)))
        rows.append(("noLongerLoaded", .noLongerLoaded(taskID: 3)))
        rows.append(("generationRerun", .generationRerun(taskID: 3)))
        rows.append(("generationInProgress", .generationInProgress(taskID: 3)))
        rows.append(("generationFailedAgain", .generationFailedAgain(taskID: 3, reason: nil)))
        rows.append(("generationFailedAgain/reason", .generationFailedAgain(taskID: 3, reason: "The model returned no team.")))
        rows.append(("generationDidNotRestart", .generationDidNotRestart(taskID: 3)))
        rows.append(("eventNotice", .eventNotice(items)))
        return rows
    }()

    // MARK: - One-shot system prompts

    /// The eight one-shot system prompts (R5.1.6 skeleton; the injection-boundary census).
    static let oneShotSystemPrompts: [OneShotPrompt] = {
        var rows: [OneShotPrompt] = []
        rows.append(OneShotPrompt(file: "PromptImprovementService.swift", label: "PromptImprovementService.systemPrompt") {
            PromptImprovementService.systemPrompt
        })
        rows.append(OneShotPrompt(file: "SupervisorAutoAnswerService.swift", label: "SupervisorAutoAnswerService.systemPrompt") {
            SupervisorAutoAnswerService.systemPrompt
        })
        rows.append(OneShotPrompt(file: "BashJudgeService.swift", label: "BashJudgeService.judgeSystemPrompt") {
            BashJudgeService.judgeSystemPrompt(policy: BashPolicy())
        })
        rows.append(OneShotPrompt(file: "ComputerUseJudgeService.swift", label: "ComputerUseJudgeService.systemPrompt") {
            ComputerUseJudgeService.systemPrompt(policy: ComputerUsePolicy())
        })
        rows.append(OneShotPrompt(file: "MCPJudgeService.swift", label: "MCPJudgeService.systemPrompt") {
            MCPJudgeService.systemPrompt(strictness: .standard)
        })
        rows.append(OneShotPrompt(file: "VisionAnalysisService.swift", label: "VisionAnalysisService.systemPrompt") {
            VisionAnalysisService.systemPrompt
        })
        rows.append(OneShotPrompt(file: "BashExplainService.swift", label: "BashExplainService.explainSystemPrompt") {
            BashExplainService.explainSystemPrompt(policy: BashPolicy())
        })
        rows.append(OneShotPrompt(file: "WorkFolderContextService.swift", label: "AppDefaults.workFolderContextPrompt") {
            AppDefaults.workFolderContextPrompt
        })
        rows.append(OneShotPrompt(file: "TeamGenerationService.swift", label: "TeamGenerationService.defaultSystemPrompt") {
            TeamGenerationService.defaultSystemPrompt
        })
        return rows
    }()

    // MARK: - Every entry

    static let entries: [Entry] = {
        var e: [Entry] = []
        func add(
            _ name: String,
            audience: Audience = .localModel,
            _ render: @escaping @MainActor () -> String
        ) {
            e.append(Entry(name: name, audience: audience, render: render))
        }

        for row in oneShotSystemPrompts { add(row.label, row.render) }

        // The Harmony tool-calling body and the tool-less sentence.
        add("NativeLMStudioClient.buildToolSchemaBody/sampleTool") {
            NativeLMStudioClient.buildToolSchemaBody(tools: [sampleSchema])
        }
        // The native chip: the catalog rides the provider's `tools` field, so the body is
        // the one-tool rule and the injection boundary alone (2026-09-13).
        // The MCP gate's two authored refusals. Neither rides a `ToolErrorCode` row above:
        // `MCP_DENIED`'s row renders the POLICY's reason text, and these are the gate's own
        // — the sentence a person's decline produces, and the one a run with nobody to ask
        // produces. The `approval_unavailable` arm composes a policy reason into its
        // sentence, so the sample carries a real one.
        add("LLMExecutionService.gateMCPCalls/declined") {
            let service = LLMExecutionService(repository: NTMSRepository())
            return service.makeMCPDeniedResult(
                call: StepToolCall(name: "mcp__design__get_metadata", argumentsJSON: "{}"),
                reason: "The Supervisor declined this call.").outputJSON
        }
        add("LLMExecutionService.gateMCPCalls/approvalUnavailable") {
            let service = LLMExecutionService(repository: NTMSRepository())
            return service.makeApprovalUnavailableResult(
                call: StepToolCall(name: "mcp__design__get_metadata", argumentsJSON: "{}"),
                reason: LLMExecutionService.mcpNoApproverMessage(
                    reason: MCPPermissionService.reasonForAsking(.writesStated))
            ).outputJSON
        }
        // The policy's reasons that sentence composes in — step 1's, and every arm of the
        // nearest-miss ladder. Until 2026-10-28 none was a row: the sample above spelled one
        // arm out as a literal, so an edit to any reason moved nothing.
        add("MCPPermissionService.manualModeReason") { MCPPermissionService.manualModeReason }
        add("MCPPermissionService.crossServerTransferReason") {
            MCPPermissionService.crossServerTransferReason(from: ["Folio Desktop"], to: "GitHub")
        }
        for reason in MCPPermissionService.AskReason.allCases {
            add("MCPPermissionService.reasonForAsking/\(reason)") { MCPPermissionService.reasonForAsking(reason) }
        }
        // The two texts an MCP tool adds: the `(MCP server <slug>)` marker on its own line,
        // and the second injection boundary — which renders ONLY when a call carries one, so
        // a sample without it leaves both covered by no row at all.
        add("NativeLMStudioClient.buildToolSchemaBody/mcpTool") {
            NativeLMStudioClient.buildToolSchemaBody(tools: [sampleSchema, sampleMCPSchema])
        }
        add("NativeLMStudioClient.buildToolSchemaBody/mcpToolNative") {
            NativeLMStudioClient.buildToolSchemaBody(
                tools: [sampleSchema, sampleMCPSchema], mode: .native)
        }
        add("NativeLMStudioClient.buildToolSchemaBody/native") {
            NativeLMStudioClient.buildToolSchemaBody(tools: [sampleSchema], mode: .native)
        }
        add("PromptBuilder.formatToolCallingBlock/noTools") { PromptBuilder.formatToolCallingBlock(tools: []) }
        add("HarmonyToolCallEnvelope.text") {
            HarmonyToolCallEnvelope.text(name: "sample_tool", argumentsJSON: "{\"path\":\"a.txt\"}")
        }

        // Builder-injected sections and chips.
        add("PromptBuilder.formatGlobalContext") { PromptBuilder.formatGlobalContext("Sample guidance.") }
        add("PromptBuilder.buildConversationMechanicsGuidance/tagTools") {
            PromptBuilder.buildConversationMechanicsGuidance(hasTagProducingTools: true)
        }
        add("PromptBuilder.buildConversationMechanicsGuidance/noTagTools") {
            PromptBuilder.buildConversationMechanicsGuidance(hasTagProducingTools: false)
        }
        // What a questionnaire answer carries beyond the Supervisor's own words: which
        // questions got no decision, and what the asking role does about them. Nothing is
        // filled in for a skipped question since 2026-09-12, so the second row is the whole
        // replacement for the assumption the first one used to report.
        add("SupervisorInquiryRenderer.unansweredMarker") {
            SupervisorInquiryRenderer.unansweredMarker
        }
        add("SupervisorInquiryRenderer.unansweredDirection") {
            SupervisorInquiryRenderer.unansweredDirection
        }
        // The last thing an automated answerer reads before it replies. Marked and
        // registered because it SHAPES the reply: the questionnaire tail names what to do
        // when information is missing, and until 2026-09-12 that rung could be skipped
        // because an omission was filled in from the recommendation.
        add("SupervisorAutoAnswerService.answerTail") { SupervisorAutoAnswerService.answerTail }
        add("SupervisorAutoAnswerService.questionnaireTail") {
            SupervisorAutoAnswerService.questionnaireTail
        }
        // The questionnaire as an AUTOMATED answerer sees it, contract included. It reaches
        // three different seams — a tool result, a question turn and a user turn — and is one
        // string so that a change to how a form is asked moves one fingerprint, once.
        add("SupervisorInquiryReply.questionnaire") {
            SupervisorInquiryReply.questionnaire(for: sampleInquiry)
        }
        // The Supervisor asking a parked role to re-ask its plain question as a form. It rides
        // the tool result of that role's own `ask_supervisor`, which is the only channel a
        // parked step has — so its first sentence has to say the question was not answered.
        add("SupervisorQuestionnaireRequest.directive") {
            SupervisorQuestionnaireRequest.directive
        }
        add("PromptBuilder.replayedAskSupervisorEnvelope") {
            PromptBuilder.replayedAskSupervisorEnvelope(question: "Which framework?")
        }
        add("PromptBuilder.truncatedOutsideFences/marker") {
            PromptBuilder.truncatedOutsideFences("sample line\nanother line", maxChars: 1)
        }
        for producing in [true, false] {
            for canAsk in [true, false] {
                add("SystemTemplates.stepEnding/producing=\(producing),ask=\(canAsk)") {
                    SystemTemplates.stepEnding(producing: producing, canAskSupervisor: canAsk)
                }
            }
        }
        add("SystemTemplates.meetingStance") {
            SystemTemplates.meetingStance(derivedFrom: "Own the sample deliverable. Keep it short.")
        }
        add("AppDefaults.globalContext") { AppDefaults.globalContext }

        // Nudges and loop recovery — the texts that ride every LATER call of a step.
        add("LLMExecutionService.noToolCallNudge") {
            LLMExecutionService.noToolCallNudge(allowedToolNames: sampleTools, questionnaire: false)
        }
        add("LLMExecutionService.repetitiveNonToolNudge") {
            LLMExecutionService.repetitiveNonToolNudge(
                count: 2, allowedToolNames: sampleTools, questionnaire: false)
        }
        // The arms `sampleTools` never renders: the manager's idle park and a role holding
        // neither channel. Until 2026-09-11 only the `ask_supervisor` arm rode the
        // fingerprint, so a rewrite of either sibling would have shipped under a
        // `runtimePromptVersion` that said nothing moved (REC.9) — the 2026-09-08 lesson, one
        // builder down.
        add("LLMExecutionService.noToolCallNudge/waitForEvents") {
            LLMExecutionService.noToolCallNudge(
                allowedToolNames: [ToolNames.waitForEvents], questionnaire: false)
        }
        add("LLMExecutionService.noToolCallNudge/none") {
            LLMExecutionService.noToolCallNudge(
                allowedToolNames: [ToolNames.readFile], questionnaire: false)
        }
        add("LLMExecutionService.repetitiveNonToolNudge/askSupervisor") {
            LLMExecutionService.repetitiveNonToolNudge(
                count: 2, allowedToolNames: [ToolNames.askSupervisor], questionnaire: false)
        }
        add("LLMExecutionService.repetitiveNonToolNudge/waitForEvents") {
            LLMExecutionService.repetitiveNonToolNudge(
                count: 2, allowedToolNames: [ToolNames.waitForEvents], questionnaire: false)
        }
        // The form arms (2026-09-11): the turn's text carried the questionnaire's shape and
        // the role holds `ask_supervisor_form`. Rendered here because `sampleTools` holds
        // neither the form nor a questionnaire, so no other row reaches this text.
        add("LLMExecutionService.noToolCallNudge/askSupervisorForm") {
            LLMExecutionService.noToolCallNudge(
                allowedToolNames: [ToolNames.askSupervisor, ToolNames.askSupervisorForm],
                questionnaire: true)
        }
        add("LLMExecutionService.repetitiveNonToolNudge/askSupervisorForm") {
            LLMExecutionService.repetitiveNonToolNudge(
                count: 2,
                allowedToolNames: [ToolNames.askSupervisor, ToolNames.askSupervisorForm],
                questionnaire: true)
        }
        add("LLMExecutionService.repetitiveNonToolNudge/none") {
            LLMExecutionService.repetitiveNonToolNudge(
                count: 2, allowedToolNames: [ToolNames.readFile], questionnaire: false)
        }
        add("LLMExecutionService.missingArtifactsNudge") { LLMExecutionService.missingArtifactsNudge(missing: sampleArtifacts) }
        add("LLMExecutionService.escalationClause") {
            LLMExecutionService.escalationClause(code: nil, tool: ToolNames.readFile, allowedToolNames: sampleTools)
        }
        add("LLMExecutionService.escalationClause/approvalUnavailable") {
            LLMExecutionService.escalationClause(
                code: ToolErrorCode.approvalUnavailable.rawValue, tool: ToolNames.bash, allowedToolNames: sampleTools)
        }
        // `sampleTools` is non-empty and holds `ask_supervisor`, so the two composers that
        // answer `nil` for other inputs answer here — unwrapped, not defaulted: a nil would be
        // a composer change, and `RuntimePromptFingerprintPinTests` renders every entry.
        add("LLMExecutionService.toolNameExamples") {
            LLMExecutionService.toolNameExamples(allowedToolNames: sampleTools)!
        }
        // Every text `handleNoToolCalls` appends after a no-tool turn, plus its five cap
        // escalations. They were inline literals until 2026-09-08, so their bytes shipped
        // under a `runtimePromptVersion` that said nothing had moved — measured that day, when
        // seven of them were rewritten and this fingerprint did not budge (REC.9). The census
        // is enforced by `Ratchet/RuntimePromptCensusPinTests`, not by this list's length.
        add("NoToolTurnNudges.reasoningChannel") {
            NoToolTurnNudges.reasoningChannel(
                namedCalls: [ToolNames.readFile], allowedToolNames: sampleTools)
        }
        add("NoToolTurnNudges.reasoningChannel/unnamed") {
            NoToolTurnNudges.reasoningChannel(namedCalls: [], allowedToolNames: sampleTools)
        }
        add("NoToolTurnNudges.thinkingDrift") {
            NoToolTurnNudges.thinkingDrift(thousandsOfCharacters: 12)
        }
        add("NoToolTurnNudges.missingToolName") {
            NoToolTurnNudges.missingToolName(allowedToolNames: sampleTools)
        }
        add("NoToolTurnNudges.toolNameInsideArguments") {
            NoToolTurnNudges.toolNameInsideArguments(allowedToolNames: sampleTools)
        }
        add("NoToolTurnNudges.malformedJSON") {
            NoToolTurnNudges.malformedJSON(
                defect: "parser error: unescaped control character", allowedToolNames: sampleTools)
        }
        add("NoToolTurnNudges.noCallEnvelope") {
            NoToolTurnNudges.noCallEnvelope(allowedToolNames: sampleTools)
        }
        add("NoToolTurnNudges.tokensOnly") { NoToolTurnNudges.tokensOnly() }
        add("NoToolTurnNudges.planningSalvage") {
            NoToolTurnNudges.planningSalvage(allowedToolNames: sampleTools)
        }
        // The native arms (2026-09-13): no envelope to illustrate, a tool to name.
        add("NoToolTurnNudges.planningSalvage/native") {
            NoToolTurnNudges.planningSalvage(allowedToolNames: sampleTools, mode: .native)
        }
        add("NoToolTurnNudges.reasoningChannel/native") {
            NoToolTurnNudges.reasoningChannel(
                namedCalls: [ToolNames.readFile], allowedToolNames: sampleTools, mode: .native)
        }
        add("NoToolTurnNudges.nativeCallRejected") {
            NoToolTurnNudges.nativeCallRejected(
                reason: "tool call does not match the expected peg-native format",
                allowedToolNames: sampleTools)
        }
        add("NoToolTurnNudges.outputTruncated") {
            NoToolTurnNudges.outputTruncated(allowedToolNames: sampleTools, mode: .promptTaught)
        }
        add("NoToolTurnNudges.outputTruncated/native") {
            NoToolTurnNudges.outputTruncated(allowedToolNames: sampleTools, mode: .native)
        }
        add("NoToolTurnNudges.planRecorded") { NoToolTurnNudges.planRecorded() }
        add("NoToolTurnNudges.unrecognisedSentinel") {
            NoToolTurnNudges.unrecognisedSentinel(
                sentinel: "<|tool_call|", allowedToolNames: sampleTools)
        }
        add("NoToolTurnNudges.revisionArtifacts") {
            NoToolTurnNudges.revisionArtifacts(allowedToolNames: sampleTools)
        }
        add("HarmonyCallExample.envelope") {
            HarmonyCallExample.envelope(preferring: sampleTools)!
        }
        add("LLMExecutionService.callShapeClause") {
            LLMExecutionService.callShapeClause(allowedToolNames: sampleTools)
        }
        add("LLMExecutionService.callShapeClause/native") {
            LLMExecutionService.callShapeClause(allowedToolNames: sampleTools, mode: .native)
        }
        add("LLMExecutionService.reasoningEnvelopeEscalationQuestion") {
            LLMExecutionService.reasoningEnvelopeEscalationQuestion(roleName: "Software Engineer")
        }
        add("LLMExecutionService.driftEscalationQuestion") {
            LLMExecutionService.driftEscalationQuestion(
                roleName: "Software Engineer", thousandsOfCharacters: 12)
        }
        add("LLMExecutionService.refusalLoopEscalationQuestion") {
            LLMExecutionService.refusalLoopEscalationQuestion(
                roleName: "Software Engineer", count: 3)
        }
        add("LLMExecutionService.malformedJSONEscalationQuestion") {
            LLMExecutionService.malformedJSONEscalationQuestion(roleName: "Software Engineer")
        }
        add("LLMExecutionService.unrecognisedSentinelEscalationQuestion") {
            LLMExecutionService.unrecognisedSentinelEscalationQuestion(
                roleName: "Software Engineer", sentinel: "<|tool_call|")
        }
        add("LLMExecutionService.nativeCallRejectedEscalationQuestion") {
            LLMExecutionService.nativeCallRejectedEscalationQuestion(roleName: "Software Engineer")
        }
        add("LLMExecutionService.outputTruncatedEscalationQuestion") {
            LLMExecutionService.outputTruncatedEscalationQuestion(roleName: "Software Engineer")
        }
        add("LLMExecutionService.noToolParkQuestion") {
            LLMExecutionService.noToolParkQuestion(turns: 20)
        }
        add("LLMExecutionService.nonProductiveEscalationQuestion") {
            LLMExecutionService.nonProductiveEscalationQuestion(
                roleName: "Software Engineer", turns: 20)
        }
        // The two notes a REPAIR hands the model on the tool result it rides. Same property
        // as a nudge — model-facing, never retired — and neither was versioned until
        // 2026-09-08 (rule #220: a registry that looks complete and is not).
        // The parse-failure diagnostic's own two literals: they reach the model inside the
        // malformed-JSON nudge as `parser error: …`, so a rewording of either moves the
        // fingerprint. The third return value is Foundation's message about the model's own
        // bytes and cannot be versioned.
        add("ToolCallParsingHelpers.malformedJSONDiagnostic/noObject") {
            ToolCallParsingHelpers.malformedJSONDiagnostic(in: "<|call|>ping<|end|>")!
        }
        // The one defect this layer names in its OWN words instead of forwarding
        // Foundation's, so it is versioned like any other model-facing sentence.
        add("ToolCallParsingHelpers.unterminatedStringDefect") {
            ToolCallParsingHelpers.unterminatedStringDefect(
                in: #"{"name":"ask_supervisor_form","arguments":{"headline":"H","form":"{\"questions\": []}}"#)!
        }
        add("ToolCallParsingHelpers.malformedJSONDiagnostic/unbalanced") {
            ToolCallParsingHelpers.malformedJSONDiagnostic(
                in: #"<|call|>{"name":"write_file","arguments":{"path":"x"#)!
        }
        add("ToolCallParsingHelpers.leadingEmptyObjectsNote") {
            ToolCallParsingHelpers.leadingEmptyObjectsNote(count: 1)!
        }
        add("ToolCallParsingHelpers.spilledArgumentsNote") {
            ToolCallParsingHelpers.spilledArgumentsNote(
                recoveredKeys: ["path", "old_text"])!
        }
        add("ToolCallParsingHelpers.strandedArgumentsNote") {
            ToolCallParsingHelpers.strandedArgumentsNote(keys: ["reasoning", "thought"], tool: ToolNames.readFile)!
        }
        add("ToolCallParsingHelpers.transposedQuoteRepairNote") {
            ToolCallParsingHelpers.transposedQuoteRepairNote
        }
        add("ToolCallParsingHelpers.reorderedClosersRepairNote") {
            ToolCallParsingHelpers.reorderedClosersRepairNote
        }
        // The `ask_supervisor_form` repairs (2026-09-11): what the model is told when its
        // form was READ despite typographic quotes, surplus closers, or markers in labels.
        add("SupervisorFormTextRepair.requotedNote") { SupervisorFormTextRepair.requotedNote(count: 2) }
        add("SupervisorFormTextRepair.droppedClosersNote") { SupervisorFormTextRepair.droppedClosersNote(count: 1) }
        add("SupervisorInquiryLabelRepair.enumerationNote") { SupervisorInquiryLabelRepair.enumerationNote(count: 2) }
        add("SupervisorInquiryLabelRepair.recommendedMarkerNote") { SupervisorInquiryLabelRepair.recommendedMarkerNote(count: 1) }
        add("SupervisorInquiryHeadlineFallback.note") { SupervisorInquiryHeadlineFallback.note }
        add("SupervisorInquiryHeadlineFallback.nestedNote") { SupervisorInquiryHeadlineFallback.nestedNote }
        // The closer rung, and the two sentences a REFUSAL carries (2026-09-11): what was put
        // back, what was already handled and is therefore NOT the fault, and the one
        // completeness rule a tolerant parse cannot answer for itself.
        add("SupervisorFormTextRepair.insertedCloserNote") { SupervisorFormTextRepair.insertedCloserNote }
        add("SupervisorFormTextRepair.closedTheFormNote") { SupervisorFormTextRepair.closedTheFormNote }
        add("SupervisorFormTextRepair.handledNotTheFaultNote") {
            SupervisorFormTextRepair.handledNotTheFaultNote(
                [SupervisorFormTextRepair.requotedNote(count: 2)])
        }
        add("SupervisorInquiryCompleteness.tooFewOptionsNote") {
            SupervisorInquiryCompleteness.tooFewOptionsNote(questionNumber: 2, options: 1)
        }
        // The three states of a form that ran out of text, one row each: their recoveries
        // differ, so one sample would leave two texts riding provenance unversioned.
        add("SupervisorFormDecoding.unfinishedNote/owesMoreThanTheFrame") {
            SupervisorFormDecoding.unfinishedNote(in: #"{"questions":[{"kind":"free_text"}"#)
        }
        add("SupervisorFormDecoding.unfinishedNote/unfinishedValue") {
            SupervisorFormDecoding.unfinishedNote(in: #"{"questions":[{"prompt":"#)
        }
        // The two refusals' standing instructions. Model-facing text composed in a handler is
        // still model-facing text (REC.9): unregistered, an edit to either ships under a
        // `runtimePromptVersion` asserting nothing moved.
        add("AskSupervisorTool.questionnaireRequiredMessage") {
            AskSupervisorTool.questionnaireRequiredMessage
        }
        add("AskSupervisorTool.questionnaireRequiredReason") {
            AskSupervisorTool.questionnaireRequiredReason
        }
        add("AskSupervisorFormTool.repairTheFormReason") {
            AskSupervisorFormTool.repairTheFormReason
        }
        // Nothing open and yet no offset: the text ran out before anything was written. The
        // sample has to be a text that can actually REACH the function — a balanced document
        // never fails this way, so a row rendering one would fingerprint a sentence no run
        // can produce.
        add("SupervisorFormDecoding.unfinishedNote/nothingOpen") {
            SupervisorFormDecoding.unfinishedNote(in: "")
        }
        add("ToolRuntimeError.argumentsNotObject") {
            ToolRuntimeError.argumentsNotObject.errorDescription ?? ""
        }
        add("ToolRuntimeError.duplicateArgumentKey") {
            ToolRuntimeError.duplicateArgumentKey("command").errorDescription ?? ""
        }

        // The argument vocabulary (2026-11-09). The refusals and the rename sentence over
        // sample inputs; every alias DETAIL and every IGNORE reason from the handlers' own
        // tables, so a reworded reason moves this fingerprint like any other text.
        add("ToolArgumentVocabulary.unknownArgumentsMessage/one") {
            ToolArgumentVocabulary.unknownArgumentsMessage(
                tool: ToolNames.search, keys: ["foo"], accepted: ["mode", "paths", "query"])
        }
        add("ToolArgumentVocabulary.unknownArgumentsMessage/many") {
            ToolArgumentVocabulary.unknownArgumentsMessage(
                tool: ToolNames.search, keys: ["bar", "foo"], accepted: ["mode", "paths", "query"])
        }
        add("ToolArgumentVocabulary.unknownArgumentsMessage/none") {
            ToolArgumentVocabulary.unknownArgumentsMessage(tool: ToolNames.gitStatus, keys: ["path"], accepted: [])
        }
        add("ToolArgumentVocabulary.unknownArgumentsMessage/externalMCP", audience: .externalAgent) {
            ToolArgumentVocabulary.unknownArgumentsMessage(
                tool: ExternalAutovisorToolNames.messageTask, keys: ["priority"],
                accepted: ["folder_id", "message", "role_id", "task_id"])
        }
        add("ToolArgumentVocabulary.twoSpellingsMessage/two") {
            ToolArgumentVocabulary.twoSpellingsMessage(
                tool: ToolNames.search, argument: "paths", spellings: ["path", "paths"])
        }
        add("ToolArgumentVocabulary.twoSpellingsMessage/three") {
            ToolArgumentVocabulary.twoSpellingsMessage(
                tool: ToolNames.bash, argument: "command", spellings: ["cmd", "command", "script"])
        }
        add("SupervisorFormPayload.strayQuestionsNote") { SupervisorFormPayload.strayQuestionsNote }
        add("ToolArgumentVocabulary.notTextMessage") {
            ToolArgumentVocabulary.notTextMessage(key: "working_directory", received: "array")
        }
        add("ToolArgumentVocabulary.readAsTextNote") { ToolArgumentVocabulary.readAsTextNote(key: "query") }
        add("ToolArgumentVocabulary.renameNote/one") {
            ToolArgumentVocabulary.renameNote(tool: ToolNames.readFile, renames: [("file_path", "path", nil)])
        }
        // One flat, once-sorted list of (tool, key, kind): the registry order is stable across
        // launches, and nothing sorts inside a loop.
        let vocabularyRows = ToolHandlerRegistry.allTypes
            .flatMap { type in type.undeclaredArguments.map { (tool: type.name, key: $0.key, kind: $0.value) } }
            .sorted { ($0.tool, $0.key) < ($1.tool, $1.key) }
        for row in vocabularyRows {
            switch row.kind {
            case .alias(let argument, let detail?, _):
                add("ToolArgumentVocabulary.renameNote/\(row.tool)/\(row.key)") {
                    ToolArgumentVocabulary.renameNote(tool: row.tool, renames: [(row.key, argument, detail)])
                }
            case .ignored(let reason):
                add("ToolArgumentVocabulary.ignoredNote/\(row.tool)/\(row.key)") {
                    ToolArgumentVocabulary.ignoredNote(key: row.key, reason: reason)
                }
            case .alias, .readByHandler:
                continue
            }
        }
        // The type gate's sentences, model-facing since 2026-09-07 and unregistered until now.
        add("argumentTypeViolations/each") {
            argumentTypeViolations(
                args: ["flag": "on", "count": "many", "paths": 5],
                schema: JSONSchema.object(properties: [
                    "flag": JSONSchema.boolean(), "count": JSONSchema.integer(),
                    "paths": JSONSchema.array(items: JSONSchema.string()),
                ])
            ).joined(separator: " ") + " Fix the value, or omit the argument."
        }
        // `set_work_folder_context`'s empty-text refusal, read by the built-in manager and by an
        // external agent alike — a shared text, so `.localModel` like the other shared replies.
        // Shipped unregistered from 2026-09-07; registered 2026-11-13, when an external agent
        // began to receive it too.
        add("AutovisorToolDecoding.emptyContextDetail") {
            AutovisorToolDecoding.emptyContextDetail
        }

        let loopDetections: [(String, LoopDetection)] = [
            ("repetitivePlanning", .repetitivePlanning(count: 3)),
            ("repetitiveTool", .repetitiveTool(tool: ToolNames.readFile, count: 3)),
            ("repetitiveFailure", .repetitiveFailure(tool: ToolNames.readFile, count: 3, errorCode: ToolErrorCode.fileNotFound.rawValue)),
            // Two rows: the INVALID_ARGS directive reads whether the runtime's message held
            // (the same fault every time) or moved (a converging repair, run 11 of 2026-09-11).
            ("persistentToolError/held", .persistentToolError(tool: ToolNames.readFile, count: 3, errorCode: ToolErrorCode.invalidArgs.rawValue, messagesIdentical: true)),
            ("persistentToolError/moving", .persistentToolError(tool: ToolNames.readFile, count: 3, errorCode: ToolErrorCode.invalidArgs.rawValue, messagesIdentical: false)),
        ]
        for (name, detection) in loopDetections {
            add("LLMExecutionService.loopWarningMessage/\(name)") {
                LLMExecutionService.loopWarningMessage(loopDetection: detection, allowedToolNames: sampleTools)
            }
        }
        add("LoopRecoveryPolicy.nudgePrefix") { LoopRecoveryPolicy.nudgePrefix }
        add("LoopRecoveryPolicy.stuckQuestionMarker") { LoopRecoveryPolicy.stuckQuestionMarker }
        add("LoopRecoveryPolicy.escalationChannel") { LoopRecoveryPolicy.escalationChannel(in: sampleTools)! }
        let signals: [(String, LoopSignal)] = [
            ("withinMessage", .withinMessage(diagnostic: "")),
            ("acrossMessages", .acrossMessages(diagnostic: "")),
            ("identicalToolCallSequence", .identicalToolCallSequence(diagnostic: "")),
        ]
        for (name, signal) in signals {
            add("LoopSignal.modelFacingClause/\(name)") { signal.modelFacingClause }
        }

        // Tool-result notes — the direction appended after an error envelope, per code.
        // `(none)` for a code the policy appends nothing after — the ABSENCE of a direction
        // is versioned too, so a code gaining one moves the fingerprint.
        for code in ToolErrorCode.allCases {
            add("ToolErrorNotePolicy.direction/\(code.rawValue)") {
                ToolErrorNotePolicy.direction(
                    for: makeErrorResult(toolName: ToolNames.readFile, args: ["path": "a.txt"], code: code, message: "Sample failure."),
                    allowedToolNames: sampleTools) ?? "(none)"
            }
        }
        // The executor's own envelopes, per reason — and the direction each one's code
        // draws. These codes are not `ToolErrorCode` cases (the loop above never reaches
        // them), and until the evening of 2026-09-11 neither the four envelopes this wave
        // rewrote nor the `tool_not_authorized` remedy it changed moved the fingerprint.
        let sampleCall = StepToolCall(name: ToolNames.runXcodebuild, argumentsJSON: "{}")
        for reason in LLMExecutionService.ToolUnavailabilityReason.allCases {
            add("LLMExecutionService.makeUnavailableToolResult/\(reason)") {
                LLMExecutionService.makeUnavailableToolResult(
                    call: sampleCall, canonicalName: ToolNames.runXcodebuild,
                    scope: "for this role", reason: reason).outputJSON
            }
        }
        // `.approverUnavailable` branches on `ToolHandlerRegistry.shellTools`, and every row
        // above renders with `run_xcodebuild` — so its SHELL arm rode no row and no
        // fingerprint, and an edit to it would have shipped under an unchanged
        // `runtimePromptVersion`. Byte-for-byte the defect fixed on 2026-09-13 by giving
        // `sampleInquiry` a `recommendedOptionID`: a sample that never reaches a branch leaves
        // that branch's text covered by nothing (DEBTS D-B10).
        add("LLMExecutionService.makeUnavailableToolResult/approverUnavailable+shell") {
            let shellCall = StepToolCall(name: ToolNames.bash, argumentsJSON: "{}")
            return LLMExecutionService.makeUnavailableToolResult(
                call: shellCall, canonicalName: ToolNames.bash,
                scope: "for this role", reason: .approverUnavailable).outputJSON
        }
        // One direction row per executor CODE (several reasons share `precondition_failed`;
        // the first reason carrying a code renders it).
        var seenCodes: Set<String> = []
        for reason in LLMExecutionService.ToolUnavailabilityReason.allCases
            where seenCodes.insert(reason.errorCode).inserted {
            add("ToolErrorNotePolicy.direction/\(reason.errorCode)") {
                ToolErrorNotePolicy.direction(
                    for: LLMExecutionService.makeUnavailableToolResult(
                        call: sampleCall, canonicalName: ToolNames.runXcodebuild,
                        scope: "for this role", reason: reason),
                    allowedToolNames: sampleTools) ?? "(none)"
            }
        }
        add("ToolErrorNotePolicy.direction/identical_write_loop") {
            ToolErrorNotePolicy.direction(
                for: LLMExecutionService.makeIdenticalWriteLoopResult(
                    call: StepToolCall(name: ToolNames.writeFile, argumentsJSON: "{}")),
                allowedToolNames: sampleTools) ?? "(none)"
        }
        // The two sentences the MCP result mapper writes. Everything else in a tool result
        // from an external server is the SERVER's text, which no fingerprint of this app's
        // code could or should cover.
        add("MCPToolResultMapper.serverFailureMessage") {
            MCPToolResultMapper.serverFailureMessage("the ticker was not recognised")
        }
        add("MCPToolResultMapper.serverFailureMessage/silent") {
            MCPToolResultMapper.serverFailureMessage(nil)
        }
        add("MCPToolResultMapper.unknownBlockWarning") {
            MCPToolResultMapper.unknownBlockWarning(kinds: ["video"])
        }
        add("MCPToolResultMapper.injectionWarning") {
            MCPToolResultMapper.injectionWarning(signals: ["instruction_override"])
        }
        // The coercion's refusals of an MCP call whose header parameter has no header spelling,
        // or whose argument violates a declared enum or numeric bound, each naming the property:
        // the `INVALID_ARGS` message the model reads (`ToolErrorHandler`). Rows since 2026-10-28; no row for a
        // value the 2026-07-28 revision says to SEND through its Base64 sentinel — a control
        // character, a line or paragraph separator — and added the spec's own refusal of an
        // integer outside the safe range.
        let coercionFailures: [(String, MCPArgumentCoercion.Failure)] = [
            ("headerValueNotAScalar", .headerValueNotAScalar(argument: "account")),
            ("headerValueOutsideSafeIntegerRange", .headerValueOutsideSafeIntegerRange(argument: "account")),
            ("valueOutsideEnum", .valueOutsideEnum(argument: "format", value: "bmp", allowed: ["png", "jpg"])),
            ("valueOutOfRange", .valueOutOfRange(argument: "scale", value: "5", requirement: "between 1 and 4")),
        ]
        for (name, failure) in coercionFailures {
            add("MCPArgumentCoercion.message/\(name)") { failure.message }
        }
        // The two refusals of a 2026-07-28 call whose result is not a finished answer
        // (basic/index, "ResultType"): the message of its `MCP_TOOL_ERROR` / `MCP_SERVER_UNAVAILABLE`
        // envelope (`ToolErrorHandler`).
        add("MCPClientError.inputRequiredMessage") { MCPClientError.inputRequiredMessage }
        add("MCPClientError.unknownResultTypeMessage/streaming") { MCPClientError.unknownResultTypeMessage("streaming") }
        add("ToolErrorNotePolicy.requiredArgumentsHint") {
            ToolErrorNotePolicy.requiredArgumentsHint(toolName: ToolNames.readFile, argumentsJSON: "{}")
        }
        let sandboxErrors: [(String, SandboxPathError)] = [
            ("absolutePathNotAllowed", .absolutePathNotAllowed("/etc/passwd")),
            ("parentTraversalNotAllowed", .parentTraversalNotAllowed("../secret")),
            ("outsideSandbox", .outsideSandbox("escape")),
            ("restrictedPath", .restrictedPath),
        ]
        for (name, error) in sandboxErrors {
            add("SandboxPathError/\(name)") { error.message }
        }

        // Planning phase.
        add("PlanningPhasePolicy.planningBrief") {
            PlanningPhasePolicy.planningBrief(exploreToolNames: [ToolNames.readFile, ToolNames.search], expectedArtifacts: sampleArtifacts)
        }
        add("PlanningPhasePolicy.implementationSeedTurn") {
            PlanningPhasePolicy.implementationSeedTurn(notes: "- sample note", expectedArtifacts: sampleArtifacts)
        }
        add("PlanningPhasePolicy.planningClosedTurn") { PlanningPhasePolicy.planningClosedTurn }

        // Context compaction — the epoch's request and its seed. Both reach the model: the
        // request is the trailing turn of the summary call, the seed is the one `.user` turn
        // the compacted wire keeps. They shipped a wave before this row existed, because the
        // census pin's population was three NAMED files — the registry's own failure shape
        // (rule #220) reproduced in the pin that guards it. The seed sample carries all three
        // sections so a rewording of any one moves the fingerprint.
        add("CompactionPolicy.summaryRequestTurn") { CompactionPolicy.summaryRequestTurn() }
        add("CompactionPolicy.seedTurn") {
            CompactionPolicy.seedTurn(
                summary: "Wrote the parser and its tests.",
                notes: "- sample note",
                record: ["Ship the smaller change first."])
        }

        // Meetings and votes.
        add("ChangeRequestService.voteInstruction") { ChangeRequestService.voteInstruction }
        add("ChangeRequestService.buildVotingContext") {
            ChangeRequestService.buildVotingContext(
                requestingRole: .codeReviewer, targetRoleDef: sampleRole,
                changes: "Add the null check", reasoning: "Crash on empty input").context
        }
        let directives: [(String, Int, Bool, Bool, Bool, Bool)] = [
            ("participant", 2, false, false, false, false),
            ("coordinatorOpening", 1, true, false, false, false),
            ("coordinatorLast", 6, true, false, false, false),
            ("discussionClub", 2, false, true, false, false),
            ("vote", 2, false, false, true, false),
            ("voteTarget", 2, false, false, true, true),
        ]
        for (name, turn, coordinator, club, votes, target) in directives {
            add("MeetingCoordinator.turnDirective/\(name)") {
                MeetingCoordinator.turnDirective(
                    speakerName: "Software Engineer", turnNumber: turn, maxTurns: 6,
                    isCoordinator: coordinator, isDiscussionClub: club, votes: votes,
                    speakerIsTarget: target)
            }
        }

        // Side exchanges.
        add("DelegatedSupervisorAnswerService.questionTurnBoundaryPhrase") {
            DelegatedSupervisorAnswerService.questionTurnBoundaryPhrase
        }
        // The turn that CARRIES that phrase, and the two sentences that are the exchange's
        // own contract: which tools are on the wire, and what calling one means. One sample —
        // the questionnaire variant differs only in the `question` string, and that string
        // has its own row (`SupervisorInquiryReply.questionnaire`), so a second row here
        // would version the same bytes twice.
        add("DelegatedSupervisorAnswerService.questionTurn") {
            DelegatedSupervisorAnswerService.questionTurn(
                targetTeamName: "Engineering", question: "Which scheme should I build?")
        }
        add("LLMExecutionService.renderChildPausedEnvelope/runTimedOut") {
            LLMExecutionService.renderChildPausedEnvelope(
                childTID: 7,
                targetTeamName: "Engineering Team",
                reason: .runTimedOut(seconds: 600))
        }
        add("LLMExecutionService.renderChildPausedEnvelope/iterationLimitReached") {
            LLMExecutionService.renderChildPausedEnvelope(
                childTID: 7,
                targetTeamName: "Engineering Team",
                reason: .iterationLimitReached(limit: 50))
        }
        add("JudgeReplyChannelPolicy.retryInstruction") { JudgeReplyChannelPolicy.retryInstruction }
        add("BashJudgeService.judgeUserPrompt") { BashJudgeService.judgeUserPrompt(command: "ls", workingDirectory: nil) }
        // The computer-use judge's user turn, twice: a bare click renders the fence alone, and
        // the screen-context lines — the stale note among them — render only with a context.
        add("ComputerUseJudgeService.userPrompt") {
            ComputerUseJudgeService.userPrompt(action: .click(x: 834, y: 250, button: "left", double: false, target: nil))
        }
        add("ComputerUseJudgeService.userPrompt/staleContext") {
            ComputerUseJudgeService.userPrompt(
                action: .click(x: 834, y: 250, button: "left", double: false, target: "Safari"),
                context: ComputerUseJudgeContext(
                    appName: "Safari", windowTitle: "Feed", elementUnderPoint: "AXButton “Post”",
                    actionsSinceCapture: 2))
        }
        for strictness in [MCPJudgeStrictness.permissive, .strict] {
            add("MCPJudgeService.systemPrompt/\(strictness.rawValue)") {
                MCPJudgeService.systemPrompt(strictness: strictness)
            }
        }
        add("MCPJudgeService.userPrompt") {
            MCPJudgeService.userPrompt(call: MCPJudgeCall(
                serverDisplayName: "Folio Desktop",
                toolName: "mcp__folio__place_order",
                toolTitle: "Place order",
                toolDescription: "Places an order on the desk.",
                outgoing: MCPDynamicTool.OutgoingCall(
                    arguments: .object(["id": .string("1")]),
                    headerParameters: [:]),
                annotations: MCPToolAnnotations(
                    raw: .object(["readOnlyHint": .bool(false), "destructiveHint": .bool(true)])),
                priorServerNames: []))
        }
        add("MCPJudgeService.deniedEnvelopeMessage") {
            MCPJudgeService.deniedEnvelopeMessage(reason: "Deletes records.")
        }
        // What a judge's deny envelope carries when the RUNTIME wrote the reason: a transport
        // failure, an unparseable reply, an allow that stayed in the reasoning channel.
        add("JudgeFailClosedReason.bashNoVerdict") { JudgeFailClosedReason.bashNoVerdict }
        add("JudgeFailClosedReason.bashNotSingleObject") { JudgeFailClosedReason.bashNotSingleObject }
        add("JudgeFailClosedReason.bashConflicting") { JudgeFailClosedReason.bashConflicting }
        add("JudgeFailClosedReason.bashMalformed") { JudgeFailClosedReason.bashMalformed }
        add("JudgeFailClosedReason.actionNoVerdict") { JudgeFailClosedReason.actionNoVerdict }
        add("JudgeFailClosedReason.actionUnparseable") { JudgeFailClosedReason.actionUnparseable }
        add("JudgeFailClosedReason.mcpNoVerdict") { JudgeFailClosedReason.mcpNoVerdict }
        add("JudgeFailClosedReason.mcpUnparseable") { JudgeFailClosedReason.mcpUnparseable }
        add("JudgeFailClosedReason.mcpPromptTooLarge") { JudgeFailClosedReason.mcpPromptTooLarge }
        for subject in JudgeFailClosedReason.Subject.allCases {
            add("JudgeFailClosedReason.callFailed/\(subject.rawValue)") {
                JudgeFailClosedReason.callFailed(subject: subject, message: "The request timed out.")
            }
        }
        add("JudgeReplyChannelPolicy.reasoningOnlyAllowReason") { JudgeReplyChannelPolicy.reasoningOnlyAllowReason }
        // A DENY the model gave without a `reason` still reaches the envelope — as each judge's
        // own default sentence, rendered through the parser that substitutes it.
        add("BashJudgeService.parse/denyWithoutReason") { BashJudgeService.parse(#"{"decision":"DENY"}"#).reason }
        add("ComputerUseJudgeService.parse/denyWithoutReason") {
            ComputerUseJudgeService.parse(#"{"decision":"DENY"}"#).reason
        }
        add("MCPJudgeService.parse/denyWithoutReason") {
            MCPJudgeService.parse(#"{"decision":"DENY"}"#).reason
        }
        add("BashExplainService.explainUserPrompt") { BashExplainService.explainUserPrompt(command: "ls", workingDirectory: nil) }

        // A deferred tool call that does not finish: the dispatcher's answer for a call its
        // stopped step never reached, the change-request vote a stopped step interrupted, and a
        // deferred action's when the folder changed under it.
        add("DeferredCallReplies.notRun") { DeferredCallReplies.notRun }
        add("DeferredCallReplies.voteInterrupted") { DeferredCallReplies.voteInterrupted }
        add("DeferredCallReplies.folderChanged") { DeferredCallReplies.folderChanged }
        // The Autovisor's manager: the reply to each of its actions and the mid-review event
        // notice, one row per case of the builder.
        for (name, reply) in autovisorReplySamples {
            add("AutovisorReply.text/\(name)", audience: reply.audience) { reply.text }
        }
        // The Autovisor's read-tool envelopes (`list_tasks`, `task_status`) and their fallback
        // error messages / close-hint reason — every string `LLMExecutionService+Autovisor`
        // returns to the manager's tool-result channel.
        let sampleClock = Date(timeIntervalSince1970: 1_700_000_000)
        add("LLMExecutionService.autovisorUnavailableMessage") {
            LLMExecutionService.autovisorUnavailableMessage
        }
        add("LLMExecutionService.taskStatusNotFoundMessage") {
            LLMExecutionService.taskStatusNotFoundMessage(taskID: 9)
        }
        add("LLMExecutionService.reviewReadyCloseReason") {
            LLMExecutionService.reviewReadyCloseReason
        }
        add("LLMExecutionService.renderListTasksEnvelope") {
            let summaries = [
                TaskSummary(
                    id: 3, title: "Fix login", status: .running,
                    updatedAt: sampleClock.addingTimeInterval(-45),
                    isChatMode: false, hasPendingSupervisorInput: true,
                    pendingSupervisorQuestionCount: 1, hasRolesAwaitingAcceptance: true),
            ]
            return LLMExecutionService.renderListTasksEnvelope(tasks: summaries, now: sampleClock)
        }
        let sampleTeam: Team = {
            var team = Team(name: "Engineering")
            team.roles = [sampleRole]
            return team
        }()
        add("LLMExecutionService.renderTaskStatusEnvelope/running") {
            let step = StepExecution(
                id: "swe", role: .softwareEngineer, title: "Software Engineer",
                status: .running,
                createdAt: sampleClock.addingTimeInterval(-180),
                updatedAt: sampleClock.addingTimeInterval(-120),
                artifacts: [
                    Artifact(
                        name: "Engineering Notes",
                        createdAt: sampleClock, updatedAt: sampleClock,
                        relativePath: "tasks/3/roles/swe/Engineering_Notes.md"),
                ],
                toolCalls: [
                    StepToolCall(
                        name: ToolNames.readFile,
                        argumentsJSON: #"{"path":"README.md"}"#),
                ])
            let waitingStep = StepExecution(
                id: "tl", role: .techLead, title: "Tech Lead",
                status: .needsSupervisorInput,
                createdAt: sampleClock.addingTimeInterval(-180),
                updatedAt: sampleClock.addingTimeInterval(-120),
                needsSupervisorInput: true,
                supervisorQuestion: "Which scheme should I build?")
            let run = Run(
                id: 0,
                createdAt: sampleClock.addingTimeInterval(-180),
                updatedAt: sampleClock.addingTimeInterval(-120),
                steps: [step, waitingStep],
                roleStatuses: ["swe": .needsAcceptance])
            let task = NTMSTask(
                id: 3, title: "Fix login", supervisorTask: "Investigate login timeout.",
                status: .running,
                createdAt: sampleClock.addingTimeInterval(-180),
                updatedAt: sampleClock.addingTimeInterval(-120),
                runs: [run],
                runTimeoutSeconds: 600)
            return LLMExecutionService.renderTaskStatusEnvelope(
                task: task, team: sampleTeam, now: sampleClock,
                lastError: "Connection timed out.")
        }
        add("LLMExecutionService.renderTaskStatusEnvelope/reviewReadyToClose") {
            let step = StepExecution(
                id: "swe", role: .softwareEngineer, title: "Software Engineer",
                status: .done,
                createdAt: sampleClock.addingTimeInterval(-180),
                updatedAt: sampleClock.addingTimeInterval(-30),
                completedAt: sampleClock.addingTimeInterval(-30))
            let run = Run(
                id: 0,
                createdAt: sampleClock.addingTimeInterval(-180),
                updatedAt: sampleClock.addingTimeInterval(-30),
                steps: [step],
                roleStatuses: ["swe": .done])
            let task = NTMSTask(
                id: 3, title: "Fix login", supervisorTask: "Investigate login timeout.",
                status: .needsSupervisorAcceptance,
                createdAt: sampleClock.addingTimeInterval(-180),
                updatedAt: sampleClock.addingTimeInterval(-30),
                runs: [run])
            return LLMExecutionService.renderTaskStatusEnvelope(
                task: task, team: sampleTeam, now: sampleClock)
        }
        // `create_managed_task`'s team refusal, per failing resolution — and the remedy's three
        // arms between them: several options, one option, and none left.
        let engineering = Team(name: "Engineering")
        let refusals: [(String, AutovisorTeamPolicy, AutovisorTeamPolicy.ManagedTeamResolution, [Team], Bool)] = [
            ("generationDisabled", AutovisorTeamPolicy(allowGeneration: false), .generationDisabled, [engineering], true),
            ("teamBlocked", .unrestricted, .teamBlocked("Engineering"), [engineering], true),
            ("activeTeamBlocked", .unrestricted, .activeTeamBlocked("Engineering"), [engineering], false),
            ("activeTeamIsChat", AutovisorTeamPolicy(allowGeneration: false), .activeTeamIsChat("Coding Assistant"), [engineering], false),
            ("activeTeamNotUsable", .unrestricted, .activeTeamNotUsable, [engineering], false),
            ("unknown", AutovisorTeamPolicy(allowGeneration: false), .unknown("no-such-team"), [], false),
        ]
        for (name, policy, resolution, teams, omitPathIsViable) in refusals {
            add("AutovisorTeamPolicy.failureMessage/\(name)") {
                Self.orNone(policy.failureMessage(for: resolution, allTeams: teams, omitPathIsViable: omitPathIsViable))
            }
            add("AutovisorTeamPolicy.failureMessage/externalMCP/\(name)", audience: .externalAgent) {
                Self.orNone(policy.failureMessage(
                    for: resolution, allTeams: teams, omitPathIsViable: omitPathIsViable, surface: .externalMCP
                ))
            }
        }
        // `manage_role accept` refused: the fact, per status and for a role with no status
        // entry, and the way out — the remedy's prose and the reason its `next` hint carries
        // (`AutovisorReply.acceptRejected` joins the first two). `(none)` where a status is no
        // refusal: the absence is versioned too.
        add("AcceptanceService.validateAcceptance/unknownRole") {
            Self.orNone(AcceptanceService.validateAcceptance(roleID: "swe", roleStatuses: [:]))
        }
        for status in RoleExecutionStatus.allCases {
            add("AcceptanceService.validateAcceptance/\(status.rawValue)") {
                Self.orNone(AcceptanceService.validateAcceptance(roleID: "swe", roleStatuses: ["swe": status]))
            }
        }
        var adviceCases: [(String, RoleExecutionStatus?, Bool, Bool)] = [("noStatus", nil, false, false)]
        for status in RoleExecutionStatus.allCases { adviceCases.append((status.rawValue, status, false, false)) }
        adviceCases.append(("done/readyToClose", .done, false, true))
        adviceCases.append(("done/chat", .done, true, false))
        for (name, status, isChat, readyToClose) in adviceCases {
            add("AutovisorStatus.acceptRejectionAdvice/\(name)") {
                guard let advice = AutovisorStatus.acceptRejectionAdvice(
                    roleStatus: status, isChatModeTask: isChat, taskReadyToClose: readyToClose,
                    taskID: 3, roleID: "swe")
                else { return "(none)" }
                return advice.prose + "\n" + (advice.next.reason ?? "")
            }
        }
        for state in ExternalAutovisorReadiness.State.allCases {
            add("ExternalAutovisorReadiness.reason/\(state.rawValue)", audience: .externalAgent) {
                Self.orNone(ExternalAutovisorReadiness.reason(for: state))
            }
            add("ExternalAutovisorReadiness.whatThePersonMustDo/\(state.rawValue)", audience: .externalAgent) {
                Self.orNone(ExternalAutovisorReadiness.whatThePersonMustDo(for: state))
            }
        }
        add("LLMRetryNotice.text", audience: .externalAgent) {
            LLMRetryNotice.text(
                attempt: 2, maxRetries: 3, errorDescription: "Could not connect to the server.", delaySeconds: 10)
        }
        add("NTMSOrchestrator.timeoutNotPastElapsedMessage", audience: .externalAgent) {
            NTMSOrchestrator.timeoutNotPastElapsedMessage(elapsedSeconds: 7_200)
        }
        add("NTMSOrchestrator.foreignTaskRefusalMessage", audience: .externalAgent) {
            NTMSOrchestrator.foreignTaskRefusalMessage(taskID: 3)
        }
        // `set_work_folder_context`'s refusals of an external agent (2026-11-13): the person's
        // switch, the characters that change how text displays, a stamp that is none.
        add("NTMSOrchestrator.contextReplacementNotAllowedMessage", audience: .externalAgent) {
            NTMSOrchestrator.contextReplacementNotAllowedMessage
        }
        add("NTMSOrchestrator.contextReplacementNotAllowedRemedy", audience: .externalAgent) {
            NTMSOrchestrator.contextReplacementNotAllowedRemedy
        }
        add("NTMSOrchestrator.contextHiddenCharactersDetail", audience: .externalAgent) {
            NTMSOrchestrator.contextHiddenCharactersDetail(count: 2, first: "\u{202E}", position: 41)
        }
        add("NTMSOrchestrator.contextRevisionNotARevisionDetail", audience: .externalAgent) {
            NTMSOrchestrator.contextRevisionNotARevisionDetail
        }
        add("NTMSOrchestrator.alreadyCreatedIdempotentMessage", audience: .externalAgent) {
            NTMSOrchestrator.alreadyCreatedIdempotentMessage(taskID: 3, requestKey: "req-1")
        }
        add("NTMSOrchestrator.createdBeforeFolderChangedMessage", audience: .externalAgent) {
            NTMSOrchestrator.createdBeforeFolderChangedMessage(taskID: 3)
        }
        add("NTMSOrchestrator.requestInProgressMessage", audience: .externalAgent) {
            NTMSOrchestrator.requestInProgressMessage(requestKey: "req-1")
        }
        add("NTMSOrchestrator.changedFilesBashNote", audience: .externalAgent) {
            NTMSOrchestrator.changedFilesBashNote
        }
        add("HostedMCPStdioRelay.serverNotAnsweringMessage", audience: .externalAgent) {
            HostedMCPStdioRelay.serverNotAnsweringMessage(port: 47321)
        }
        add("HostedMCPInstructions.text", audience: .externalAgent) {
            HostedMCPInstructions.text
        }
        for toolName in HostedMCPCatalog.toolNames {
            add("HostedMCPCatalog.toolDescription/\(toolName)", audience: .externalAgent) {
                HostedMCPCatalog.toolDescription(for: toolName)
            }
        }
        // The input schemas the agent reads beside each description. Unregistered until
        // 2026-11-07, so a property's wording could change without moving `agentTextVersion`.
        for toolName in HostedMCPCatalog.toolNames {
            add("HostedMCPCatalog.inputSchemaText/\(toolName)", audience: .externalAgent) {
                HostedMCPCatalog.inputSchemaText(for: toolName)
            }
        }
        // A refused `folder_id`, per case: the message and the call it points at. Until
        // 2026-11-08 a stale id and a call with no folder open borrowed the race reply.
        for refusal in ExternalFolderRefusal.allCases {
            add("ExternalFolderRefusal.message/\(refusal)", audience: .externalAgent) {
                refusal.message
            }
            add("ExternalFolderRefusal.next/\(refusal)", audience: .externalAgent) {
                [refusal.next.suggested_cmd, refusal.next.reason].compactMap { $0 }.joined(separator: "\n")
            }
        }
        add("AutovisorReply.createdScheduled/withDate", audience: .externalAgent) {
            AutovisorReply.createdScheduled(for: 1, title: "Task", runAt: Date(timeIntervalSince1970: 1700000000))
        }
        add("AutovisorReply.createdScheduled/withoutDate", audience: .externalAgent) {
            AutovisorReply.createdScheduled(for: 1, title: "Task", runAt: nil)
        }
        add("ExternalAutovisorOperations.llmUnreachableWarning", audience: .externalAgent) {
            ExternalAutovisorOperations.llmUnreachableWarning
        }
        for reason in [ApprovalGatedAvailability.Reason.switchedOff, .noApprover] {
            let key = reason == .switchedOff ? "switched_off" : "no_approver"
            add("ExternalAutovisorApprovals.bashWhatThePersonMustDo/\(key)", audience: .externalAgent) {
                ExternalAutovisorApprovals.bashWhatThePersonMustDo(for: reason)
            }
            add("ExternalAutovisorApprovals.computerUseWhatThePersonMustDo/\(key)", audience: .externalAgent) {
                ExternalAutovisorApprovals.computerUseWhatThePersonMustDo(for: reason)
            }
        }
        add("ExternalAutovisorOperations.continuationPausesAtOnceWarning", audience: .externalAgent) {
            ExternalAutovisorOperations.continuationPausesAtOnceWarning
        }
        // The refusals production writes, rendered through the builders it calls (F6 T3: hand-
        // written copies until 2026-11-12).
        for sample in ControlVerb.TimeoutRefusal.registrySamples {
            add("ControlVerb.refusalMessage/\(sample.name)", audience: .externalAgent) {
                ControlVerb.refusalMessage(sample.refusal)
            }
        }
        add("TaskChangesRefusal.invalidFilePath", audience: .externalAgent) {
            TaskChangesRefusal.invalidFilePath("foo/../bar")
        }
        add("TaskChangesRefusal.invalidPage", audience: .externalAgent) { TaskChangesRefusal.invalidPage }
        add("TaskChangesRefusal.invalidPageSize", audience: .externalAgent) { TaskChangesRefusal.invalidPageSize }
        add("TaskChangesRefusal.invalidRoundArgument", audience: .externalAgent) {
            TaskChangesRefusal.invalidRoundArgument
        }
        add("TaskChangesRefusal.invalidPageArgument", audience: .externalAgent) {
            TaskChangesRefusal.invalidPageArgument
        }
        add("TaskChangesRefusal.protectedWorkFolder", audience: .externalAgent) {
            TaskChangesRefusal.protectedWorkFolder("/System")
        }
        add("TaskChangesRefusal.snapshotsUnavailable", audience: .externalAgent) {
            TaskChangesRefusal.snapshotsUnavailable(taskID: 1)
        }
        add("TaskChangesRefusal.roundDoesNotExist", audience: .externalAgent) {
            TaskChangesRefusal.roundDoesNotExist(round: 99, taskID: 1)
        }
        // The call every refusal names next, and why (F6 L1/T4: about thirty inline reasons until
        // 2026-11-12, none of them in the fingerprint).
        for call in ExternalNextCall.allCases {
            add("ExternalNextCall.reason/\(call.rawValue)", audience: .externalAgent) {
                (call.command ?? "(the refused tool)") + "\n" + call.reason
            }
        }
        add("TaskChangesWarnings.hiddenCharactersInName", audience: .externalAgent) {
            TaskChangesWarnings.hiddenCharactersInName("src/a<U+202E>b.swift")
        }
        add("TaskChangesWarnings.hiddenCharactersInDiff", audience: .externalAgent) {
            TaskChangesWarnings.hiddenCharactersInDiff("src/a.swift")
        }
        add("TaskChangesWarnings.notUTF8", audience: .externalAgent) {
            TaskChangesWarnings.notUTF8("legacy.txt")
        }
        add("TaskChangesWarnings.storeRestored", audience: .externalAgent) {
            TaskChangesWarnings.storeRestored(["config", "hooks"])
        }
        add("TaskChangesWarnings.lateStartSnapshot", audience: .externalAgent) {
            TaskChangesWarnings.lateStartSnapshot(round: 2)
        }
        add("TaskChangesWarnings.endSnapshotMissing/timedOut", audience: .externalAgent) {
            TaskChangesWarnings.endSnapshotMissing(round: 2, reason: .timedOut)
        }
        add("TaskChangesWarnings.endSnapshotMissing/failed", audience: .externalAgent) {
            TaskChangesWarnings.endSnapshotMissing(round: 2, reason: .failed)
        }
        add("TaskChangesWarnings.endSnapshotMissing/completedLate", audience: .externalAgent) {
            TaskChangesWarnings.endSnapshotMissing(round: 2, reason: .completedLate)
        }
        return e
    }()

    nonisolated private static func orNone(_ value: String?) -> String {
        value ?? "(none)"
    }
}
