import Foundation

/// Recovers a tool call from a reply that carries NO Harmony sentinel at all.
///
/// Every parsing strategy in `HarmonyToolCallParser` is hard-gated on a literal
/// `<|call|>` / `<|start|>` / `<|channel|>`, which is correct — a marker is the model's
/// commitment signal, and without one an object that merely *looks* like a call could be
/// something the model was writing ABOUT. But that leaves a gap the runtime cannot talk
/// its way out of: a model that expresses the call in the exact payload shape the system
/// prompt documents, minus the sentinels, is told "you replied with text but did not call
/// a tool" — i.e. instructed to do the thing it just did. Observed in production
/// (`openai/gpt-oss-20b`): a review pass tried three times to end itself with
/// `wait_for_events` and could not, because the three shapes it reached for were
/// `{"name":"wait_for_events","arguments":{}}`, the bare identifier, and an empty-bodied
/// channel envelope.
///
/// This is the LAST resort: it runs only when the accumulator, the Harmony buffer and the
/// reasoning-channel fallback have all produced nothing, and only on the CONTENT channel
/// (never on reasoning — see the asymmetry note below). Because there is no marker to
/// establish intent, the guards below stand in for one: **the permissiveness of shape
/// recognition scales with the strength of the intent signal.** Inside an envelope,
/// `ToolCallShapeRecognizer` may infer a tool from an argument signature or promote a flat
/// payload; here nothing is inferred.
nonisolated enum BareToolCallSalvage {

    /// Tools a BARE IDENTIFIER may invoke. An explicit allowlist, never a property of the
    /// schema — "zero required parameters" admits eleven tools, among them `git_pull`
    /// (a network mutation that can create a merge commit) and both Xcode runners. Worse,
    /// `ToolRegistry.resolveToolName` maps the ordinary English words `test` and `build`
    /// onto `run_xcodetests` / `run_xcodebuild`, so a chat role replying with the single
    /// word "test" would launch a build. The alias map is legitimate INSIDE an envelope,
    /// where intent is established; on a bare word it is exactly the over-reach.
    ///
    /// `wait_for_events` earns its place on an argument no other tool can make: it is the
    /// only way an Autovisor review pass can terminate, and the manager has no
    /// `ask_supervisor` to fall back on, so a missed emission is not one wasted turn — it
    /// is a pass that cannot end. Every addition needs a written side-effect-free
    /// justification.
    static let zeroArgumentAllowlist: Set<String> = [ToolNames.waitForEvents]

    /// Keys that may carry the tool identity. Deliberately explicit: an inferred name is
    /// exactly what this route must not accept.
    private static let nameKeys = ["name", "tool_name", "tool", "function_name"]

    /// Keys that may carry the arguments object.
    private static let argumentKeys = ["arguments", "args", "parameters", "params"]

    /// - Parameter text: the assistant's CONTENT for this turn — never its reasoning.
    ///   Route 3 accepts Harmony envelopes out of `thinkingCollected`, and the asymmetry
    ///   is principled rather than an oversight: a `<|…|>` marker IS the commitment
    ///   signal, so it means the same thing wherever it appears, whereas bare JSON in the
    ///   reasoning channel is a model *considering* a call.
    /// - Parameter advertised: the schemas actually sent this iteration. Used only by
    ///   Rule B, to confirm the role really holds the tool.
    ///
    /// Rule A is tried first: a reply that satisfies both is a JSON object. (Nothing can,
    /// in fact — A needs a leading `{` and B a bare identifier — but the order states the
    /// precedence rather than relying on that.)
    static func salvage(from text: String, advertised: [ToolSchema]) -> StepToolCall? {
        let cleaned = unwrappingFence(
            ModelTokenCleaner.clean(text).trimmingCharacters(in: .whitespacesAndNewlines))
        guard !cleaned.isEmpty else { return nil }
        return jsonEnvelopeCall(in: cleaned)
            ?? bareIdentifierCall(in: cleaned, advertised: advertised)
    }

    /// True when `text` is a tool-call payload the runtime failed to dispatch — the whole
    /// reply is one JSON object naming a real tool.
    ///
    /// Separate from `salvage` on purpose: this answers "was that an ATTEMPT?", which has
    /// callers that must not dispatch anything. The planning phase is the motivating one —
    /// its prose fallback records the turn as the step's durable plan, and a failed call
    /// recorded there survives the phase boundary as the only memory of the exploration
    /// (observed 2026-08-07: a step's `scratchpad` became
    /// `{"name":"list_files","arguments":{"path":"MeditationApp"}}|`, so the implementation
    /// phase began with no plan and the role never ran the build its contract demanded).
    ///
    /// Rule A with the tail requirement relaxed — the point is recognition, not dispatch,
    /// so trailing prose or sentinel wreckage must not make an attempt unrecognisable.
    ///
    /// The rest of the chain is Rule A's, EXACTLY, by running Rule A: the two must not be
    /// able to disagree about what counts as an attempt. Every future tightening (a new
    /// reserved name, a different resolver, an added shape rejection) then applies to both
    /// at once — a divergence here would either make the planning nudge fire for payloads
    /// route 4 dispatches, or leave a dispatched call unrecognised as an attempt.
    static func looksLikeToolCallAttempt(_ text: String) -> Bool {
        let cleaned = unwrappingFence(
            ModelTokenCleaner.clean(text).trimmingCharacters(in: .whitespacesAndNewlines))
        guard !cleaned.isEmpty else { return false }
        return jsonEnvelopeCall(in: cleaned, requireCleanTail: false) != nil
    }

    // MARK: - Rule A — the whole reply is one JSON object

    /// - Parameter requireCleanTail: whether everything after the object must be
    ///   whitespace or sentinel debris. `true` for dispatch (see `isSentinelDebris`);
    ///   `false` only for `looksLikeToolCallAttempt`, which dispatches nothing.
    private static func jsonEnvelopeCall(
        in cleaned: String, requireCleanTail: Bool = true
    ) -> StepToolCall? {
        // The object must span the ENTIRE reply. Prose around a JSON object means the
        // model was writing about a call, not making one — and this is deliberately not
        // `TeamConfigParser.extractJSONObject`, which SCANS for the first object anywhere
        // in the text and fabricates closing braces for a truncated one. Both behaviours
        // are right for "the model returned its config as prose" and wrong here.
        guard cleaned.hasPrefix("{"),
              let (jsonText, end) = ToolCallParsingHelpers.extractJSONBracedValue(
                  in: Substring(cleaned), from: cleaned.startIndex),
              !requireCleanTail || isSentinelDebris(cleaned[end...])
        else { return nil }

        // STRICT parse only. The repair chain (`parseAfterRepair`, control-character
        // re-escaping) exists to rescue bytes whose intent a `<|call|>` already
        // established. With no marker the intent is precisely what is in question, and
        // repairing unframed prose is how a quoted JSON snippet becomes a dispatch.
        guard let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any]
        else { return nil }

        guard let rawName = explicitToolName(in: dict) else { return nil }
        guard !ToolCallParsingHelpers.reservedChannelNames.contains(rawName.lowercased())
        else { return nil }

        // Registry membership, NOT the role's allowed set. A real tool the role happens to
        // lack is promoted on purpose, so `executeToolCalls` answers `tool_not_authorized`
        // + "do not retry 'X'" — strictly more actionable than a silent parse-layer drop,
        // and the only way the planning phase's "withheld, try later" contract can be
        // reached at all. Legal only because an all-rejected batch no longer re-arms the
        // no-tool ceiling (`ToolTurnProductivity`).
        //
        // A name outside the registry resolves to nothing and falls through to the nudge:
        // without a marker there is no evidence this object was a call attempt, and
        // `{"name":"my-app","version":"1.0"}` is an ordinary thing to paste into a chat.
        let resolved = ToolRegistry.resolveToolName(rawName)
        guard ToolNames.allNames.contains(resolved) else { return nil }

        return StepToolCall(
            providerID: nil, name: resolved, argumentsJSON: arguments(in: dict))
    }

    /// Whether everything after the object is whitespace or the wreckage of a sentinel
    /// the token cleaner half-removed.
    ///
    /// The rule that the object must span the ENTIRE reply is what keeps Rule A safe —
    /// prose around a JSON object means the model was writing ABOUT a call. But
    /// `allSatisfy(\.isWhitespace)` is a stricter tail test than the parser it backstops:
    /// `gemma-4-e4b` appends a stray `|` after the closing brace in 9 of 30 envelopes,
    /// and a single one of those bytes was the entire reason one call was dropped.
    /// These characters cannot form a sentence the way a trailing clause can, so
    /// admitting them costs none of the contract.
    private static func isSentinelDebris(_ tail: Substring) -> Bool {
        tail.allSatisfy { $0.isWhitespace || "|></".contains($0) }
    }

    /// The tool identity, read from an explicit top-level key only.
    ///
    /// `ToolCallShapeRecognizer.resolve` is deliberately NOT used here despite being the
    /// house name-shape mapper: two of its branches infer. `inferToolNameFromShape` reads
    /// a name out of an argument signature, and the flat-`create_artifact` branch maps any
    /// `{"name":X,"content":Y}` whose `X` is not a known tool onto an artifact write —
    /// `{name, content}` being the canonical shape of a document record. On unframed prose
    /// that would let a chat reply persist an artifact, and `resolveArtifactName`'s prefix
    /// matching could then let `checkArtifactCompleteness` finish the step with a fragment
    /// as the deliverable. Both branches stay live for marker-bearing envelopes, where the
    /// marker is the commitment they assume.
    private static func explicitToolName(in dict: [String: Any]) -> String? {
        for key in nameKeys {
            if let value = ToolCallParsingHelpers.stringValue(dict[key]),
               !value.trimmingCharacters(in: .whitespaces).isEmpty
            {
                return value
            }
        }
        if let function = dict["function"] as? [String: Any],
           let value = ToolCallParsingHelpers.stringValue(function["name"]),
           !value.trimmingCharacters(in: .whitespaces).isEmpty
        {
            return value
        }
        return nil
    }

    /// The arguments object, or `{}`.
    ///
    /// Never `""`: an empty string makes `canonicalToolCallSignature` fall back to a raw
    /// string compare, so the same call expressed two ways stops counting as identical and
    /// a model alternating shapes slips past the repeated-tool-call loop detector — which
    /// is the very loop this salvage exists to end.
    private static func arguments(in dict: [String: Any]) -> String {
        for key in argumentKeys {
            guard let value = dict[key] else { continue }
            if let nested = value as? [String: Any] {
                return ToolCallParsingHelpers.stableJSONString(from: nested) ?? "{}"
            }
            // Some providers serialize `arguments` as a JSON STRING.
            if let text = value as? String {
                let normalized = ToolCallParsingHelpers.normalizeArgumentsJSONString(text)
                return normalized.isEmpty ? "{}" : normalized
            }
        }
        return "{}"
    }

    // MARK: - Rule B — the whole reply is one bare tool identifier

    private static func bareIdentifierCall(
        in cleaned: String, advertised: [ToolSchema]
    ) -> StepToolCall? {
        // A single snake_case identifier and nothing else. No backtick stripping and no
        // trailing-punctuation stripping: `` `search` `` and "Search." are the model
        // TALKING about a tool, not calling one.
        guard isBareToolIdentifier(cleaned) else { return nil }
        guard zeroArgumentAllowlist.contains(cleaned) else { return nil }
        guard advertised.contains(where: { $0.name == cleaned }) else { return nil }
        return StepToolCall(providerID: nil, name: cleaned, argumentsJSON: "{}")
    }

    /// `^[a-z][a-z0-9_]{2,39}$`, hand-rolled to keep this type free of NSRegularExpression.
    static func isBareToolIdentifier(_ text: String) -> Bool {
        guard (3...40).contains(text.count) else { return false }
        guard let first = text.first, first.isLowercaseASCIILetter else { return false }
        return text.allSatisfy {
            $0.isLowercaseASCIILetter || ("0"..."9").contains($0) || $0 == "_"
        }
    }

    // MARK: - Fences

    /// Removes at most ONE surrounding ``` fence, with or without a language tag. More
    /// than one, or an unterminated fence, is left alone — a reply that elaborate is prose.
    private static func unwrappingFence(_ text: String) -> String {
        guard text.hasPrefix("```"), text.hasSuffix("```"), text.count > 6 else { return text }
        var body = Substring(text).dropFirst(3).dropLast(3)
        // Drop a language tag on the opening line (```json).
        if let newline = body.firstIndex(of: "\n") {
            let tag = body[..<newline]
            if tag.allSatisfy({ $0.isLetter }) {
                body = body[body.index(after: newline)...]
            }
        }
        let inner = body.trimmingCharacters(in: .whitespacesAndNewlines)
        // A fenced block containing a further fence is prose about code.
        return inner.contains("```") ? text : inner
    }
}

nonisolated private extension Character {
    var isLowercaseASCIILetter: Bool { ("a"..."z").contains(self) }
}
