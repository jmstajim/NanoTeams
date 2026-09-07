import Foundation
#if DEBUG
import Synchronization
#endif

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
/// **This family tolerates WHITESPACE and nothing else.** The rule was "`<|call|` must
/// abut its `{`" until 2026-09-07, on the argument that the prefix is a prefix of the
/// canonical `<|call|>` itself, so any tolerance would rewrite shapes that parse today —
/// `<|call|>tool_name{…}` is a `CallMarkerStrategy` branch, and a debris run would strip
/// a `tool_name` that `ToolNames.allNames` does not list, leaving a nameless payload.
/// That argument is sound for a DEBRIS run and does not reach whitespace: `prefixTable`
/// is sorted longest-first, so `<|call|>` matches as `.canonical` before `<|call|` is
/// offered, and at a `.truncatedCanonical` hit the next character is therefore provably
/// not `>`. No shape that parses can carry whitespace in that position.
///
/// The same model that dropped the `>` also put a space after it — `MeditationApp` task
/// 39 run 8 (Ollama, 2026-09-06), 17 responses in the shape
///
///     <|call| {"name":"read_file", "arguments": {"path": "…"}}<|end|>
///
/// none of which resolved. The negative pin written on 2026-09-05 to state the abutment
/// rule carried the fixture `<|call| {"name":"search"}`; the model produced that string
/// verbatim the next day. A non-whitespace run stays refused — `<|call|read_file{` is
/// still untouched, because a run that can CARRY the call's identity is the 2026-08-14
/// identity-loss defect (`MangledSentinelIdentityTests`) one step on.
///
/// **What the gap costs, stated rather than discovered.** Prose that WRITES `<|call| {` with a
/// complete payload is now read as a call — pinned as an accepted false positive by
/// `ConversationRepairServiceTests.testReasoningNames_proseWritingTheGapShape_isReadAsACall_acceptedCost`.
/// The discriminator that would remove it is "the sentinel begins its line", and it is
/// rejected for a structural reason, not taste: `hasNormalizableOccurrence` is ALSO the
/// per-delta stream gate and receives a bounded WINDOW it cannot tell from a whole buffer, so
/// a window opening mid-line would report normalizable, `normalize` would then repair nothing
/// on the full buffer, and `sawHarmonyMarker` would close with `earliestLower == nil` — the
/// truncation rewind skipped and visible prose frozen mid-turn. That is the failure the
/// wrapper family's first draft produced, and it is strictly worse. The exposure is also
/// bounded by what reaching it takes: a model quoting the taught format writes `<|call|>{…}`
/// WITH its `>`, which has always dispatched, so the gap widens an opening that already
/// existed rather than opening a new one.
///
/// A THIRD family does not corrupt the sentinel at all — it WRAPS it. `ornith-1.5:35b`
/// again (Ollama, `MeditationApp` task 39 run 1, 2026-09-07), now emitting its native
/// ChatML tool-call tag AROUND the canonical envelope the prompt teaches:
///
///     …and ContentView.swift.<tool_call>
///     <|call|>{"name":"read_file","arguments":{"path":"MeditationApp/ContentView.swift"}}
///     <|end|>
///     </tool_call>
///
/// Unlike the two families above, this one raises nothing: the envelope parses and the
/// call dispatches. What it costs is the OPENING tag. It sits before the earliest marker,
/// so the streamer's truncation rewind keeps it as assistant prose; `ModelTokenCleaner`
/// cannot see it (that contract is `<|…|>` spans, and this form has no pipes);
/// `displayContent` is the identity for assistant turns and the bubble is a plain
/// `NSTextView`. So it rendered verbatim to the user AND rode the append-only wire, which
/// makes it self-reinforcing exactly like the truncated sentinel: measured over the run's
/// 28 assistant turns, phase 1 (17 turns) was clean, phase 2 slipped on its FIRST turn,
/// and 10 of 10 non-empty turns after that carried the tag — 64 occurrences replayed back
/// to the model.
///
/// **Adjacency is the entire gate.** The tag is dropped ONLY when at most `maxWrapperGap`
/// whitespace characters separate it from an envelope opening — measured, that gap was a
/// single `\n` every time. Standing alone the tag is honest prose: the Qwen
/// `<tool_call><function=NAME>` DSL is named in this repo's own playbook (R3.8.7 Check),
/// so promoting it would corrupt the documents that describe it. The marker-less
/// `<tool_call>{…}</tool_call>` form is deliberately NOT recognised for the same reason
/// one level up: identifying it needs a paired closer, and over those 28 turns the model
/// wrote `</tool_call>` exactly ONCE. Promoting text to a call on evidence that thin is
/// the inference `BareToolCallSalvage` refuses.
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
/// envelope contradicts the one-tool-per-response rule `NativeLMStudioClient.oneToolPerResponseRule` calls
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

    /// The canonical sentinel minus its closing `>`. Matched only when a `{` follows it
    /// across at most `maxTruncatedGap` whitespace characters (see the type comment for
    /// why whitespace is safe here and a debris run is not).
    private static let truncatedCanonicalPrefix = "<|call|"

    /// Longest run of WHITESPACE tolerated between `truncatedCanonicalPrefix` and its
    /// payload. The observed run is 1 — a single space in every one of the 17 occurrences
    /// of task 39 run 8, and a `\n` in the sibling shape. 4 is headroom for `\r\n`, a
    /// blank line or an indent, the same cap and the same reasoning as `maxWrapperGap`:
    /// past it the run is prose spacing, not a mangled token.
    private static let maxTruncatedGap = 4

    /// The ChatML tool-call tag the third family wraps the envelope in. An EXACT literal,
    /// never case-folded and never trimmed: `<TOOL_CALL>` or `< tool_call >` would be
    /// inference, the same rule `trailingToolName` states for tool names.
    private static let chatMLOpenTag = "<tool_call>"

    /// Every literal droppable as a WRAPPER — debris standing immediately to the left of
    /// an envelope opening, which the truncation rewind would otherwise keep as prose.
    ///
    /// The second entry is the scan's own needle: a bare `<|` with no `|>` anywhere after
    /// it is an unmatched opener by construction, and `ModelTokenCleaner` cannot remove it
    /// (its contract is closed `<|…|>` spans, so it breaks at the unmatched opener and
    /// returns the remainder verbatim). Record 115 of task 39 run 8 is exactly this: the
    /// turn that finally escaped the loop opened with `<|` on its own line, and those two
    /// characters reached the user as their own chat bubble.
    ///
    /// Longest first, stating the tie-break once as `prefixTable` does. No two entries can
    /// match at one position — they end in different characters — so the order is a
    /// convention here rather than a correctness requirement, and saying so keeps a future
    /// entry from having to rediscover which it is.
    private static let wrapperTags: [(tag: String, length: Int)] = [
        (chatMLOpenTag, chatMLOpenTag.count),
        (sentinelOpen, sentinelOpen.count),
    ].sorted { $0.length > $1.length }

    /// Longest run of whitespace tolerated between the wrapper tag and the envelope
    /// opening it wraps. The observed gap is 1 (`\n`, in all 10 occurrences); 4 is headroom
    /// for `\r\n`, a blank line or an indent — a cap, not an observation. It is what keeps
    /// this an adjacency test rather than a backward scan that could reach across prose.
    private static let maxWrapperGap = 4

    /// Longest normalizable needle, in characters: the worst case over both REPAIRABLE
    /// families —
    /// `alienPrefix` + debris run + `{`, and `truncatedCanonicalPrefix` + whitespace gap
    /// + `{`. The second is 12 against the first's 32, so the gap added in 2026-09-07 does
    /// not widen the per-delta window — pinned by
    /// `StreamMarkerWindowTests.testNeedleSpanIsUnchangedByTheTruncatedGap`.
    /// One input to `StreamMarkerWindow.harmonyNeedleSpan` — the per-delta
    /// detection window must be able to hold a whole sentinel that arrived split
    /// across deltas.
    ///
    /// The ChatML wrapper family does NOT enter this maximum, and the reason is that its
    /// branch cannot decide the window's answer: every wrapper positive CONTAINS an opening
    /// that fires on its own — a verbatim marker (caught by `harmonyNeedleArrived`'s marker
    /// test before this function is reached) or one of the two repairable sentinels above.
    /// The latch therefore closes without it, and `normalize` then runs on the FULL buffer,
    /// where the wrapper is visible whole. Growing the span for it would widen every
    /// per-delta window to buy nothing. Pinned by
    /// `StreamMarkerWindowTests.testNeedleSpanIsUnchangedByTheWrapperBranch`.
    static let maxNeedleSpan = max(
        alienPrefix.count + maxDebrisRun + 1,
        truncatedCanonicalPrefix.count + maxTruncatedGap + 1)

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
    ///
    /// Independently of all three, a `<tool_call>` WRAPPER is dropped when it sits within
    /// `maxWrapperGap` whitespace characters to the LEFT of an envelope opening — a
    /// verbatim marker, or a sentinel this pass repairs into one. Nothing else about the
    /// buffer changes: exactly the tag's characters are removed, the gap is re-emitted, and
    /// the closing `</tool_call>` is left alone (see the type comment for why).
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
            let payload = payloadStart(in: text[...], after: hit.range.upperBound,
                                       family: hit.family)
            // The wrapper is dropped only in front of something that IS an envelope opening
            // once this pass is done: a verbatim marker, or a sentinel this same iteration
            // repairs into one. Anything looser would leave the tag standing in front of a
            // repaired `<|call|>` — the same leak, one family to the left.
            let wrapper = (hit.family == .canonical || payload != nil)
                ? wrapperRange(in: text[...], endingAt: hit.range.lowerBound, notBefore: cursor)
                : nil

            // Decided BEFORE the prose prefix is appended: the wrapper sits to the LEFT of
            // the match, so appending the prefix first would already have committed the tag
            // to `result`, and nothing downstream re-reads what has been emitted.
            result.append(
                contentsOf: text[cursor..<(wrapper?.lowerBound ?? hit.range.lowerBound)])
            if let wrapper {
                // The whitespace gap is re-emitted verbatim — exactly the tag's characters
                // are removed and nothing else, so the rewind's own
                // `stripSurroundingWhitespace` still decides the model's spacing.
                result.append(contentsOf: text[wrapper.upperBound..<hit.range.lowerBound])
            }

            if let payload {
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
            // A verbatim marker counts as normalizable ONLY when a wrapper precedes it.
            // Without that condition this returns `true` for every ordinary `<|call|>{…}` —
            // and it is the guard on `normalize`'s early return, so every envelope-bearing
            // turn would rebuild the whole buffer. That regression is invisible in output
            // and shows up only as slowness, which is why it is pinned by
            // `testHasNormalizableOccurrence_ordinaryEnvelope_staysOffTheRebuildPath`.
            if hit.family == .canonical,
               wrapperRange(in: text, endingAt: hit.range.lowerBound, notBefore: cursor) != nil {
                return true
            }
            cursor = hit.range.upperBound
        }
        return false
    }

    /// Longest run inspected when NAMING a near-miss rather than repairing one.
    ///
    /// Deliberately wider than `maxDebrisRun`: the two budgets answer different questions.
    /// A wrong repair dispatches a call the model did not make, so the repair stays
    /// conservative; a wrong diagnosis costs one nudge, and the shape too mangled to repair
    /// is exactly the one the model most needs named. Sharing one cap would have made the
    /// diagnosis silent precisely where it is most useful.
    private static let maxDiagnosticRun = 2 * maxDebrisRun

    /// The prefix of a repairable-family sentinel this pass did NOT repair but which
    /// carries a payload anyway — the evidence that the turn was a call ATTEMPT rather
    /// than prose about the format.
    ///
    /// This exists because repair and diagnosis fail differently. Every widening of the
    /// repair is one more shape rescued and the NEXT unknown shape is still silent:
    /// `sawHarmonyMarker` stays open, so `classifyHarmonyCallIssue` — which sits behind
    /// that latch — never runs, and `handleNoToolCalls` falls through to whichever branch
    /// happens to match, which for a producing role is the artifact nudge. That is how
    /// `MeditationApp` task 39 run 8 spent 16 consecutive turns being told it had not
    /// submitted its deliverables while the feed plainly showed a tool call (CLAUDE.md
    /// #165's second half, unpaid until now).
    ///
    /// Returns the matched literal from `prefixTable`, never a slice of the model's own
    /// bytes: the caller puts this in a nudge, a nudge is never retired (R3.8.4), and
    /// quoting the looping output back into the prefix of every later request is the
    /// defect R3.8.3 forbids — measured at 80 characters re-seeding a loop, 2026-08-24.
    ///
    /// The run between prefix and `{` must contain NO whitespace. That is the same intent
    /// signal `payloadStart` demands of the alien family, and it is what keeps prose ABOUT
    /// the sentinel out: `Use <|call| when you want {…}` has a space in the run and is not
    /// a near-miss, while `<|call|read_file{` has none and is.
    static func unrepairedSentinel(in text: String) -> String? {
        guard text.contains(sentinelOpen) else { return nil }
        let body = text[...]
        var cursor = body.startIndex
        while let hit = nextSentinel(in: body, from: cursor) {
            if hit.family != .canonical,
               payloadStart(in: body, after: hit.range.upperBound, family: hit.family) == nil,
               carriesPayload(in: body, after: hit.range.upperBound) {
                return String(body[hit.range])
            }
            cursor = hit.range.upperBound
        }
        return nil
    }

    /// Whether a `{` follows within `maxDiagnosticRun` characters with no whitespace in
    /// between — "a payload abuts this token, but the family's own rule refused the run".
    private static func carriesPayload(in text: Substring, after start: String.Index) -> Bool {
        var index = start
        var scanned = 0
        while index < text.endIndex, scanned < maxDiagnosticRun {
            let character = text[index]
            if character == "{" { return true }
            if character.isWhitespace { return false }
            index = text.index(after: index)
            scanned += 1
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
        /// A verbatim `HarmonyToolCallParser` marker. Never repaired — matched so the scan
        /// STOPS on it and can inspect what sits immediately to its left.
        case canonical
    }

    /// Every prefix the scan recognises, longest first.
    ///
    /// Order is load-bearing in exactly one place and it is not cosmetic: `<|call|>`
    /// (`.canonical`) EXTENDS `<|call|` (`.truncatedCanonical`), so a shortest-first walk
    /// would read every healthy marker as a broken one and hand it to `payloadStart` under
    /// the wrong rule. Sorting by descending length states that tie-break once, instead of
    /// leaving it to where a case happens to sit in a literal.
    ///
    /// The `.canonical` set is `HarmonyToolCallParser.harmonyMarkers` rather than a
    /// `<|call|>` literal, and that is a single-source-of-truth choice, not convenience: it
    /// is the same set `sawHarmonyMarker` latches on and the earliest-marker rewind
    /// searches, so the wrapper is dropped in front of exactly what the streamer treats as
    /// an envelope opening — and a fourth marker would need no edit here.
    private static let prefixTable: [(prefix: String, length: Int, family: Family)] = {
        var entries: [(String, Family)] = [
            (alienPrefix, .alien),
            (truncatedCanonicalPrefix, .truncatedCanonical),
        ]
        entries.append(contentsOf: HarmonyToolCallParser.harmonyMarkers.map { ($0, .canonical) })
        return entries
            .map { (prefix: $0.0, length: $0.0.count, family: $0.1) }
            .sorted { $0.length > $1.length }
    }()

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
    /// Candidate prefixes are tried longest first (`prefixTable`), which is the only tie
    /// that exists: `<|call|>` extends `<|call|`.
    private static func nextSentinel(
        in text: Substring, from cursor: String.Index
    ) -> (range: Range<String.Index>, family: Family)? {
        var searchFrom = cursor
        while let open = text.range(of: sentinelOpen, range: searchFrom..<text.endIndex) {
            #if DEBUG
            _scanWork.wrappingAdd(1, ordering: .relaxed)
            #endif
            let rest = text[open.lowerBound...]
            if let match = family(openedBy: rest) {
                let end = text.index(open.lowerBound, offsetBy: match.length,
                                     limitedBy: text.endIndex) ?? text.endIndex
                return (open.lowerBound..<end, match.family)
            }
            searchFrom = open.upperBound
        }
        return nil
    }

    /// Which family, if any, the text starting at a `<|` belongs to, and how long its
    /// prefix is. The length travels with the match so the scan never re-derives it —
    /// `String.count` walks graphemes, and `prefixTable` pays that walk once at type
    /// initialisation for literals whose length cannot change at runtime.
    private static func family(openedBy rest: Substring) -> (family: Family, length: Int)? {
        for entry in prefixTable where rest.hasPrefix(entry.prefix) {
            return (entry.family, entry.length)
        }
        return nil
    }

    /// The wrapper immediately preceding an envelope opening, if one is there: a
    /// `<tool_call>` tag or a bare unmatched `<|` (see `wrapperTags`).
    ///
    /// BACKWARD and bounded, and that is what makes this family free: the tag is only ever
    /// significant when it abuts an opening, and openings are already found by the single
    /// forward scan `nextSentinel` makes. So recognising it adds no forward search —
    /// `sentinelOpen`, the early-return gate in `normalize`, and the disjointness of
    /// `nextSentinel`'s scans are all untouched.
    ///
    /// `floor` is the rebuild cursor: a wrapper may not reach back into text already
    /// emitted. The comparison is INCLUSIVE — `index(_:offsetBy:limitedBy:)` returns the
    /// limit itself rather than `nil` — because a tag opening the buffer is a real shape
    /// (records 68 and 80 of the run are exactly that), and an exclusive floor would leave
    /// precisely those turns uncleaned.
    private static func wrapperRange(
        in text: Substring, endingAt envelopeStart: String.Index, notBefore floor: String.Index
    ) -> Range<String.Index>? {
        var gapStart = envelopeStart
        var gap = 0
        while gap < maxWrapperGap, gapStart > floor {
            let previous = text.index(before: gapStart)
            guard text[previous].isWhitespace else { break }
            gapStart = previous
            gap += 1
        }
        for entry in wrapperTags {
            guard let tagStart = text.index(gapStart, offsetBy: -entry.length,
                                            limitedBy: floor),
                text[tagStart...].hasPrefix(entry.tag)
            else { continue }
            return tagStart..<gapStart
        }
        return nil
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
    /// `.canonical` never yields a payload: it is not repaired. For `.truncatedCanonical`
    /// the accepted run is up to `maxTruncatedGap` WHITESPACE characters and nothing else —
    /// anything non-whitespace there is prose or a name-bearing debris run, both refused.
    /// For `.alien` the debris run may be up to `maxDebrisRun` characters and, inversely,
    /// must contain no whitespace at all.
    ///
    /// Both families share the mid-stream contract: running out of buffer yields `nil`,
    /// and the caller re-normalises the whole accumulated buffer on the next delta, so
    /// a `nil` here is retried rather than final.
    private static func payloadStart(
        in text: Substring, after start: String.Index, family: Family
    ) -> String.Index? {
        // A verbatim marker is not a repair candidate — it is already the shape the parser
        // wants, and rewriting it is what the `isByteIdentical` pins forbid. It is matched
        // only so the scan stops on it; whether anything happens is decided by its wrapper.
        if case .canonical = family { return nil }

        guard start < text.endIndex else { return nil }

        if case .truncatedCanonical = family {
            // Whitespace only, and bounded. A `>` here is the canonical marker (which
            // `prefixTable` has already claimed as `.canonical`, so this is unreachable
            // rather than merely refused); any other non-whitespace character is either
            // prose or a debris run that could carry the call's identity, and both stay
            // refused. Running out of buffer mid-gap yields `nil` and is retried on the
            // next delta, the same mid-stream contract as the alien family.
            var index = start
            var gap = 0
            while index < text.endIndex, gap < maxTruncatedGap, text[index].isWhitespace {
                index = text.index(after: index)
                gap += 1
            }
            guard index < text.endIndex else { return nil }
            return text[index] == "{" ? index : nil
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

    #if DEBUG
    /// Work-bound seam for `HarmonySentinelNormalizerTests`: `<|` candidates `nextSentinel`
    /// has INSPECTED since the last reset.
    ///
    /// The linearity of this file rests on one property — `searchFrom` only ever moves
    /// forward past an inspected opener, so the scans are disjoint spans whose lengths sum
    /// to the buffer's. That claim used to be guarded by the complexity ratchet, which
    /// ranked the rebuild loop while it lived in `normalize`; since it moved here, where
    /// `text` is a parameter rather than an accumulator, axis a2 no longer ranks it and the
    /// argument went unguarded (DEBTS.md D-B6).
    ///
    /// Counted INSIDE the loop, not beside a call site: the property under test is how many
    /// times a candidate is inspected, and a counter at the call site would report one per
    /// `normalize` no matter how many times the scan doubled back (CLAUDE.md #62).
    ///
    /// A regression here is invisible in OUTPUT — a non-disjoint scan returns exactly the
    /// same answers, just quadratically slower — which is why the bound is asserted at all.
    private static let _scanWork = Atomic<Int>(0)
    static func _testScanWork() -> Int { _scanWork.load(ordering: .relaxed) }
    static func _testResetScanWork() { _scanWork.store(0, ordering: .relaxed) }
    #endif
}
