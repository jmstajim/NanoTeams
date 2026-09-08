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

    /// `nonisolated` so the rows can be built from a nested helper; the renderer itself
    /// is main-actor code, which the closure type says.
    nonisolated struct Entry {
        let name: String
        let render: @MainActor () -> String
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
    private static let sampleSchema = ToolSchema(
        name: "sample_tool",
        description: "A sample tool.",
        parameters: JSONSchema(type: "object", properties: ["path": JSONSchema.string("A path.")], required: ["path"]))
    private static let sampleRole = TeamRoleDefinition(
        id: "swe", name: "Software Engineer", prompt: "", toolIDs: [], usePlanningPhase: false,
        dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: sampleArtifacts))

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
        func add(_ name: String, _ render: @escaping @MainActor () -> String) {
            e.append(Entry(name: name, render: render))
        }

        for row in oneShotSystemPrompts { add(row.label, row.render) }

        // The Harmony tool-calling body and the tool-less sentence.
        add("NativeLMStudioClient.buildToolSchemaBody/sampleTool") {
            NativeLMStudioClient.buildToolSchemaBody(tools: [sampleSchema])
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
        add("LLMExecutionService.noToolCallNudge") { LLMExecutionService.noToolCallNudge(allowedToolNames: sampleTools) }
        add("LLMExecutionService.repetitiveNonToolNudge") {
            LLMExecutionService.repetitiveNonToolNudge(count: 2, allowedToolNames: sampleTools)
        }
        add("LLMExecutionService.missingArtifactsNudge") { LLMExecutionService.missingArtifactsNudge(missing: sampleArtifacts) }
        add("LLMExecutionService.escalationClause") {
            LLMExecutionService.escalationClause(code: nil, allowedToolNames: sampleTools)
        }
        add("LLMExecutionService.escalationClause/approvalUnavailable") {
            LLMExecutionService.escalationClause(code: ToolErrorCode.approvalUnavailable.rawValue, allowedToolNames: sampleTools)
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
        add("ToolCallParsingHelpers.malformedJSONDiagnostic/unbalanced") {
            ToolCallParsingHelpers.malformedJSONDiagnostic(
                in: #"<|call|>{"name":"write_file","arguments":{"path":"x"#)!
        }
        add("ToolCallParsingHelpers.spilledArgumentsNote") {
            ToolCallParsingHelpers.spilledArgumentsNote(
                recoveredKeys: ["path", "old_text"])!
        }
        add("ToolCallParsingHelpers.transposedQuoteRepairNote") {
            ToolCallParsingHelpers.transposedQuoteRepairNote
        }
        add("ToolRuntimeError.argumentsNotObject") {
            ToolRuntimeError.argumentsNotObject.errorDescription ?? ""
        }

        let loopDetections: [(String, LoopDetection)] = [
            ("repetitivePlanning", .repetitivePlanning(count: 3)),
            ("repetitiveTool", .repetitiveTool(tool: ToolNames.readFile, count: 3)),
            ("repetitiveFailure", .repetitiveFailure(tool: ToolNames.readFile, count: 3, errorCode: ToolErrorCode.fileNotFound.rawValue)),
            ("persistentToolError", .persistentToolError(tool: ToolNames.readFile, count: 3, errorCode: ToolErrorCode.invalidArgs.rawValue)),
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
        let directives: [(String, Int, Bool, Bool, Bool)] = [
            ("participant", 2, false, false, false),
            ("coordinatorOpening", 1, true, false, false),
            ("coordinatorLast", 6, true, false, false),
            ("discussionClub", 2, false, true, false),
            ("vote", 2, false, false, true),
        ]
        for (name, turn, coordinator, club, votes) in directives {
            add("MeetingCoordinator.turnDirective/\(name)") {
                MeetingCoordinator.turnDirective(
                    speakerName: "Software Engineer", turnNumber: turn, maxTurns: 6,
                    isCoordinator: coordinator, isDiscussionClub: club, votes: votes)
            }
        }

        // Side exchanges.
        add("DelegatedSupervisorAnswerService.questionTurnBoundaryPhrase") {
            DelegatedSupervisorAnswerService.questionTurnBoundaryPhrase
        }
        add("JudgeReplyChannelPolicy.retryInstruction") { JudgeReplyChannelPolicy.retryInstruction }
        add("BashJudgeService.judgeUserPrompt") { BashJudgeService.judgeUserPrompt(command: "ls", workingDirectory: nil) }
        add("BashExplainService.explainUserPrompt") { BashExplainService.explainUserPrompt(command: "ls", workingDirectory: nil) }
        return e
    }()
}
