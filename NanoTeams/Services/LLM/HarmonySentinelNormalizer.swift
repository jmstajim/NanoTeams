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
/// A second family corrupts the sentinel the prompt teaches rather than splicing an
/// alien one into it: `ornith-1.5:35b` (Ollama, `CastleSurvivorsNT` task 12 run 1,
/// 2026-09-05) drops the canonical marker's closing `>` and abuts the payload —
///
///     <|call|{"name":"bash","arguments":{"command":"git ls-tree …"}}
///
/// — which is one character from a working call and, before this, worth nothing. That
/// run is also what makes the family load-bearing rather than a curiosity: 30
/// consecutive assistant turns called tools in the canonical form, turn 31 slipped
/// once, and the next 9 turns reproduced the slip verbatim. The wire is append-only
/// (R3.9.1), so a turn the parser cannot read is stored raw and replayed as the
/// model's own most recent call shape — the defect becomes its own few-shot example
/// and never decays. Repairing the sentinel breaks that cycle at both ends: the call
/// dispatches, and the assistant turn is committed from the RESOLVED call
/// (`HarmonyToolCallEnvelope`), so the canonical form is what returns to the wire.
///
/// **This family tolerates NO debris.** `<|call|` must abut its `{`. The prefix is a
/// prefix of the canonical `<|call|>` itself, so any tolerance here would also rewrite
/// shapes that parse today — `<|call|>tool_name{…}` is a `CallMarkerStrategy` branch,
/// and a debris run would strip a `tool_name` that `ToolNames.allNames` does not list,
/// leaving a nameless payload. Requiring `{` immediately after `<|call|` cannot reach
/// either shape: both have `>` in that position.
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

    /// The canonical sentinel minus its closing `>`. Matched ONLY when a `{` abuts it
    /// (see the type comment) — this string is a prefix of `<|call|>`, so the abutment
    /// requirement is the entire thing keeping the repair off shapes that already parse.
    private static let truncatedCanonicalPrefix = "<|call|"

    /// Longest normalizable needle, in characters: the worst case over both families —
    /// `alienPrefix` + debris run + `{`, and `truncatedCanonicalPrefix` + `{`.
    /// One input to `StreamMarkerWindow.harmonyNeedleSpan` — the per-delta
    /// detection window must be able to hold a whole sentinel that arrived split
    /// across deltas.
    static let maxNeedleSpan = max(
        alienPrefix.count + maxDebrisRun + 1,
        truncatedCanonicalPrefix.count + 1)

    /// Rewrites every mangled opening sentinel to `<|call|>`, leaving everything else
    /// byte-identical.
    ///
    /// An `.alien` match requires all three, and each one is load-bearing:
    ///  1. the literal `<|tool_call` — an ordinary `tool_call` in prose has no `<|`;
    ///  2. a debris run under `maxDebrisRun` chars containing NO whitespace or newline —
    ///     a sentinel is one token, so any gap means the model was writing prose;
    ///  3. a `{` immediately after it — the payload. Without this requirement a model
    ///     *discussing* `<|tool_call|>` would have its sentence promoted to a call, which
    ///     is precisely the inference `BareToolCallSalvage` refuses to make. The rule
    ///     there applies here too: the permissiveness of shape recognition scales with
    ///     the strength of the intent signal, and a bare mangled token is not one.
    ///
    /// A `.truncatedCanonical` match requires (1) `<|call|` and (3) the abutting `{`, and
    /// admits NO debris run at all — condition (2) is not merely tightened here but
    /// removed, for the reason the type comment gives: the prefix is a prefix of the
    /// canonical marker, so a tolerated run would reach shapes that already parse.
    static func normalize(_ text: String) -> String {
        // Two read-only fast paths before anything is allocated. Since 2026-08-21 the
        // per-delta caller no longer reaches this with the whole accumulated buffer:
        // `StreamMarkerWindow.harmonyNeedleArrived` scans only the delta plus a
        // needle-sized overlap, and this function runs on the FULL buffer at most
        // once per stream, on the delta that completed a needle. (The previous
        // guard here was CLAUDE.md #106 in the flesh: allocation-free but O(buffer)
        // per delta — the gate itself was the quadratic it claimed to prevent.)
        //
        // The cheap gate is `sentinelOpen` — the scan's own needle, and the only thing
        // both families share. It has to be exactly the scan's needle: a gate NARROWER
        // than the scan returns early on buffers the scan would have repaired, which is
        // a missed repair, not a slow one. `truncatedCanonicalPrefix` is the tempting
        // spelling and that rule is what disqualifies it — `alienPrefix` (`<|tool_call`)
        // does NOT contain `<|call|`, so gating on it would hand back every
        // alien-family buffer unrewritten. That it is also a prefix of every canonical
        // `<|call|>`, and so filters weakly, is the lesser objection: a weak filter
        // costs one pre-check, a narrow one costs the repair.
        guard text.contains(sentinelOpen), hasNormalizableOccurrence(in: text[...]) else {
            return text
        }

        var result = ""
        result.reserveCapacity(text.count)
        var cursor = text.startIndex

        while let hit = nextSentinel(in: text[...], from: cursor) {
            result.append(contentsOf: text[cursor..<hit.range.lowerBound])

            if let payload = payloadStart(in: text[...], after: hit.range.upperBound,
                                          family: hit.family) {
                result.append(HarmonyToolCallParser.callMarker)
                // The debris run can CARRY the call's identity: `gemma-4-26b-a4b-qat`
                // writes `<|tool_call>call:edit_file{…}` (network_log.json, 2026-08-13),
                // and replacing the run wholesale took `edit_file` with it — leaving a
                // nameless payload that resolves to nothing and is dropped in silence.
                // Re-emitting the identifier lands on `CallMarkerStrategy`'s existing
                // `<|call|>tool_name{…}` branch, so this costs no new parsing machinery.
                // For `.truncatedCanonical` the run is empty by construction, so this
                // reads as the no-op it is rather than needing a branch of its own.
                if let name = trailingToolName(in: text[hit.range.upperBound..<payload]) {
                    result.append(name)
                }
                cursor = payload
            } else {
                // Not a call attempt — emit the token verbatim and keep scanning after
                // it, so a later genuine occurrence in the same buffer still normalises.
                result.append(contentsOf: text[hit.range.lowerBound..<hit.range.upperBound])
                cursor = hit.range.upperBound
            }
        }

        result.append(contentsOf: text[cursor...])
        return result
    }

    /// Whether at least one occurrence would actually be rewritten. Allocation-free, and
    /// bounded per occurrence by `maxDebrisRun`, so the no-op case stays a pure scan.
    /// Takes a `Substring` so `StreamMarkerWindow` can ask about a bounded window
    /// without copying it — the answer for a window is the answer for the buffer,
    /// because a needle wholly inside the buffer lies wholly inside some window.
    static func hasNormalizableOccurrence(in text: Substring) -> Bool {
        var cursor = text.startIndex
        while let hit = nextSentinel(in: text, from: cursor) {
            if payloadStart(in: text, after: hit.range.upperBound, family: hit.family) != nil {
                return true
            }
            cursor = hit.range.upperBound
        }
        return false
    }

    /// Which corruption a matched prefix belongs to. The two differ only in what may
    /// sit between the prefix and the payload, so the family travels with the match
    /// rather than being re-derived from the text at each use.
    private enum Family {
        /// `<|tool_call` + a whitespace-free debris run + `{`.
        case alien
        /// `<|call|` + `{`, no debris.
        case truncatedCanonical
    }

    /// Every sentinel of both families opens with this, so ONE forward search per
    /// iteration finds the next candidate of either. Searching for each prefix
    /// separately is the shape this deliberately avoids: with `k` candidates in the
    /// buffer, the family that runs out first re-scans to `endIndex` on every one of
    /// the other's iterations — O(n·k) on exactly the reply that motivates the file (a
    /// tool-loop turn can carry dozens of envelopes; `qwen3.8:27b-mlx` wrote 56 in one,
    /// 2026-08-15), and invisible because the answer stays correct. CLAUDE.md #106.
    private static let sentinelOpen = "<|"

    /// The next occurrence of either family at or after `cursor`, left to right.
    ///
    /// Linear over the buffer across the whole rebuild: `searchFrom` only ever moves
    /// forward past an inspected `<|`, so the searches this makes are disjoint spans of
    /// the buffer and their lengths sum to its length. The per-candidate test is
    /// `hasPrefix` against a bounded literal — no scan of its own.
    ///
    /// The two prefixes diverge at their third character (`t` vs `c`), so at most one
    /// family can match a given `<|` and there is no tie to break.
    private static func nextSentinel(
        in text: Substring, from cursor: String.Index
    ) -> (range: Range<String.Index>, family: Family)? {
        var searchFrom = cursor
        while let open = text.range(of: sentinelOpen, range: searchFrom..<text.endIndex) {
            let rest = text[open.lowerBound...]
            if let family = family(openedBy: rest) {
                let end = text.index(open.lowerBound, offsetBy: prefixLength(family),
                                     limitedBy: text.endIndex) ?? text.endIndex
                return (open.lowerBound..<end, family)
            }
            searchFrom = open.upperBound
        }
        return nil
    }

    /// Which family, if any, the text starting at a `<|` belongs to.
    private static func family(openedBy rest: Substring) -> Family? {
        if rest.hasPrefix(alienPrefix) { return .alien }
        if rest.hasPrefix(truncatedCanonicalPrefix) { return .truncatedCanonical }
        return nil
    }

    /// Prefix lengths, counted ONCE at type initialisation. `String.count` walks
    /// graphemes, so reading `alienPrefix.count` inside the scan would pay that walk per
    /// candidate — small per call and pointless, since both prefixes are compile-time
    /// ASCII literals whose length can never change at runtime.
    private static let alienPrefixLength = alienPrefix.count
    private static let truncatedCanonicalPrefixLength = truncatedCanonicalPrefix.count

    private static func prefixLength(_ family: Family) -> Int {
        switch family {
        case .alien: return alienPrefixLength
        case .truncatedCanonical: return truncatedCanonicalPrefixLength
        }
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

    /// Index of the payload's opening `{`, or `nil` when what follows the prefix
    /// disqualifies the match.
    ///
    /// For `.truncatedCanonical` the only accepted run is the empty one, so this is a
    /// single-character test: a `>` there is the canonical marker (leave it alone), and
    /// anything else is prose. For `.alien` the debris run may be up to `maxDebrisRun`
    /// characters and must contain no whitespace.
    ///
    /// Both families share the mid-stream contract: running out of buffer yields `nil`,
    /// and the caller re-normalises the whole accumulated buffer on the next delta, so
    /// a `nil` here is retried rather than final.
    private static func payloadStart(
        in text: Substring, after start: String.Index, family: Family
    ) -> String.Index? {
        guard start < text.endIndex else { return nil }

        if case .truncatedCanonical = family {
            return text[start] == "{" ? start : nil
        }

        var index = start
        var scanned = 0
        while index < text.endIndex, scanned < maxDebrisRun {
            let character = text[index]
            if character == "{" { return index }
            if character.isWhitespace || character.isNewline { return nil }
            index = text.index(after: index)
            scanned += 1
        }
        // Ran out of buffer or blew the cap.
        return nil
    }
}
