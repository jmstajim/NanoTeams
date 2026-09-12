import Foundation

private typealias TN = ToolNames
private typealias JS = JSONSchema

// MARK: - ask_supervisor

nonisolated struct AskSupervisorTool: ToolHandler {
    static let name = TN.askSupervisor
    static let schema = ToolSchema(
        name: TN.askSupervisor,
        description: "Ask the Supervisor a question. The step will pause until the Supervisor answers.",
        parameters: JS.object(
            properties: [
                "question": JS.string(),
            ],
            required: ["question"]
        )
    )
    static let category: ToolCategory = .supervisor
    static let excludedInMeetings = true

    
    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self()
    }

    func handle(context: ToolExecutionContext, args: [String: Any]) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: Self.name, args: args) {
            // Non-empty, because the dispatcher's own `!trimmed.isEmpty` guard
            // (`+ToolResultDispatching`) silently declines to park on an empty
            // question — so accepting one here reports `ok: true` for a step that
            // never stops, and the model waits for an answer nobody was asked for
            // until the non-productive-turn ceiling ends the step.
            let question = try requiredNonEmptyString(args, "question")
            // Several questions, or one with its options, is the form's shape: refused —
            // an error, not a park — when the batch holds the form (`SupervisorQuestionShape`
            // says why, and why never otherwise).
            if SupervisorQuestionShape.requiresForm(
                question, formAvailable: context.questionnaireAvailable) {
                return questionnaireRequired(args: args)
            }
            return makeSupervisorQuestionResult(
                toolName: Self.name,
                args: args,
                question: question
            )
        }
    }

    /// Shaped like `AskSupervisorFormTool.invalidForm`: the defect in the message, the standing
    /// instruction in `next`. `ToolErrorNotePolicy` appends nothing after this code — the
    /// envelope already carries both halves, and the default arm's "choose a different
    /// approach" would send an ask-only role back to prose.
    private func questionnaireRequired(args: [String: Any]) -> ToolExecutionResult {
        ToolExecutionResult(
            toolName: Self.name,
            argumentsJSON: encodeArgsToJSON(args),
            outputJSON: makeErrorEnvelope(
                code: .questionnaireRequired,
                message: Self.questionnaireRequiredMessage,
                next: NextHint(
                    suggested_cmd: TN.askSupervisorForm,
                    reason: Self.questionnaireRequiredReason)),
            isError: true
        )
    }

    /// runtime-prompt
    static let questionnaireRequiredMessage =
        "Several questions, or one with its options, in a plain ask. Nothing was asked — the "
            + "Supervisor is not waiting."

    /// runtime-prompt
    ///
    /// The last sentence is the one the refusal was missing. A questionnaire a role arrives at
    /// through ANALYSIS has a body, and the form has nowhere to put it: a headline and the
    /// questions. Told only "send the same questions as a form", the model sent the questions
    /// and dropped 2.4 KB of Russian analysis the Supervisor then never read (MeditationApp
    /// task 67 run 1, 2026-09-11). The turn's own text is committed to the feed beside the
    /// call, so the two channels together carry what the plain ask carried alone.
    static let questionnaireRequiredReason =
        "Send the same questions as a form: one `questions` entry per question; a choice as "
            + "single_choice with its options. The analysis "
            + "around them is not a question — write it as the turn's own text, beside the "
            + "call."
}

// MARK: - ask_supervisor_form

/// The structured sibling of `ask_supervisor`: several questions at once, each with
/// predefined answers.
///
/// A separate tool rather than an optional parameter on `ask_supervisor`, and the reason is
/// chat mode: every chat template ends with "reply by calling `ask_supervisor`", so every
/// assistant turn in a chat-mode team is an `ask_supervisor` call. A form parameter reachable
/// there would turn conversation into a questionnaire. Two tools let the schema resolver
/// decide, per role, whether questionnaires are even a thing this role can do.
///
/// It is a COMPANION, never a replacement: `LoopRecoveryPolicy.escalationChannel` names one
/// escalation channel and does not know this tool, so a role holding only the form would have
/// no channel at all. `TeamValidationService` flags that shape.
nonisolated struct AskSupervisorFormTool: ToolHandler {
    static let name = TN.askSupervisorForm
    static let schema = ToolSchema(
        name: TN.askSupervisorForm,
        description: """
        Ask the Supervisor several questions at once, each with the answers you think \
        are likely. The step pauses until they reply.
        
        The headline is one line naming what the questions are about — it is what the \
        Supervisor sees first.
        
        The form is a nested object — send the object itself, not a string \
        containing it. It has a `questions` array, one entry per question. Each entry \
        carries its own `prompt`, an optional `detail`, and a `kind` of free_text, \
        single_choice or multi_choice. A choice question also has an `options` array \
        whose entries you order as you would present them. Each option has a `label` and \
        an optional `detail`; if you recommend one, open that option's `detail` with the \
        word Recommended. Ids are optional and derived from the text.
        
        Example call: {"headline": "Which scheme to build", "form": \
        {"questions": [{"prompt": "Which scheme should I build?", "kind": \
        "single_choice", "options": [{"label": "Debug", "detail": "Recommended. What CI \
        uses"}, \
        {"label": "Release"}]}, {"prompt": "Anything else I should know?", "kind": \
        "free_text"}]}}
        """,
        parameters: JS.object(
            properties: [
                "headline": JS.string("One line naming what the questions are about."),
                "form": JS.object("The questionnaire object. See the description."),
            ],
            required: ["headline", "form"]
        )
    )
    static let category: ToolCategory = .supervisor
    static let excludedInMeetings = true

    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self()
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: Self.name, args: args) {
            // Reading the questionnaire and shaping a tool result are two jobs, and only the
            // first is wanted by the second seam that needs it — the delegated Supervisor
            // exchange, which has no tool runtime at all. The whole ladder therefore lives in
            // `SupervisorFormPayload`; what stays here is the envelope. Splitting it is what
            // let a form call stop reading as "no answer" on the delegated path (DEBTS D-B14).
            switch try SupervisorFormPayload.read(args: args) {
            case .read(let read):
                return makeSupervisorFormResult(
                    toolName: Self.name, args: args, inquiry: read.inquiry,
                    droppedQuestions: read.droppedQuestions, repairs: read.repairs)
            case .refused(let refusal):
                return invalidForm(
                    args: args, diagnosis: refusal.diagnosis,
                    message: refusal.message, repairs: refusal.repairs)
            }
        }
    }

    /// Every rejection of a form, shaped so the model can act on it.
    ///
    /// The fault comes FIRST and the repairs after it, marked as already handled. A repair
    /// that worked is not a diagnosis: read as the opening sentence of a refusal it is a
    /// false one, and the model acts on it — on 2026-09-11 it answered a refusal whose real
    /// fault was an object it never closed with "The curly quotes « » and “ ” are breaking
    /// the parser" and rewrote every string in ASCII, leaving the fault untouched (playbook
    /// R1.8.1: the fault in the first sentence; R1.8.5: a false diagnosis sends the model to
    /// perturb the wrong thing for another round).
    ///
    /// The standing instruction rides in `next` rather than in the literal: the decoder's own
    /// messages already say what to change and where (they carry the coding path), and
    /// appending a generic "fix it and try again" to each of them would restate the specific
    /// advice with a vaguer one.
    private func invalidForm(
        args: [String: Any],
        diagnosis: SupervisorFormPayload.Diagnosis,
        message: String,
        repairs: [String] = []
    ) -> ToolExecutionResult {
        var text = "Invalid form: \(message)"
        if !repairs.isEmpty {
            text += " " + SupervisorFormTextRepair.handledNotTheFaultNote(repairs)
        }
        return ToolExecutionResult(
            toolName: Self.name,
            argumentsJSON: encodeArgsToJSON(args),
            outputJSON: makeErrorEnvelope(
                code: .invalidArgs,
                message: text,
                details: ["diagnosis": diagnosis.rawValue],
                next: NextHint(
                    suggested_cmd: TN.askSupervisorForm,
                    reason: Self.repairTheFormReason)),
            isError: true
        )
    }

    /// runtime-prompt
    static let repairTheFormReason =
        "Repair the `form` argument and call again — nothing was asked, so the Supervisor is "
            + "not waiting."
}


// MARK: - Decoding diagnostics

/// Renders a decode failure for the MODEL — the throw-site text plus where it happened.
///
/// `error.localizedDescription` collapses every `DecodingError` to "the data couldn't be
/// read", and `debugDescription` alone carries the key only for `keyNotFound`. A form is an
/// array of arrays: without the coding path the model is told a label is too long and has to
/// re-emit the whole questionnaire to find which one.
///
/// The syntax case is worse still, and it is the one that fires in practice. A questionnaire
/// is ~2 KB of JSON the model escapes by hand into a `String` parameter (`JSONSchema` cannot
/// express an array of objects — CLAUDE.md #46), so a single dropped brace is a live event,
/// not a hypothetical: measured 2026-09-10, one of two runs. Foundation answers it with the
/// constant sentence "The given data was not valid JSON.", which tells the model only that
/// something, somewhere, is wrong — and it re-emits all 2 KB, with a fresh chance to slip.
/// The byte offset is right there in the underlying error; quoting the text around it costs
/// nothing and turns a re-write into an edit.
nonisolated enum SupervisorFormDecoding {

    /// How much of the payload to quote around the failure, in CHARACTERS. Enough to see the
    /// structure that broke (a couple of keys either side), short enough that the error
    /// stays an error rather than an echo of the form.
    private static let windowRadius = 60

    /// Whether the text never parsed at all — as opposed to parsing into a shape the
    /// decoder refused. Foundation reports the former as `dataCorrupted` at the root with
    /// its own `NSError` underneath; every validation failure this app throws carries a
    /// coding path and no underlying error. The one discriminator `message` reads, and the
    /// gate on running `SupervisorFormTextRepair`: a repair pass over text that parsed
    /// would rewrite content, not syntax.
    static func isSyntaxFailure(_ error: Error) -> Bool {
        guard case .dataCorrupted(let ctx)? = error as? DecodingError else { return false }
        return ctx.codingPath.isEmpty && ctx.underlyingError != nil
    }

    /// - Parameter source: the JSON text that failed, when the caller has it. Only a SYNTAX
    ///   failure uses it — a validation failure already names its own coding path, and
    ///   quoting bytes at it would point at a place that parsed fine.
    static func message(_ error: Error, in source: String? = nil) -> String {
        guard let decoding = error as? DecodingError else {
            return ToolErrorHandler.classify(error).message
        }
        let ctx: DecodingError.Context
        switch decoding {
        case .dataCorrupted(let c), .keyNotFound(_, let c),
             .typeMismatch(_, let c), .valueNotFound(_, let c):
            ctx = c
        @unknown default:
            return ToolErrorHandler.classify(error).message
        }
        if ctx.codingPath.isEmpty, let source,
           let excerpt = syntaxExcerpt(of: ctx, in: source) {
            // Foundation's own sentence is dropped here: for every syntax failure it is the
            // constant "The given data was not valid JSON.", which the code `INVALID_ARGS`
            // and the caller's "Invalid form:" prefix already say — and leading with it puts
            // two sentences of nothing in front of the one that names the fault (R1.8.1).
            return excerpt
        }
        guard !ctx.codingPath.isEmpty else { return ctx.debugDescription }
        var path = ""
        for key in ctx.codingPath {
            if let index = key.intValue {
                path += "[\(index)]"
            } else if path.isEmpty {
                path += key.stringValue
            } else {
                path += ".\(key.stringValue)"
            }
        }
        return "\(ctx.debugDescription) (at `\(path)`)"
    }

    /// Where the parser stopped, and the text around it.
    ///
    /// `NSJSONSerializationErrorIndex` is a BYTE offset into the data, so the stop is located
    /// on the UTF-8 view — measuring it in Characters would drift on the first non-ASCII
    /// character. The WINDOW around it is cut in Characters, though: cut in bytes it landed
    /// inside a Cyrillic letter, and `String(utf8[…])` — failable — answered nil, so a model
    /// writing Russian got the bare sentence while one writing English got the excerpt
    /// (MeditationApp task 52 run 9, 2026-09-11: three forms of five opened a string with
    /// `«`, and the model guessed "escaping", then "curly quotes"). The character it stopped
    /// on is named from the text, not from Foundation's message, which prints the first BYTE
    /// of a multi-byte character (`'Â'` for `«`).
    ///
    /// "Unexpected end of file" carries no offset at all — the text ended with something
    /// still open — so that arm quotes the tail instead of nothing. An offset at or past the
    /// end would name no character either and takes the same arm; Foundation has not been
    /// seen to report one, and a separate arm for it was two lines no test could reach.
    ///
    /// A quoted excerpt of JSON is full of `"`, so it is delimited by `⟦ ⟧` rather than by
    /// more quotes — the model has to see where the quotation ends — and not by guillemets,
    /// which are the very characters the live run confused with quotes.
    private static func syntaxExcerpt(
        of ctx: DecodingError.Context, in source: String
    ) -> String? {
        guard let underlying = ctx.underlyingError as NSError? else { return nil }
        let utf8 = source.utf8
        guard let offset = underlying.userInfo["NSJSONSerializationErrorIndex"] as? Int,
              offset >= 0, offset < utf8.count
        else {
            return unfinishedNote(in: source)
        }
        // A String index from the UTF-8 view; the String APIs below round it down to the
        // Character it falls in, which is the character the parser choked on. The number the
        // model reads is a CHARACTER count from there — the byte offset is Foundation's unit,
        // not the model's (1276 bytes were 854 characters in the live payload).
        let stop = utf8.index(utf8.startIndex, offsetBy: offset)
        let character = source.distance(from: source.startIndex, to: stop)
        let lower = source.index(stop, offsetBy: -windowRadius, limitedBy: source.startIndex)
            ?? source.startIndex
        let upper = source.index(stop, offsetBy: windowRadius, limitedBy: source.endIndex)
            ?? source.endIndex
        return "The parser stopped at character \(character), on '\(source[stop])' — the text "
            + "around it, ▶ marking the stop: ⟦\(source[lower..<stop])▶\(source[stop..<upper])⟧"
    }

    /// "Unexpected end of file": the text ran out with something still open, and Foundation
    /// carries no offset for it — the fault is not AT a character, it is the absence of the
    /// characters that should have followed.
    ///
    /// runtime-prompt
    ///
    /// Two states, and NEITHER of them is repaired by appending brackets — that is the point.
    /// The one state where appending them is safe, the form's own bracket and nothing else,
    /// never reaches this function: the ladder's fourth rung put it back and the form was
    /// read. What is left is the two ways a form ends UNFINISHED, and for both of them the
    /// recovery is to send it again.
    ///
    /// So each names its own fault and neither names a repair the instrument refused to make
    /// (playbook R1.8.5, CLAUDE.md #293). The first draft of this function did the opposite —
    /// it composed "append `]}`" for exactly the tail `closingTheTopLevelContainer` declines
    /// as laundering, which would have had the model hand the Supervisor, by hand, the
    /// questionnaire the repair exists to refuse: the padded text parses, and
    /// `SupervisorInquiryCompleteness` reads choices only, so a `free_text` question the
    /// model never finished writing disappears without a word.
    ///
    /// Both lead with the fault and the repair, before the excerpt (R1.8.1). The excerpt led
    /// on 2026-09-11 in MeditationApp task 67 run 1, and a run of Cyrillic text quoted ahead
    /// of the diagnosis read AS the diagnosis: the model answered "my JSON string contains a
    /// Russian character … I will use ASCII-safe text", translated a Russian questionnaire
    /// into English, and the single missing `}` stayed missing for another two calls.
    static func unfinishedNote(in source: String) -> String {
        let tail = "The form ends with ⟦\(source.suffix(windowRadius))⟧."
        guard let unclosed = JSONStructuralCloserRepair.unclosed(in: source) else {
            return "The form ran out before it was complete. Send the whole form again. " + tail
        }
        guard unclosed.endsOnCompleteValue else {
            return "The form ends before its last value is finished — what came after it was "
                + "never written. Send the whole form again. " + tail
        }
        return "The form stops with `\(unclosed.closers)` still owed — more than its own "
            + "closing bracket, so a question inside it was never finished. Send the whole "
            + "form again. " + tail
    }
}
