import Foundation

/// Shared, hardened parser for an LLM safety-judge reply. Both `BashJudgeService` and
/// `ComputerUseJudgeService` route through this so the two gates cannot drift apart on the
/// security-critical parsing (a naive `lastIndex('{')` / `firstIndex('}')` scan can flip a
/// DENY into an OK when the reply carries an illustrative second object — fail-open).
///
/// The contract is deliberately narrow and **fail-closed**: ALLOW requires the reply to be
/// exactly ONE clean JSON object with exactly one TOP-LEVEL `decision` key whose decoded value
/// is the ASCII word "OK". Anything else — prose, text around the object, multiple objects, a
/// duplicate `decision` key (including a `\u`-escaped one), a non-OK decision, a malformed
/// object, or no object — resolves to a non-allow outcome. Each caller maps the outcome to its
/// own `Decision` type with its own default reason strings.
/// Shared config builder for the judge pair — the config half of the same
/// no-drift contract `JudgeVerdictParser` provides for parsing. Both judges
/// resolve their effective LLMConfig here so override semantics (whitespace
/// trimming) cannot diverge.
nonisolated enum JudgeConfig {

    /// Applies the dedicated judge override (URL + model) over the base
    /// config — WITHOUT the verdict temperature pin. This is the variant for
    /// generative consumers that only want the judge's model targeting
    /// (e.g. the Ask-AI advisory in `BashExplainService`).
    /// The bearer token is resolved from the Keychain by URL at request time
    /// (never carried here).
    static func applying(_ override: LLMOverride?, to base: LLMConfig) -> LLMConfig {
        var config = base
        guard let o = override else { return config }
        if let url = o.baseURLString?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
            config.baseURLString = url
        }
        if let model = o.modelName?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            config.modelName = model
        }
        // Same resolution as `buildEffectiveConfig`: the override's provider
        // wins when set (its URL may point at a different provider's server),
        // else the base provider flows through.
        if let provider = o.provider {
            config.provider = provider
        }
        return config
    }

    /// The verdict-call config: temperature pinned to 0 (the verdict is one
    /// strict JSON object, not generative text — an inherited chat/creative
    /// temperature has no business injecting variance into a security
    /// decision). This is the ONLY production writer of
    /// `LLMConfig.temperature` — user-facing generation settings were removed
    /// (LM Studio's per-model config governs sampling).
    static func forVerdict(_ base: LLMConfig, override: LLMOverride?) -> LLMConfig {
        var pinned = base
        pinned.temperature = 0
        return applying(override, to: pinned)
    }
}

/// Which channel a gate verdict may be taken from (playbook R2.3.6; decided 2026-09-07).
///
/// The content channel is the verdict. The reasoning channel is deliberation the model was
/// not trained to the same safety standard on — so a `DENY` found only there is honoured
/// (fail-closed either way), while an `OK` found only there is NOT a decision: the judge
/// asks once more for the object in its visible reply, and denies if that reply is empty
/// again. Until 2026-09-07 both judges promoted the reasoning channel symmetrically, so a
/// reasoning model could mint an allow from the channel the prompt tells it to keep private.
nonisolated enum JudgeReplyChannelPolicy {
    enum Resolution: Equatable {
        /// Parse this text as the verdict (the content channel, or a reasoning-only deny /
        /// non-verdict — every non-`OK` outcome denies).
        case verdict(String)
        /// The reasoning channel says `OK` and the content channel is empty — not a verdict.
        /// The judge asks once more for a visible object and denies when that reply is the
        /// same; the attempt budget is the judge's (`for attempt in 0..<2`), not this
        /// policy's. Until 2026-09-07 the policy counted the attempts itself, which left
        /// every judge a post-loop deny nothing could reach.
        case reasoningOnlyAllow
    }

    /// The one instruction the retry turn carries.
    static let retryInstruction =
        "Reply now with the JSON object only, in your visible reply — a decision written inside reasoning does not count."

    static func resolve(content: String, reasoning: String, prepare: (String) -> String) -> Resolution {
        let visible = prepare(content)
        if !visible.isEmpty { return .verdict(visible) }
        let hidden = prepare(reasoning)
        guard !hidden.isEmpty else { return .verdict("") }
        if case .allow = JudgeVerdictParser.evaluate(hidden) { return .reasoningOnlyAllow }
        return .verdict(hidden)
    }

    static let reasoningOnlyAllowReason =
        "The judge allowed only inside its reasoning channel, which is not a verdict; denied for safety."
}

/// The deny reasons the RUNTIME writes when the judge produced no usable verdict — a
/// transport failure, an unparseable reply, or an allow that stayed in the reasoning
/// channel. Distinct from a deny the MODEL made: that one carries the model's own `reason`
/// (or `Denied by …` when it gave none).
///
/// They live here, beside the parser both gates share, because two readers need the same
/// list and a copy would drift: the two services write them, and the one-shot prompt
/// trainer must not read one as "the judge refused a dangerous command" — a fail-closed
/// deny on a deny-worthy input measures the transport, not the prompt (2026-09-08).
nonisolated enum JudgeFailClosedReason {
    // `BashJudgeService.parse`
    static let bashNoVerdict = "Judge returned no verdict; denied for safety."
    static let bashNotSingleObject = "Judge did not return a single clean verdict object; denied for safety."
    static let bashConflicting = "Judge returned a conflicting verdict; denied for safety."
    static let bashMalformed = "Judge verdict was malformed; denied for safety."
    // `ComputerUseJudgeService.parse`
    static let actionNoVerdict = "Judge returned no verdict; denied."
    static let actionUnparseable = "Could not parse the judge's verdict; denied."

    /// A transport / client failure, the classified message interpolated.
    /// `subject` is `"Command"` for the bash gate, `"Action"` for computer use.
    static func callFailed(subject: String, message: String) -> String {
        "\(subject) judge call failed (\(message)); denied for safety."
    }

    private static let fixed: Set<String> = [
        bashNoVerdict, bashNotSingleObject, bashConflicting, bashMalformed,
        actionNoVerdict, actionUnparseable,
    ]
    private static let callFailedPrefixes = ["Command judge call failed (", "Action judge call failed ("]

    /// True when the deny came from the runtime rather than from the model's verdict.
    static func isFailClosed(_ reason: String) -> Bool {
        if fixed.contains(reason) { return true }
        if reason == JudgeReplyChannelPolicy.reasoningOnlyAllowReason { return true }
        return callFailedPrefixes.contains { reason.hasPrefix($0) }
    }
}

nonisolated enum JudgeVerdictParser {

    /// The outcome of parsing a judge reply. `allow`/`deny` carry the object's `reason` field
    /// (may be nil); the remaining cases describe *why* the reply is not a clean verdict so the
    /// caller can surface an accurate deny reason.
    enum Outcome: Hashable {
        case allow(reason: String?)
        case deny(reason: String?)
        case noVerdict          // empty reply
        case notSingleObject    // prose / trailing text / multiple objects / not an object
        case conflicting        // >1 top-level `decision` key (self-contradiction)
        case malformed          // scanned object failed JSON decode
    }

    /// The ONLY `decision` value that allows, compared case-insensitively against the trimmed,
    /// ASCII-only field value. Every other value denies.
    private static let allowToken = "ok"

    /// Parses `text` (already stream-cleaned by the caller). Trims with `whitespaceTrimmed`
    /// internally, so a double-trim by the caller is harmless.
    static func evaluate(_ text: String) -> Outcome {
        let trimmed = whitespaceTrimmed(text)
        guard !trimmed.isEmpty else { return .noVerdict }
        guard let scanned = scanSoleObject(trimmed) else { return .notSingleObject }
        guard scanned.decisionKeyCount <= 1 else { return .conflicting }
        guard let data = scanned.json.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(JudgeResponse.self, from: data) else {
            return .malformed
        }
        // The allow token must be plain ASCII "OK". A non-ASCII look-alike (e.g. the Kelvin
        // sign U+212A, which lowercases to "k") is not the word OK → deny.
        let decision = whitespaceTrimmed(parsed.decision ?? "")
        if decision.allSatisfy(\.isASCII), decision.lowercased() == allowToken {
            return .allow(reason: parsed.reason)
        }
        return .deny(reason: parsed.reason)
    }

    /// Trims leading/trailing Unicode White_Space using `Character.isWhitespace` — the SAME
    /// predicate `scanSoleObject`'s trailing-junk check uses — so the reply's edges and its
    /// interior agree on what counts as whitespace. Foundation's `.whitespacesAndNewlines`
    /// diverges (it also strips U+200B), which would let an invisible char pad the verdict and
    /// slip past the "no surrounding text" property. Callers should stream-clean with THIS.
    static func whitespaceTrimmed(_ s: String) -> String {
        let noLeading = s.drop(while: \.isWhitespace)
        return String(noLeading.reversed().drop(while: \.isWhitespace).reversed())
    }

    /// One balanced JSON object plus its top-level `decision`-key count.
    nonisolated struct ScannedObject: Hashable {
        let json: String
        let decisionKeyCount: Int
    }

    /// A SINGLE string/escape-aware pass that both (a) verifies the reply (after stripping one
    /// optional surrounding fence) is exactly ONE balanced JSON object with only whitespace
    /// around it, and (b) counts how many of its TOP-LEVEL keys decode to `decision`. Returns
    /// nil for prose, leading/trailing text, or multiple objects — nothing that merely
    /// *contains* an object passes.
    ///
    /// A top-level key is a string at object-depth 1 immediately followed (past whitespace) by
    /// `:`. The depth-1 + followed-by-`:` test excludes nested-object keys (depth ≥ 2) and array
    /// elements / string values, so a `decision` inside a value never counts. Keys are
    /// JSON-unescaped before comparison, so `"decision"` counts as `decision`.
    ///
    /// Deliberately NOT a salvaging parser: an unbalanced or padded reply is uncertainty and
    /// must fail closed, and escapes are standard-JSON (string-interior only).
    static func scanSoleObject(_ raw: String) -> ScannedObject? {
        let s = stripSurroundingFence(raw)
        let chars = Array(s)
        guard chars.first == "{" else { return nil }
        var depth = 0
        var inString = false
        var isEscaped = false
        var stringStart: Int?       // content start: index after the opening quote
        var decisionKeys = 0
        var end: Int?
        loop: for i in chars.indices {
            let c = chars[i]
            if isEscaped { isEscaped = false; continue }
            if inString {
                if c == "\\" {
                    isEscaped = true
                } else if c == "\"" {
                    if depth == 1, let start = stringStart, isKeyPosition(chars, afterCloseAt: i),
                       decodeJSONStringBody(String(chars[start..<i])) == "decision" {
                        decisionKeys += 1
                    }
                    inString = false
                    stringStart = nil
                }
                continue
            }
            switch c {
            case "\"": inString = true; stringStart = i + 1
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { end = i; break loop }
            default: break
            }
        }
        guard let end else { return nil }                                       // unbalanced
        guard chars[(end + 1)...].allSatisfy(\.isWhitespace) else { return nil } // trailing junk / second object
        return ScannedObject(json: String(chars[0...end]), decisionKeyCount: decisionKeys)
    }

    /// True iff the next non-whitespace character after a closed string (at `i`, the closing
    /// quote) is `:` — i.e. the string was a key, not a value.
    private static func isKeyPosition(_ chars: [Character], afterCloseAt i: Int) -> Bool {
        var j = i + 1
        while j < chars.count, chars[j].isWhitespace { j += 1 }
        return j < chars.count && chars[j] == ":"
    }

    /// JSON-unescapes the body of a string literal by re-wrapping and decoding, so `decision`
    /// → `decision`. Falls back to the raw body if decoding fails (used only for key identity).
    private static func decodeJSONStringBody(_ body: String) -> String {
        guard let data = "\"\(body)\"".data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data) else { return body }
        return decoded
    }

    /// Strips a single surrounding ```/```json fence when the WHOLE reply is one fenced block
    /// (a tolerated convenience). Only fires when the reply both starts and ends with a fence.
    private static func stripSurroundingFence(_ s: String) -> String {
        guard s.hasPrefix("```"), s.hasSuffix("```"),
              let firstNL = s.firstIndex(of: "\n") else { return s }
        var inner = String(s[s.index(after: firstNL)...])
        if let close = inner.range(of: "```", options: .backwards) {
            inner = String(inner[..<close.lowerBound])
        }
        return whitespaceTrimmed(inner)
    }

    private struct JudgeResponse: Decodable {
        let decision: String?
        let reason: String?
    }

    #if DEBUG
    /// Test seam: top-level `decision`-key count for a reply (nil if it isn't a single clean
    /// object). Proves the conflict guard counts both keys of an escaped duplicate rather than
    /// relying on JSONDecoder's platform-dependent duplicate-key resolution.
    static func _testDecisionKeyCount(_ text: String) -> Int? {
        scanSoleObject(whitespaceTrimmed(text))?.decisionKeyCount
    }
    #endif
}
