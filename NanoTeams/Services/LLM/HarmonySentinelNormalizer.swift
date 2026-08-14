import Foundation

/// Canonicalises a mangled OPENING Harmony sentinel so the rest of the pipeline can
/// see the call the model actually made.
///
/// Every strategy in `HarmonyToolCallParser` is hard-gated on a literal `<|call|>` /
/// `<|start|>` / `<|channel|>`, and `LLMExecutionService+Streaming` decides
/// `sawHarmonyMarker` by exact substring against the same three. That is the right
/// contract — a marker is the model's commitment signal — but it assumes sentinel
/// corruption is confined to the TAIL. `google/gemma-4-e4b` refutes that: measured over
/// one recorded session (30 envelope-bearing replies, `MeditationApp/.nanoteams`,
/// 2026-08-07) it corrupted the OPENING sentinel in 2 of them, and both calls were
/// dropped in silence — one of them reaching the user as a raw-JSON chat bubble.
///
/// The corruption is not noise. Both observed forms splice the model's own
/// training-data sentinel (`<|tool_call|>`) into the `<|call|>` the system prompt
/// teaches:
///
///     <|tool_call>call|>{"name":"list_files",…}      record [33], 13:51:15
///     <|tool_call>call_multiple{"contributions":…}   record [39], 13:52:24
///
/// so it is predictable, and normalising it is cheaper and more honest than teaching
/// the model a format it half-knows.
///
/// **Scope: opening sentinels only.** Closing-marker defects (a stray `|` before
/// `<|end|>`, `</|end|>`, a missing `<|end|>` entirely) already cost nothing — the
/// brace walker in `ToolCallParsingHelpers.extractJSONBracedValue` stops at the first
/// depth-0 close and never consults the terminator.
///
/// **Normalising is not accepting.** Canonicalising the sentinel only lets the payload
/// reach the parser; whether it resolves is still the parser's call. Record [39] carries
/// an invented batch schema (`{"contributions":[{"toolName":…}]}`) with no top-level
/// `name` AND mismatched closers, so it resolves to nothing — correctly, since a batch
/// envelope contradicts the one-tool-per-response rule `AppDefaults.globalContext` calls
/// load-bearing. What it gains is a NAMED failure (`.malformedJSON` for that record):
/// `classifyHarmonyCallIssue` sits behind `sawHarmonyMarker`, so before this it could not
/// run at all, and the model's only feedback was an artifact nudge for an attempt the
/// harness had eaten.
nonisolated enum HarmonySentinelNormalizer {

    /// The alien sentinel's stable prefix. Deliberately not a full token: the observed
    /// `<|tool_call>call_multiple` carries no closing `|>` whatsoever.
    private static let alienPrefix = "<|tool_call"

    /// Longest run of debris tolerated between `alienPrefix` and the payload's `{`.
    /// The two observed runs are `>call|>` (7) and `>call_multiple` (14). The cap is
    /// what keeps this a sentinel repair rather than a scan that could swallow prose
    /// on its way to an unrelated brace.
    private static let maxDebrisRun = 20

    /// Rewrites every mangled opening sentinel to `<|call|>`, leaving everything else
    /// byte-identical.
    ///
    /// A match requires all three, and each one is load-bearing:
    ///  1. the literal `<|tool_call` — an ordinary `tool_call` in prose has no `<|`;
    ///  2. a debris run under `maxDebrisRun` chars containing NO whitespace or newline —
    ///     a sentinel is one token, so any gap means the model was writing prose;
    ///  3. a `{` immediately after it — the payload. Without this requirement a model
    ///     *discussing* `<|tool_call|>` would have its sentence promoted to a call, which
    ///     is precisely the inference `BareToolCallSalvage` refuses to make. The rule
    ///     there applies here too: the permissiveness of shape recognition scales with
    ///     the strength of the intent signal, and a bare mangled token is not one.
    static func normalize(_ text: String) -> String {
        // Two read-only fast paths, in ascending cost, before anything is allocated. This
        // runs on the WHOLE accumulated buffer on every content delta until a marker is
        // found, so an unconditional rebuild is quadratic in the reply length — and the
        // case that reaches it is not exotic: a partially-arrived sentinel is unmatched for
        // a few deltas, and a model writing prose about `<|tool_call` is unmatched for the
        // rest of the response.
        guard text.contains(alienPrefix), hasNormalizableOccurrence(in: text) else {
            return text
        }

        var result = ""
        result.reserveCapacity(text.count)
        var cursor = text.startIndex

        while let hit = text.range(of: alienPrefix, range: cursor..<text.endIndex) {
            result.append(contentsOf: text[cursor..<hit.lowerBound])

            if let payload = payloadStart(in: text, after: hit.upperBound) {
                result.append(HarmonyToolCallParser.callMarker)
                // The debris run can CARRY the call's identity: `gemma-4-26b-a4b-qat`
                // writes `<|tool_call>call:edit_file{…}` (network_log.json, 2026-08-13),
                // and replacing the run wholesale took `edit_file` with it — leaving a
                // nameless payload that resolves to nothing and is dropped in silence.
                // Re-emitting the identifier lands on `CallMarkerStrategy`'s existing
                // `<|call|>tool_name{…}` branch, so this costs no new parsing machinery.
                if let name = trailingToolName(in: text[hit.upperBound..<payload]) {
                    result.append(name)
                }
                cursor = payload
            } else {
                // Not a call attempt — emit the token verbatim and keep scanning after
                // it, so a later genuine occurrence in the same buffer still normalises.
                result.append(contentsOf: text[hit.lowerBound..<hit.upperBound])
                cursor = hit.upperBound
            }
        }

        result.append(contentsOf: text[cursor...])
        return result
    }

    /// Whether at least one occurrence would actually be rewritten. Allocation-free, and
    /// bounded per occurrence by `maxDebrisRun`, so the no-op case stays a pure scan.
    private static func hasNormalizableOccurrence(in text: String) -> Bool {
        var cursor = text.startIndex
        while let hit = text.range(of: alienPrefix, range: cursor..<text.endIndex) {
            if payloadStart(in: text, after: hit.upperBound) != nil { return true }
            cursor = hit.upperBound
        }
        return false
    }

    /// The debris run's trailing identifier, but ONLY when it names a real tool.
    ///
    /// The gate is `ToolNames.allNames`, and it is the whole safety argument: this
    /// recovers a name the model wrote, it never infers one. `>call|>` ends in `>` and
    /// yields nothing; `call_multiple` yields an identifier that is not a tool; both
    /// therefore keep producing the bare marker they produced before, which is what
    /// their pins assert. Matching is exact — a shouted `EDIT_FILE` is not a tool, and
    /// case-folding here would be inference by another name.
    private static func trailingToolName(in debris: Substring) -> String? {
        var start = debris.endIndex
        while start > debris.startIndex {
            let previous = debris.index(before: start)
            let character = debris[previous]
            guard character.isLetter || character.isNumber || character == "_" else { break }
            start = previous
        }
        let candidate = String(debris[start...])
        guard !candidate.isEmpty, ToolNames.allNames.contains(candidate) else { return nil }
        return candidate
    }

    /// Index of the payload's opening `{`, or `nil` when the debris run disqualifies the
    /// match (too long, or interrupted by whitespace).
    private static func payloadStart(in text: String, after start: String.Index) -> String.Index? {
        var index = start
        var scanned = 0
        while index < text.endIndex, scanned < maxDebrisRun {
            let character = text[index]
            if character == "{" { return index }
            if character.isWhitespace || character.isNewline { return nil }
            index = text.index(after: index)
            scanned += 1
        }
        // Ran out of buffer or blew the cap. Mid-stream this can be a payload that has
        // not arrived yet; the caller re-normalises the whole accumulated buffer on the
        // next delta, so a `nil` here is retried rather than final.
        return nil
    }
}
