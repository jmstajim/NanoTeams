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
        add("ToolCallParsingHelpers.spilledArgumentsNote") {
            ToolCallParsingHelpers.spilledArgumentsNote(
                recoveredKeys: ["path", "old_text"])!
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
        add("JudgeReplyChannelPolicy.retryInstruction") { JudgeReplyChannelPolicy.retryInstruction }
        add("BashJudgeService.judgeUserPrompt") { BashJudgeService.judgeUserPrompt(command: "ls", workingDirectory: nil) }
        add("BashExplainService.explainUserPrompt") { BashExplainService.explainUserPrompt(command: "ls", workingDirectory: nil) }
        return e
    }()
}
