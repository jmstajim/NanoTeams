import Foundation

/// Every model-facing text `handleNoToolCalls` appends after a turn that called no tool.
///
/// They lived as inline literals inside the branch that emits them, which cost two things.
/// `RuntimePromptRegistry` could not carry them, so their bytes rode every provenance record
/// under a `runtimePromptVersion` that said nothing had changed — measured on 2026-09-08,
/// when seven of these texts were rewritten and the fingerprint did not move (REC.9). And
/// `Ratchet/NudgeTextPinTests` could only SOURCE-scan them: its value scan runs over builders,
/// so the five rules it enforces — anchored to the note, names only tools the role holds, no
/// politeness, no exception clause, names a channel or nothing — never read these strings.
///
/// Pure functions of (defect facts, `allowedToolNames`), house pattern: `LoopRecoveryPolicy`,
/// `ToolErrorNotePolicy`, `CompactionPolicy`. `nonisolated` because the app target defaults
/// types to `@MainActor`.
///
/// The cap ESCALATION questions are not here: they are addressed to the Supervisor (a human,
/// or `SupervisorAutoAnswerService`), not to the role, and they stay beside the branch that
/// raises them as `LLMExecutionService` statics.
nonisolated enum NoToolTurnNudges {

    /// `" (e.g. \"read_file\", \"search\")"` for the role's own tools, or `""`.
    private static func examplesClause(allowedToolNames: Set<String>) -> String {
        LLMExecutionService.toolNameExamples(allowedToolNames: allowedToolNames)
            .map { " (e.g. \($0))" } ?? ""
    }

    /// runtime-prompt
    static func reasoningChannel(namedCalls: [String], allowedToolNames: Set<String>) -> String {
        let named = namedCalls.filter(allowedToolNames.contains)
        let wrote = named.isEmpty
            ? ""
            : " You wrote a call to \(named.map { "`\($0)`" }.joined(separator: ", ")) there."
        // Anchored on the STATE, not on "your previous turn": the reasoning channel is
        // stripped from the history the model is resent, so a nudge that opens by naming
        // what the model wrote there points at a turn it cannot see. What it CAN verify is
        // that nothing ran.
        return """
        This step received no callable output — the tool call was written inside your \
        reasoning, where nothing can run it.\(wrote) Write the call in your reply instead \
        of your reasoning, as a single envelope on its own line.\
        \(LLMExecutionService.callShapeClause(allowedToolNames: allowedToolNames))
        """
    }

    /// runtime-prompt
    static func thinkingDrift(thousandsOfCharacters: Int) -> String {
        // Same re-anchor as the reasoning-channel nudge: the reasoning it measures is not in
        // the history the model is resent.
        """
        This step received ~\(thousandsOfCharacters)k characters of internal reasoning \
        and no tool call — reasoning alone cannot read files, write files, or submit \
        artifacts. Take one concrete action now: call the tool that advances your next step.
        """
    }

    /// runtime-prompt
    static func missingToolName(allowedToolNames: Set<String>) -> String {
        // Examples filtered to the role's schema — an illustration naming a tool it doesn't
        // have teaches a vocabulary the runtime rejects. The `name` slot of the envelope was
        // the one place that was NOT filtered: it came from schema-blind shape inference, so a
        // producing role in the planning phase could be shown `create_artifact`, which that
        // phase withholds (R3.3.5, R3.8.3).
        """
        The turn immediately before this note carried a tool call whose JSON parsed \
        but was missing the top-level `name` field, so no tool was identified and \
        nothing ran. The top-level `name` is the tool id\(examplesClause(allowedToolNames: allowedToolNames)); a `name` inside \
        `arguments` is a tool parameter. Put the id at the top level, beside \
        `arguments`, and keep the arguments you already wrote.\
        \(LLMExecutionService.callShapeClause(allowedToolNames: allowedToolNames))
        """
    }

    /// runtime-prompt
    static func toolNameInsideArguments(allowedToolNames: Set<String>) -> String {
        // The id the model wrote is deliberately NOT echoed: it names no registered tool, and
        // a nudge that repeats it teaches a vocabulary the runtime rejects (R3.8.3). The feed
        // card carries it for the human.
        """
        The turn immediately before this note put the tool id inside `arguments`, \
        where it is read as a parameter, and the id it carried names no tool this \
        role can call — so nothing ran. The top-level `name` is the tool id\(examplesClause(allowedToolNames: allowedToolNames)). \
        Put the id at the top level, beside `arguments`.\
        \(LLMExecutionService.callShapeClause(allowedToolNames: allowedToolNames))
        """
    }

    /// runtime-prompt
    static func malformedJSON(defect: String, allowedToolNames: Set<String>) -> String {
        // Anchored to this note's own position, never to the reader's present: the note is
        // never retired, and "your previous turn" is false the moment one more turn follows it
        // (R3.8.4).
        //
        // "quoted verbatim in that turn" was an assertion about the wire, and the wire does not
        // always carry it: a step that re-enters with an empty `wireTranscript` rebuilds from
        // the display record. That rebuild now re-materializes the envelope
        // (`ConversationReplay`), but a nudge is never retired, so it must stay true on a wire
        // written before this change too.
        //
        // It prescribed "with the two closing braces before `<|end|>`" UNCONDITIONALLY until
        // 2026-09-08 — advice true for one failure shape and a false diagnosis for its
        // neighbours (R1.8.5, R3.8.2). `ornith-1.0-35b` transposed a quote, was told to add
        // closers it had already written, and repeated "missing closing brace" in its next
        // reasoning (CastleSurvivors task 5 run 0). The defect is named once, by the parser,
        // in `defect`; this sentence asks only for a whole envelope (R3.8.7).
        "The tool call in the turn immediately before this note had malformed JSON and could not be parsed (\(defect)). Re-emit it as one complete envelope: the whole call object between `<|call|>` and `<|end|>`.\(LLMExecutionService.callShapeClause(allowedToolNames: allowedToolNames))"
    }

    /// runtime-prompt
    static func noCallEnvelope(allowedToolNames: Set<String>) -> String {
        // Names the shape the model ACTUALLY emits: gpt-oss reaches for the channel form and
        // may never emit `<|call|>` in a whole pass, so a nudge teaching only the canonical
        // form describes a syntax the model isn't using while saying nothing about the one it
        // is.
        let both = HarmonyCallExample.toolAndArguments(preferring: allowedToolNames)
        let forms = both.map {
            """
             Either as \
            `<|channel|>commentary to=\($0.name)<|message|>\($0.argumentsJSON)` or as \
            `<|call|>{"name":"\($0.name)","arguments":\($0.argumentsJSON)}<|end|>`.
            """
        } ?? ""
        return """
        The turn immediately before this note opened a Harmony channel but never made a tool call — \
        there was no recipient and no JSON body to dispatch. Name the tool and give it \
        arguments.\(forms)
        """
    }

    /// runtime-prompt
    static func tokensOnly() -> String {
        // The turn this describes reaches the model EMPTY — that is the branch condition — so
        // "your previous response" names nothing it can look at. The state is the anchor.
        "This step received no usable content: the last reply was only model-internal tokens (<|...|>). Emit a tool call or a completion message."
    }

    /// runtime-prompt
    static func planningSalvage(allowedToolNames: Set<String>) -> String {
        // Anchored to the note, not to "That" — re-read on every later request, a
        // demonstrative points at whatever turn is nearest (R3.8.4). And a real id from the
        // phase's narrowed schema, in the one phase where the model most needs to be shown
        // which ids survive.
        """
        The turn immediately before this note looked like a tool call but did not \
        parse as one, so nothing ran and nothing was recorded. Emit it as a single \
        envelope on its own line.\
        \(LLMExecutionService.callShapeClause(allowedToolNames: allowedToolNames))
        Nothing before the `<|call|>` and nothing after the `<|end|>`.
        """
    }

    /// runtime-prompt
    static func planRecorded() -> String {
        "Plan recorded from your text response. The implementation phase starts on your next turn with your full toolset."
    }

    /// runtime-prompt
    static func unrecognisedSentinel(sentinel: String, allowedToolNames: Set<String>) -> String {
        // Names the form by OUR literal rather than quoting the model's bytes: a nudge is never
        // retired, so a quoted attempt rides the prefix of every later request and re-seeds the
        // loop it was meant to break (R3.8.3, R3.8.4).
        """
        The turn immediately before this note opened a tool call with `\(sentinel)`, \
        which is not the call sentinel — so nothing ran and nothing was recorded. The \
        sentinel is `<|call|>`, closing `>` included, with the payload's `{` next.\
        \(LLMExecutionService.callShapeClause(allowedToolNames: allowedToolNames))
        Nothing before the `<|call|>` and nothing after the `<|end|>`.
        """
    }

    /// runtime-prompt
    ///
    /// Named `create_artifact` unconditionally until 2026-09-08. The branch that raises it
    /// only fires for a producing role, which holds the tool in practice — but "in practice"
    /// is what Rule 2 exists to stop being the argument, and this text was invisible to its
    /// value scan while it was an inline literal. A role without the tool now gets the
    /// instruction with no id, which Rule 5 allows and `tool_not_authorized` ping-pong does not.
    static func revisionArtifacts(allowedToolNames: Set<String>) -> String {
        allowedToolNames.contains(ToolNames.createArtifact)
            ? "Address the supervisor's feedback and submit updated artifacts via create_artifact."
            : "Address the supervisor's feedback and submit the updated deliverables."
    }
}
