import Foundation

/// What — if anything — to say to the model after a FAILED tool call.
///
/// The sibling rule, from `ScratchpadNotePolicy` next door: an app-authored turn
/// is worth its cost only when it carries something the tool's own envelope does
/// not. There it reads "the app did something OTHER than the call implies"; here,
/// where the call simply failed, it reads **direction the envelope does not give**.
///
/// So this returns a DIRECTION and never a FACT. The fact is the envelope, and the
/// envelope is the immediately preceding turn on the wire — on Ollama it is even
/// merged into the same user message. Restating it buys the model nothing and
/// costs context permanently, which is not free: a stock Ollama window is ~4096
/// and overflow truncates from the HEAD, so waste here is paid for in system
/// prompt.
///
/// Every one of the nine arms used to open with the envelope's `message` verbatim,
/// and three of them added nothing else at all — `plan_required` paraphrased the
/// instruction the envelope had just given, `anchor_ambiguous` and the typed
/// `anchor_not_found` returned the envelope's message byte-for-byte. Those three
/// now return `nil`, and `cancelled` joined them for a different reason: not that
/// the direction restated the fact, but that no direction was TRUE (see its arm).
///
/// The reason recorded for copying — that synthesizing here would misreport
/// `MeetingToolExecutor`'s "in this meeting" scope as a role-level rejection —
/// defended an input that cannot arrive: the meeting executor feeds its rejections
/// into its own turn conversation and never reaches this decision, and the one
/// production caller (`processRegularToolResult`) hard-codes `scope: "for this
/// role"`. The scope distinction is real and still lives where it belongs, in the
/// envelope that the meeting turn does read.
///
/// **One function, where the sibling has two — because only one surface takes the
/// answer.** `ScratchpadNotePolicy` splits wire from feed because its surfaces
/// genuinely disagree about a SUCCESS. A failure has no such split to model: this
/// is steering, the model is its only reader, and the Supervisor reads the reason
/// off the failed call's own record — a tap on the card opens the full envelope in
/// `ActivityDetailWindow.toolCall`. So the call site persists the turn for replay
/// but leaves it unattributed, which is what keeps it out of the feed — see the
/// `feed-invisible-by-design:` note there.
///
/// An earlier version of this paragraph argued the opposite: that the direction is
/// "exactly the fact the tool card cannot carry", so the feed should show it too.
/// The premise is false and worth recording. Every arm that still emits is a
/// CONSTANT keyed on the error code (at most plus the tool name), and both the code
/// and the message ride the card's own result — so the row carried nothing
/// per-incident, and read as the same sentence twice. The arms that once did carry a
/// per-incident fact are precisely the three that now return `nil`. The 2026-08-15
/// sweep that attributed every app-authored `.user` turn was right about its own
/// class — a nudge with no card above it is the only record there is — and this site
/// is the exception it did not distinguish: its motivating case (31 of 40 `edit_file`
/// calls failing, with the Supervisor shown retries and no reasons) is now silent
/// here for a different reason, the typed diagnosis in the envelope.
///
/// That same constant-ness later retired the card's own INLINE reason line, which
/// had shipped in the commit that made this site silent. Putting the message under
/// every red arrow turned a role stuck on one rejection into a column of identical
/// paragraphs: screen space is spent per INCIDENT while the text is per CODE. The
/// reason is one tap away instead of always-on — `ToolCallItemView.resultIndicator`
/// carries that note. None of this file's reasoning moves with it: the argument
/// here is about the WIRE and the context the restatement occupies permanently.
///
/// `nonisolated` because the app target defaults types to `@MainActor`; everything
/// here is value-in/value-out.
nonisolated enum ToolErrorNotePolicy {

    /// The turn to append after `result`, or `nil` to append nothing.
    ///
    /// Reaches the model only. It is persisted with the rest of the conversation so a
    /// replay is not missing it, but carries no `sourceContext` and so never renders —
    /// see the type doc.
    static func direction(for result: ToolExecutionResult) -> String? {
        let dict = JSONUtilities.parseJSONDictionary(result.outputJSON)

        // Two envelope shapes carry the error code in different places:
        // executor-emitted errors store a top-level string ("tool_not_authorized",
        // "identical_write_loop"); ToolErrorHandler-emitted errors store a nested
        // object ({"error":{"code":"INVALID_ARGS",...}}).
        let errorCode: String? = {
            if let topLevel = dict?["error"] as? String { return topLevel }
            if let nested = (dict?["error"] as? [String: Any])?["code"] as? String { return nested }
            return nil
        }()

        // Normalize to lowercase so handler-emitted UPPERCASE codes
        // (`TOOL_NOT_AUTHORIZED`) and executor-emitted lowercase literals
        // (`tool_not_authorized`) reach the same branch.
        switch errorCode?.lowercased() {
        case "tool_not_authorized":
            // Args aren't the cause — the tool isn't in this role's schema, and the
            // generic "retry with correct arguments" suffix is what makes weaker
            // models loop on the same unavailable tool. The envelope already names
            // the tool and says to use only what the prompt lists; the ANTI-LOOP
            // instruction is what it does not say, so that is all this adds.
            let toolName = (dict?["tool"] as? String) ?? result.toolName
            return "Pick a different tool, or proceed without this step; "
                + "do not retry '\(toolName)'."

        case "plan_required":
            // Nothing to add. The only rejection that is temporal rather than
            // structural, and its envelope already states both halves: call
            // `update_scratchpad` with findings and a numbered plan, then call the
            // same tool again. The retired guidance paraphrased exactly that in
            // different words, which reads as a second, different instruction.
            return nil

        case "precondition_failed":
            // Like `tool_not_authorized`, args aren't the cause — the work folder
            // lacks a precondition (no .git, no vision model, no xcode scheme, no
            // opened folder), and the envelope names which one. What it does not
            // say is that retrying cannot help, which is the whole recovery.
            let toolName = (dict?["tool"] as? String) ?? result.toolName
            return "Do not retry '\(toolName)' — the precondition is set by the work folder, "
                + "not by your arguments. Pick a different tool or proceed without this step."

        case "bash_denied":
            // The command was blocked by the bash-permission policy (deny rule,
            // judge rejection, or human approval unavailable). The envelope carries
            // the reason; the block being POLICY rather than arguments — and so
            // immune to a reworded retry — is what it does not.
            //
            // The alternatives stay here rather than moving into the envelopes,
            // because only ONE of the five names any: the no-human arm points at a
            // supervisor-side setting. Deny-rule, Supervisor-denied, judge and mode-Off
            // all stop at the reason, so a model told merely "denied" would have nowhere
            // to go. (That one arm used to spell its own generic alternative on top
            // of this one — the duplication is gone from the envelope, not here.)
            return "Do NOT retry this command — the block is set by policy, not by your "
                + "arguments. Choose a different approach, use a read-only or "
                + "already-approved command, or ask the Supervisor."

        case "cancelled":
            // Nothing to add, and nothing that WOULD be true. The run stopped — the
            // loop this note would be appended to is ending, and on resume the step
            // re-runs and re-issues. Every direction on offer is wrong here: "fix the
            // arguments" (the default arm's, which this code used to fall into) blames
            // a call that was never rejected, and "do not retry" contradicts the resume
            // that re-issues it. The envelope's own sentence — "cancelled by user (run
            // paused or interrupted)" — is the whole fact and needs no steering.
            return nil

        case "identical_write_loop":
            // The args ARE the rejected duplicate, so retrying hits the guard again.
            // The envelope names the file and says the write already ran; the remedy
            // — verify state instead of re-issuing — is what it does not.
            return "Read the file's current state to verify whether the change is needed; "
                + "do not re-issue the same write."

        case "anchor_ambiguous":
            // The envelope's message carries the region count AND the remedy ("include
            // more surrounding lines"), so there is nothing to add. Only a malformed
            // envelope with no message at all needs the remedy synthesized here.
            let nestedMessage = ((dict?["error"] as? [String: Any])?["message"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
            guard nestedMessage == nil else { return nil }
            return "old_text matches multiple regions of the file — include more surrounding "
                + "lines in old_text to pinpoint one."

        case "anchor_not_found":
            let errorObj = dict?["error"] as? [String: Any]
            let details = errorObj?["details"] as? [String: Any]
            let envelopeMessage = (errorObj?["message"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
            // A TYPED diagnosis means the handler located the window (or proved the
            // text absent) and wrote the whole answer into the message. The generic
            // sentence below would then CONTRADICT it — telling a model to match
            // "character for character, including whitespace" is actively wrong for
            // an anchor naming code that does not exist, the majority case in the
            // field — so the envelope stands alone and this adds nothing.
            let typed = (details?["diagnosis"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if typed != nil, envelopeMessage != nil { return nil }

            // The two legacy diagnoses keep the generic sentence, which is NOT a
            // restatement: the envelope's legacy message stops at "matches exactly
            // including whitespace and indentation", while slash direction and the
            // re-read remedy appear only here.
            let argsDict = JSONUtilities.parseJSONDictionary(result.argumentsJSON)
            let path = (argsDict?["path"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
            let target = path.map { "'\($0)'" } ?? "the file"
            var guidance = "old_text not found in \(target). It must match the file's current content exactly, character for character — including whitespace, indentation, and slash direction (`/` vs `\\`). If you edited this file after reading it, your copy is stale — re-read the region first. Otherwise compare your old_text against the content you read and fix the transcription."
            // `hint` is appended ONLY when no envelope message carried it. The legacy
            // shape composes its message as `anchorNotFoundMessage + " " + hint`
            // (`FileWriteHandlers`), so restating it here put the same sentence on the
            // wire twice — the defect this type exists to remove, in miniature.
            if envelopeMessage == nil,
               let hint = (details?["hint"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) {
                guidance += " " + hint
            }
            return guidance

        default:
            let errorObj = dict?["error"] as? [String: Any]
            // Surface the typed code (when present) so the LLM can disambiguate
            // recovery — e.g. `DELEGATION_DENIED` (don't retry) vs
            // `DELEGATION_TIMED_OUT` (maybe retry later) vs `INVALID_ARGS`
            // (fix args). The code is a DISCRIMINATOR the direction below is chosen
            // by, not a restatement of the message; only handler-shape envelopes
            // carry it, and the legacy `{message:…}` shape gets no prefix to avoid
            // `[]` artifacts.
            let code = errorObj?["code"] as? String
            let codePrefix = code.map { "[\($0)] " } ?? ""
            // The recovery direction must match the code family. The pre-fix
            // fixed suffix always blamed arguments — actively misleading weaker
            // models on timeouts/denials where arguments are not the cause.
            let direction: String
            switch code {
            case "INVALID_ARGS":
                // Name the WHOLE contract, not just the first key that tripped. Handlers
                // throw on the first missing argument they read, so a call short three
                // arguments costs three round-trips of "Missing required argument: X" —
                // and the model is never told which of the ones it DID send arrived. The
                // schema is the authority; `result.argumentsJSON` is what actually landed.
                direction = "Fix the arguments and retry."
                    + Self.requiredArgumentsHint(
                        toolName: result.toolName, argumentsJSON: result.argumentsJSON)
            case let c? where c.hasSuffix("_TIMED_OUT") || c == "TIMEOUT":
                direction = "This may be transient — retry once; if it fails again, choose a different approach."
            case let c? where c.hasSuffix("_DENIED") || c == "tool_not_authorized":
                direction = "Do not retry this call — choose a different approach."
            default:
                direction = "If the message indicates bad arguments, fix them and retry; otherwise choose a different approach."
            }
            return "Tool '\(result.toolName)': \(codePrefix)\(direction)"
        }
    }

    /// " `edit_file` requires: new_text, old_text, path. Your call carried: new_text."
    /// — or "" when the tool has no schema here, or declares nothing required.
    ///
    /// A runtime failure envelope, not schema text: it ships once, on the call that
    /// already failed, so the instruction budget that keeps `ToolSchema.description`
    /// lean does not apply. What it buys is the difference between one corrective
    /// round-trip and one per missing argument.
    static func requiredArgumentsHint(
        toolName: String, argumentsJSON: String
    ) -> String {
        // `nil` and `[]` mean the same thing here — a tool that declares nothing required —
        // and one guard says so. The pair `?? []` + `!isEmpty` left an autoclosure no test
        // could reach: `JSONSchema.object` defaults `required` to `nil`, but every schema in
        // the registry passes a list or omits the argument on an object with no properties,
        // so the nil arm is unreachable through `allSchemas` while being indistinguishable
        // from the empty one on the very next line.
        guard let schema = ToolHandlerRegistry.allSchemas.first(where: { $0.name == toolName }),
              let required = schema.parameters.required,
              !required.isEmpty
        else { return "" }

        var hint = " `\(toolName)` requires: \(required.sorted().joined(separator: ", "))."
        if let carried = JSONUtilities.parseJSONDictionary(argumentsJSON), !carried.isEmpty {
            hint += " Your call carried: \(carried.keys.sorted().joined(separator: ", "))."
        } else {
            hint += " Your call carried no arguments."
        }
        return hint
    }
}
