import Foundation
import Synchronization

// MARK: - Shared Parsing Helpers

/// Stateless utilities shared across all parsing strategies.
nonisolated enum ToolCallParsingHelpers {

    static func skipWhitespace(in s: Substring, from index: String.Index) -> String.Index {
        var i = index
        while i < s.endIndex, s[i].isWhitespace {
            i = s.index(after: i)
        }
        return i
    }

    /// Like `extractIdentifier`, but also handles quoted identifiers: `"tool_name"` or `'tool_name'`.
    static func extractIdentifierOrQuoted(in s: Substring, from index: String.Index) -> (
        String, String.Index
    )? {
        guard index < s.endIndex else { return nil }
        let ch = s[index]
        if ch == "\"" || ch == "'" {
            let innerStart = s.index(after: index)
            guard let closeIdx = s[innerStart...].firstIndex(of: ch) else { return nil }
            let inner = String(s[innerStart..<closeIdx])
            guard !inner.isEmpty,
                  inner.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." })
            else { return nil }
            return (inner, s.index(after: closeIdx))
        }
        return extractIdentifier(in: s, from: index)
    }

    static func extractIdentifier(in s: Substring, from index: String.Index) -> (
        String, String.Index
    )? {
        var i = index
        var out = ""
        while i < s.endIndex {
            let ch = s[i]
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" || ch == "." {
                out.append(ch)
                i = s.index(after: i)
                continue
            }
            break
        }
        guard !out.isEmpty else { return nil }
        return (out, i)
    }

    /// Maximum imbalance we are willing to repair via synthetic closers in
    /// `extractJSONBracedValue`. Tool-call envelopes nest at most ~3 levels
    /// (call object → `arguments` → one nested value), so imbalance beyond
    /// this bound signals truly garbled input rather than a missing trailing
    /// brace some models emit consistently.
    ///
    /// Shared, deliberately, by every repair in this file that pads or removes closers:
    /// BOTH salvage arms of `extractJSONBracedValue` (not-in-string and mid-string) and
    /// `repairPrematureObjectClose`. Widening this widens all three at once.
    /// `TeamConfigParser.maxSalvageDepth` mirrors the value on a different code path
    /// (team-config generation) and is kept in sync by nothing but this note — the
    /// divergence is deliberate: no defect of this class has been observed there.
    static let maxSalvageDepth = 3

    /// Extracts the balanced `{…}` / `[…]` span starting at `index`.
    ///
    /// On an unbalanced EOF this SALVAGES: truncate at the last close observed (any
    /// depth) and pad with synthetic `}`. **Two arms, deliberately asymmetric.**
    ///
    /// **Not in a string** — the original arm, unchanged. A dropped trailing `}` is a
    /// shape several models emit consistently; salvage unconditionally within the depth
    /// budget.
    ///
    /// **Mid-string at EOF** — salvage only when NO structural (outside-string) `:`
    /// appeared after the anchor. Verbatim from Ollama + `qwen3.8:27b-mlx`: the model
    /// closed `arguments`, then emitted `,"` and stopped —
    ///
    ///     <|call|>{"name":"edit_file","arguments":{…,"new_text":"…\n}"},"<|end|>
    ///
    /// The stray `"` leaves the walker in-string for the whole remaining buffer, so a
    /// blanket `!inString` refusal dropped a call whose three arguments were COMPLETE and
    /// whose tail (`,"` then `<|end|>`) is exactly the junk the truncation above exists to
    /// discard. All three other conditions held: `depth == 1`, `depth <= maxSalvageDepth`,
    /// and `lastCloseEnd` pointing at precisely the right byte.
    ///
    /// The colon is what separates that from `{"a":{"b":1},"c":"oops`, where the
    /// unterminated string is the VALUE of a begun key: truncating THAT silently drops an
    /// argument the model did send — the `ToolCallArgumentSpill` failure class this
    /// codebase refuses. Ask not "is there a value" but "is it COMPLETE". A member needs
    /// `key : value`, so "no structural colon after the anchor" means at most a partial
    /// KEY NAME is discarded. STRUCTURAL is load-bearing: `,"note: see below` carries a
    /// colon inside the unterminated key and must stay salvageable, which is why the flag
    /// is set only in the outside-string branch — a byte-level `contains(":")` over the
    /// tail would refuse it.
    ///
    /// `salvageEndMarker` bounds the mid-string arm's ANCHOR — never the walk. The walk
    /// must stay unbounded: a healthy envelope may legitimately carry `<|end|>` inside a
    /// string value (`{"content":"write <|end|> to stop"}` parses today), and cutting the
    /// walk there drops a call that works. But a stray quote inverts quote parity for the
    /// rest of the buffer, so a brace inside a LATER envelope's string value can be
    /// counted as structure and march `lastCloseEnd` into that envelope; refusing an
    /// anchor past the first end marker keeps this salvage inside the same bound
    /// `extractCallObject`'s premature-close repair already respects. Recovering the first
    /// call in that case needs a walker-state SNAPSHOT at the boundary (the pad count is
    /// EOF-`depth`, so a clamped anchor alone is not enough) — deliberately not done.
    ///
    /// The missing-key-quote family (`,path":`, `HarmonyJSONDefectRepairTests`) is NOT
    /// reliably excluded by either arm's guards — an earlier note here claimed parity
    /// inversion keeps every `}` inside a string so `lastCloseEnd` stays nil, and that
    /// claim was falsified in production (CubeCraft task 8 run 0): any `]`/`}` inside a
    /// LATER string value reads as structure under the inverted parity and becomes the
    /// anchor, so this salvage returns a span truncated MID-VALUE that no regex repair
    /// can terminate — and brackets inside `old_text`/`new_text` are the COMMON case
    /// when editing code, not a corner. That composition's rescue is downstream and
    /// deliberate: `CallMarkerStrategy` falls through to the `<|end|>`-bounded raw body
    /// when a walked span fails to parse, and `parseAfterRepairAndRewalk` re-walks the
    /// REPAIRED bytes, whose parity is correct. Do not read the family's tests as
    /// evidence about the colon discriminator.
    static func extractJSONBracedValue(
        in s: Substring, from index: String.Index, salvageEndMarker: String? = nil
    ) -> (
        String, String.Index
    )? {
        let i = index
        guard i < s.endIndex else { return nil }

        let startChar = s[i]
        guard startChar == "{" || startChar == "[" else { return nil }

        var depth = 0
        var inString = false
        var escape = false
        // Track the index *after* the last closing `}`/`]` we processed (any depth, not
        // only the outer one). When the walker exits unbalanced, we truncate there and
        // pad with synthetic closers — anything after the last close is junk (e.g.
        // trailing `<|end|>`).
        var lastCloseEnd: String.Index?
        // Whether a member BEGAN after the salvage anchor: set on a structural
        // (outside-string) `:`, cleared every time `lastCloseEnd` moves. The mid-string
        // salvage arm below is gated on this, and only this is what makes it safe — a
        // member is `key : value`, so no structural colon after the anchor means the
        // truncation discards at most a partial key name, never a value the model sent.
        var memberBeganAfterLastClose = false

        var end = i
        while end < s.endIndex {
            let ch = s[end]

            // Handle escapes uniformly — inside AND outside strings. Valid JSON only
            // contains `\` inside string literals, but the gemma-4-26b-a4b over-escape
            // defect emits `\"` at structural positions (`,\"key\":\"value\"`). Treating a
            // backslash-escaped quote as a literal pair everywhere stops that stray `\"`
            // from spuriously OPENING a string — without this the walker swallows the
            // closing braces as string content, never balances, and drops the whole tool
            // call before `parseToolCallFromJSON`'s repair pass can recover it. For valid
            // JSON the outside-string branch is unreachable (no `\` there), so for valid
            // input this is a pure superset of the prior behaviour and inside a string it is
            // byte-identical. (Behaviour differs only for already-malformed input — e.g. a
            // stray `\` before a structural close now returns nil instead of a broken span —
            // which fails closed, the correct outcome.)
            if escape {
                escape = false
            } else if ch == "\\" {
                escape = true
            } else if inString {
                if ch == "\"" {
                    inString = false
                }
            } else {
                if ch == "\"" {
                    inString = true
                } else if ch == "{" || ch == "[" {
                    depth += 1
                } else if ch == "}" || ch == "]" {
                    depth -= 1
                    lastCloseEnd = s.index(after: end)
                    memberBeganAfterLastClose = false
                    if depth == 0 {
                        let jsonText = String(s[i...end])
                        let next = s.index(after: end)
                        return (jsonText, next)
                    }
                } else if ch == ":" {
                    memberBeganAfterLastClose = true
                }
            }

            end = s.index(after: end)
        }

        // Walker reached end with unbalanced braces. Some models emit
        // `<|call|>{"name":"X","arguments":{…}<|end|>` — missing the outer `}`.
        // Salvage by truncating at the last `}`/`]` we saw (any depth) and padding
        // with synthetic closers. `maxSalvageDepth` guards against truly garbled
        // input; `lastCloseEnd != nil` guards against input with no observed
        // structure. The two arms are asymmetric on purpose — see the doc comment.
        guard depth > 0, depth <= Self.maxSalvageDepth, let truncate = lastCloseEnd else {
            return nil
        }
        if inString {
            guard !memberBeganAfterLastClose else { return nil }
            if let marker = salvageEndMarker,
               let boundary = s.range(of: marker, range: i..<s.endIndex)?.lowerBound,
               truncate > boundary
            {
                return nil
            }
        }
        let salvaged = String(s[i..<truncate]) + String(repeating: "}", count: depth)
        return (salvaged, truncate)
    }

    /// Whether the text at `index` continues an object's member list — optional
    /// whitespace, a `,`, optional whitespace, then a quoted key.
    ///
    /// This is the ONE structural signal that distinguishes "the object ended" from
    /// "the model closed it before it had finished writing the members". The brace
    /// walker cannot see the difference: it returns at the first depth-0 close, which
    /// for the defect below is several members too soon.
    static func continuesMemberList(
        _ s: Substring, from index: String.Index, limit: String.Index
    ) -> Bool {
        var i = index
        while i < limit, s[i].isWhitespace { i = s.index(after: i) }
        guard i < limit, s[i] == "," else { return false }
        i = s.index(after: i)
        while i < limit, s[i].isWhitespace { i = s.index(after: i) }
        return i < limit && s[i] == "\""
    }

    /// `extractJSONBracedValue` plus one repair the walker structurally cannot perform:
    /// a **premature closer** — the model closed the call object (or its `arguments`
    /// wrapper) before writing the remaining members, so the walker's first depth-0
    /// close lands mid-payload and everything after it is dropped in silence.
    ///
    /// Observed live from `google/gemma-4-26b-a4b-qat` twice in one step
    /// (`network_log.json`, 2026-08-13, 19:53:20 and 19:53:28):
    ///
    ///     {"name":"edit_file","arguments":{"new_text":"…"},"old_text":"…"},"path":"…"}}
    ///
    /// The walker returns at the `}` after `old_text`, so `path` never enters the dict
    /// and `edit_file` dispatches with `new_text` alone → `Missing required argument:
    /// path`, to a model that had sent all three. This is the mirror of the existing
    /// EOF salvage, which is strictly one-directional (`depth > 0`, appends closers) and
    /// therefore cannot help an over-closed object — for this payload it is not even
    /// reached, because the walker succeeds.
    ///
    /// Two properties keep the repair from reaching past its defect:
    ///  - it runs ONLY when a member list continues after the walker's span, so a
    ///    healthy call, and prose or junk after a balanced object, are byte-identical;
    ///  - the span stops at `endMarker`, so a repair can never swallow the NEXT
    ///    `<|call|>` envelope in the same buffer.
    ///
    /// The repaired object still carries the recovered members as SIBLINGS of
    /// `arguments`; moving them inside is `ToolCallShapeRecognizer`'s job, which owns
    /// shape recognition. This function only recovers bytes the walker discarded.
    static func extractCallObject(
        in s: Substring, from index: String.Index, endMarker: String
    ) -> (json: String, next: String.Index)? {
        guard
            let (json, next) = extractJSONBracedValue(
                in: s, from: index, salvageEndMarker: endMarker)
        else { return nil }

        let bodyEnd = s.range(of: endMarker, range: next..<s.endIndex)?.lowerBound ?? s.endIndex
        guard next < bodyEnd, continuesMemberList(s, from: next, limit: bodyEnd) else {
            return (json, next)
        }
        guard let repaired = repairPrematureObjectClose(String(s[index..<bodyEnd])) else {
            return (json, next)
        }
        return (repaired, bodyEnd)
    }

    /// Removes closers that ended an object while its member list was still going, then
    /// re-balances the tail. Returns nil unless the result strictly parses as an object —
    /// a reconstruction that does not parse is worse than the truncated span it replaces.
    ///
    /// Bounded by `maxSalvageDepth` removals for the same reason the EOF salvage is:
    /// beyond that the input is garbled rather than off by a brace, and inventing a
    /// shape for it would dispatch a call the model never made.
    private static func repairPrematureObjectClose(_ body: String) -> String? {
        var out = ""
        out.reserveCapacity(body.count)
        var depth = 0
        var inString = false
        var escape = false
        var removed = 0

        var i = body.startIndex
        while i < body.endIndex {
            let ch = body[i]
            let after = body.index(after: i)

            if escape {
                escape = false
            } else if ch == "\\" {
                escape = true
            } else if inString {
                if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
            } else if ch == "{" || ch == "[" {
                depth += 1
            } else if ch == "}" || ch == "]" {
                // A closer that would end the OUTER object while members continue is the
                // defect. Deeper closers are legitimate (`{"a":{"b":1},"c":2}` is valid
                // JSON), so only depth-to-zero is a candidate.
                if depth == 1, continuesMemberList(body[...], from: after, limit: body.endIndex) {
                    removed += 1
                    guard removed <= maxSalvageDepth else { return nil }
                    i = after
                    continue
                }
                depth -= 1
            }

            out.append(ch)
            i = after
        }

        guard !inString else { return nil }
        guard removed > 0 else { return nil }

        // Surplus trailing closers (the model closed twice at the end after closing early
        // in the middle) — drop them; missing ones — pad, on the EOF salvage's budget.
        while depth < 0 {
            while let last = out.last, last.isWhitespace { out.removeLast() }
            guard let last = out.last, last == "}" || last == "]" else { return nil }
            out.removeLast()
            depth += 1
        }
        if depth > 0 {
            guard depth <= maxSalvageDepth else { return nil }
            out += String(repeating: "}", count: depth)
        }

        guard let data = out.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              object is [String: Any]
        else { return nil }
        return out
    }

    static func advanceCursor(
        in s: Substring, from index: String.Index, endMarker: String
    ) -> String.Index {
        if let endRange = s.range(of: endMarker, range: index..<s.endIndex) {
            return endRange.upperBound
        }
        return index
    }

    /// Re-serialises an arguments payload into stable, sorted JSON.
    ///
    /// Carries ONE repair, for a shape observed live from `openai/gpt-oss-20b`: the model
    /// writes the arguments as a quoted ATTRIBUTE — `to=read_file arguments="{\"path\":…}"`
    /// with no `<|message|>` marker — so `ChannelEnvelopeParser`'s plain-`{` fallback finds the
    /// first brace inside that string literal and hands us the still-escaped body. Returned
    /// unchanged (the previous behaviour) it is not JSON at all: the tool runtime receives the
    /// whole blob as a single argument value, and every later stateless resend carries it
    /// inside the re-materialized Harmony envelope, where it is unparseable.
    ///
    /// The repair is gated on the text having ALREADY failed to parse, so it cannot touch a
    /// healthy payload — a Windows path or a regex keeps its backslashes byte-for-byte. If the
    /// unescaped form is not JSON either, the original is returned exactly as before: this
    /// widens what is recoverable, never what is accepted.
    static func normalizeArgumentsJSONString(_ jsonText: String) -> String {
        if let normalized = normalizedJSONContainer(jsonText) { return normalized }
        if let unescaped = unescapedJSONStringBody(jsonText),
           let normalized = normalizedJSONContainer(unescaped)
        {
            return normalized
        }
        // JSON5-style bare keys — `{new_text: "…"}` — reach here from the named-marker
        // branch (`<|call|>edit_file{…}`), which does not go through the repair chain in
        // `parseToolCallFromJSON`. Without this the blob is handed back unchanged and the
        // tool runtime, unable to parse it, wraps the WHOLE thing as `__raw_input__`,
        // where `requiredString`'s last-resort `return raw` hands it over as the value of
        // whichever argument is asked for first. Gated on the text having already failed
        // to parse, so a healthy payload is untouched.
        if let requoted = repairUnquotedJSONKeys(jsonText),
           let normalized = normalizedJSONContainer(requoted)
        {
            _bumpRepairFireCount()
            return normalized
        }
        return jsonText
    }

    /// Quotes bare identifiers sitting in KEY position — `{new_text: "…"}` →
    /// `{"new_text": "…"}` — or nil when there was nothing of the kind to fix.
    ///
    /// Safe by construction rather than by heuristic: a bare identifier in key position
    /// OUTSIDE a string is never valid JSON, so this can only turn invalid input into
    /// valid input. The caller re-parses strictly and discards the result otherwise, so
    /// a payload this cannot fully rescue (single-quoted values, say) is declined rather
    /// than guessed at.
    ///
    /// Two pieces of state carry the whole correctness argument. `inString` keeps a
    /// `key:` sequence inside a VALUE untouched — the payload that motivated this
    /// carried `struct ContentView: View {` and `let x: Int` inside `new_text`, and a
    /// string-blind pass would corrupt the very edit the model was making. The container
    /// stack keeps a `,` inside an ARRAY from opening a key position.
    ///
    /// Returns nil (not the input) when nothing changed, so callers can use it as a
    /// "was this defect present" test without bumping the repair-rate metric on healthy
    /// calls.
    static func repairUnquotedJSONKeys(_ text: String) -> String? {
        enum Container { case object, array }

        var stack: [Container] = []
        var out = ""
        out.reserveCapacity(text.count)
        var inString = false
        var escape = false
        var expectKey = false
        var changed = false

        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]

            if escape {
                escape = false
            } else if ch == "\\" {
                escape = true
            } else if inString {
                if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
                expectKey = false
            } else if ch == "{" {
                stack.append(.object)
                expectKey = true
            } else if ch == "[" {
                stack.append(.array)
                expectKey = false
            } else if ch == "}" || ch == "]" {
                if !stack.isEmpty { stack.removeLast() }
                expectKey = false
            } else if ch == "," {
                expectKey = stack.last == .object
            } else if !ch.isWhitespace {
                if expectKey, ch.isLetter || ch == "_" {
                    var identifierEnd = i
                    while identifierEnd < text.endIndex,
                          text[identifierEnd].isLetter || text[identifierEnd].isNumber
                          || text[identifierEnd] == "_"
                    {
                        identifierEnd = text.index(after: identifierEnd)
                    }
                    var colon = identifierEnd
                    while colon < text.endIndex, text[colon].isWhitespace {
                        colon = text.index(after: colon)
                    }
                    if colon < text.endIndex, text[colon] == ":" {
                        out += "\"\(text[i..<identifierEnd])\""
                        out += text[identifierEnd..<colon]
                        changed = true
                        expectKey = false
                        i = colon
                        continue
                    }
                }
                expectKey = false
            }

            out.append(ch)
            i = text.index(after: i)
        }

        guard changed, !inString else { return nil }
        return out
    }

    /// Stable re-serialisation, or `nil` when `text` is not a JSON object/array.
    private static func normalizedJSONContainer(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [])
        else { return nil }
        if let dict = object as? [String: Any] { return stableJSONString(from: dict) }
        if let arr = object as? [Any] { return stableJSONString(from: arr) }
        return nil
    }

    /// `text` read as the BODY of a JSON string literal, i.e. with one level of escaping
    /// removed. `nil` when there is nothing to unescape or the result is not a valid literal —
    /// letting Foundation own the escape rules rather than restating them here.
    private static func unescapedJSONStringBody(_ text: String) -> String? {
        guard text.contains("\\") else { return nil }
        guard let data = "\"\(text)\"".data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(
                  with: data, options: [.fragmentsAllowed]),
              let unescaped = object as? String,
              unescaped != text
        else { return nil }
        return unescaped
    }

    static func stableJSONString(from object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: options) {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    /// Harmony channel names that must never surface as tool names. Without
    /// this guard, `<|channel|>commentary<|message|>{...}` (no `to=functions.X`
    /// routing) would dispatch the channel name as a tool.
    static let reservedChannelNames: Set<String> = [
        "commentary", "analysis", "final", "thinking",
    ]

    static func parseToolCallFromJSON(_ jsonText: String) -> StepToolCall? {
        let sanitized = JSONUtilities.sanitizeJSONControlCharacters(jsonText)
        guard let data = sanitized.data(using: .utf8) else { return nil }
        let dict: [String: Any]
        if let object = try? JSONSerialization.jsonObject(with: data, options: []),
           let strictDict = object as? [String: Any]
        {
            dict = strictDict
            // Observability: when sanitize had to change the bytes to make this parse, the
            // input was strict-broken (only control-char defects alter sanitize's output, and
            // valid JSON never contains raw control chars) — so this is a sanitize-LAYER
            // recovery that the regex repair chain never saw. Count it so the train-app audit's
            // repair-rate metric isn't blind to RC3-class fixes. Mutually exclusive with the
            // `parseAfterRepair` bump below (that branch only runs when strict parse fails).
            if sanitized != jsonText { _bumpRepairFireCount() }
        } else if let repairedDict = parseAfterRepair(sanitized) {
            // Strict parse failed. Apply known model-defect repairs and retry —
            // the program covers the model's weakness rather than asking it to
            // fix what it can't see (CORE_PRINCIPLES). When a repair succeeds,
            // the tool call dispatches normally and the model never knows its
            // first-emit JSON was broken.
            dict = repairedDict
        } else if let reescapedDict = parseAfterContentReescape(jsonText) {
            // True last resort: the model emitted a large `content`/`new_text` field with raw
            // (unescaped) quotes and/or control chars — which the narrow regex chain above
            // cannot fix. Re-escape that ONE field by structure. Gated by strict re-validation
            // + a known-arg-key check (see the function), so a malformed reconstruction fails
            // closed rather than dispatching a corrupted call. NOTE: the gate blocks fabricated
            // UNKNOWN keys, not all truncation — when the field value itself contains a
            // `","<knownkey>":"…"`-shaped fragment the split is inherently ambiguous; see the
            // function doc for why that residual risk is accepted by design.
            dict = reescapedDict
            _bumpRepairFireCount()
        } else {
            return nil
        }

        let providerID = stringValue(dict["id"]) ?? stringValue(dict["call_id"])

        // Shape recognition (which envelope variant the model emitted) is owned
        // by `ToolCallShapeRecognizer`. The repair/recovery above turned the
        // (possibly broken) bytes into this clean dict; here we only dispatch on
        // its shape and serialize the resolved arguments.
        guard let resolved = ToolCallShapeRecognizer.resolve(from: dict) else { return nil }

        // Parameters the model wrote OUTSIDE its `arguments` wrapper were merged back in
        // by the shape recognizer. Tell the model, once, on the result of the call it
        // just made: a repair nobody reports is a defect the model re-emits for the rest
        // of the run — which is exactly what the 2026-08-13 gemma run did, eight seconds
        // apart, after being told only "Fix the arguments and retry".
        let recovered = ToolCallShapeRecognizer.spilledSiblingKeys(from: dict)
        if !recovered.isEmpty { _bumpRepairFireCount() }

        return StepToolCall(
            providerID: providerID,
            name: resolved.name,
            argumentsJSON: normalizeArgumentsJSON(resolved.arguments),
            argumentRepairNote: spilledArgumentsNote(recoveredKeys: recovered))
    }

    /// One line for the model, or nil when it emitted the call correctly.
    static func spilledArgumentsNote(recoveredKeys: [String]) -> String? {
        guard !recoveredKeys.isEmpty else { return nil }
        return "your `arguments` object closed early — "
            + recoveredKeys.joined(separator: ", ")
            + " were outside it and had to be recovered; put every parameter inside "
            + "`arguments`"
    }

    private static func normalizeArgumentsJSON(_ value: Any?) -> String {
        guard let value else { return "" }
        if let s = value as? String { return s }
        if let dict = value as? [String: Any] {
            return stableJSONString(from: dict) ?? ""
        }
        if let arr = value as? [Any] {
            return stableJSONString(from: arr) ?? ""
        }
        return String(describing: value)
    }

    /// Non-empty string value of a JSON `Any?`, else nil. Internal (not
    /// `private`) because `ToolCallShapeRecognizer` reads name fields through
    /// it — a shared parsing utility, the documented purpose of this enum.
    static func stringValue(_ any: Any?) -> String? {
        guard let any else { return nil }
        if let s = any as? String, !s.isEmpty { return s }
        return nil
    }

    // MARK: - Defect Repair (covers known model weaknesses)

    /// Counts how many times a JSON recovery turned a strict-broken payload into a
    /// parseable one — covering all THREE recovery layers `parseToolCallFromJSON` runs:
    /// (1) a sanitize-only recovery (bumps when `sanitizeJSONControlCharacters` alone makes
    /// the bytes parse, i.e. an RC3-class `\`+control fix), (2) the `parseAfterRepair` regex
    /// chain, and (3) the `parseAfterContentReescape` last-resort field re-escape. The three
    /// live in mutually exclusive arms of that function's if/else-if chain, so a recovered
    /// envelope counts exactly once. Never bumped on a no-op transform (valid JSON leaves
    /// sanitize output unchanged). Read via `repairFireCount` for diagnostics; reset via
    /// `_resetRepairFireCount()` in tests.
    ///
    /// The counter is **process-global** (the parser is stateless), so it
    /// reflects total repair activity across all roles and tasks in the current
    /// run of the app. That's enough granularity for the train-app skill audit
    /// pass ("compare repair-rate across model versions") which is the primary
    /// motivating consumer. A future refinement could move this to a
    /// per-`StepExecutionState` counter if finer attribution is needed.
    private static let _repairFireCount = Atomic<Int>(0)

    /// Number of times a JSON repair fix recovered a strict-broken envelope.
    /// Read-only; update via the internal `_bumpRepairFireCount` helper.
    static var repairFireCount: Int {
        _repairFireCount.load(ordering: .relaxed)
    }

    #if DEBUG
    static func _resetRepairFireCount() {
        _repairFireCount.store(0, ordering: .relaxed)
    }
    #endif

    private static func _bumpRepairFireCount() {
        _repairFireCount.wrappingAdd(1, ordering: .relaxed)
    }

    /// Repairs known stable JSON defects emitted by specific models, then
    /// returns the parsed object dict (or nil if no repair recovers a valid
    /// envelope). Used as a fallback after strict `JSONSerialization` failure.
    ///
    /// Per CORE_PRINCIPLES the program covers model weaknesses rather than
    /// teaching the model — the model can't observe its own broken-byte
    /// output, so retry nudges asking it to "use valid JSON" loop forever.
    /// Each repair targets ONE concrete payload pattern observed in a network
    /// trace, never a generic "best-effort fix" that could corrupt valid JSON.
    static func parseAfterRepair(_ sanitized: String) -> [String: Any]? {
        let repaired = repairCommonJSONDefects(sanitized)
        guard repaired != sanitized,
              let data = repaired.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any]
        else {
            return nil
        }
        _bumpRepairFireCount()
        return dict
    }

    /// Last-resort rescue for an `<|end|>`-bounded `<|call|>` body whose UNREPAIRED bytes
    /// poison the brace walk itself, so no downstream repair can help: repair FIRST, then
    /// RE-WALK the repaired bytes.
    ///
    /// The composition this exists for (live: CubeCraft task 8 run 0, `qwen3.8:27b-mlx`):
    /// a missing key-opening quote (`,path":`) PLUS a dropped trailing `}`. The quote
    /// defect inverts string parity, so the walk over raw bytes anchors its EOF salvage on
    /// a bracket INSIDE a later string value and truncates that value — a span no regex
    /// can terminate. The plain raw-body parse fails too: the repair chain is regex-only
    /// and cannot pad the missing brace. Repairing first restores parity; re-walking then
    /// lets the walker's ordinary EOF salvage pad the closer, and the strict parse of that
    /// span is the final gate — a repair mis-fire degrades to nil, never to a corrupted
    /// dispatch (same argument as `repairOverescapedKeyValuePair`'s call-path safety note).
    ///
    /// Gated on the repair actually CHANGING the bytes: re-walking unrepaired bytes would
    /// reproduce the exact failure the caller already has. `extractCallObject` rather than
    /// the bare walker, so the premature-closer repair composes here too.
    ///
    /// Counter note: a rescue whose re-walked span parses strictly bumps
    /// `repairFireCount` once, here. In the corner where the span needs the re-escape
    /// layer as well it can count twice — acceptable imprecision for a diagnostics
    /// counter (the regex chain cannot fire twice: its repairs are idempotent, so
    /// `parseAfterRepair` on already-repaired bytes returns nil).
    static func parseAfterRepairAndRewalk(_ rawBody: String) -> StepToolCall? {
        let sanitized = JSONUtilities.sanitizeJSONControlCharacters(rawBody)
        let repaired = repairCommonJSONDefects(sanitized)
        guard repaired != sanitized else { return nil }
        let sub = Substring(repaired)
        let start = skipWhitespace(in: sub, from: sub.startIndex)
        guard start < sub.endIndex, sub[start] == "{" else { return nil }
        guard let (span, _) = extractCallObject(
            in: sub, from: start, endMarker: CallMarkerStrategy.endMarker)
        else { return nil }
        guard let call = parseToolCallFromJSON(span) else { return nil }
        _bumpRepairFireCount()
        return call
    }

    /// Tool arguments the file/artifact tools accept (`write_file` / `edit_file` /
    /// `delete_file` / `create_artifact`). A recovered envelope whose `arguments` contains any
    /// key OUTSIDE this set means the re-escape split landed inside the content and fabricated
    /// a spurious key — so it's rejected. This blocks fabricated UNKNOWN keys; it does NOT
    /// catch every truncation (a split that absorbs the content's own `","<knownkey>":"…"`
    /// fragment still passes — see `parseAfterContentReescape`'s residual-ambiguity note).
    ///
    /// Hand-maintained: must stay a superset of those tools' schema property keys. A new schema
    /// arg added without updating this set would silently start rejecting otherwise-recoverable
    /// envelopes. Pinned by `testKnownToolArgumentKeys_coversFileAndArtifactToolSchemas`.
    private static let knownToolArgumentKeys: Set<String> = [
        "content", "new_text", "old_text", "path", "format", "name", "replace_all", "must_exist",
    ]

    #if DEBUG
    /// Read-only access to `knownToolArgumentKeys` for the schema-sync guard test
    /// (Swift `private` is file-scoped — the test lives in another file).
    static var _knownToolArgumentKeysForTesting: Set<String> { knownToolArgumentKeys }
    #endif

    /// Last-resort recovery for `gemma-4-26b-a4b`'s most severe defect: a large `content` /
    /// `new_text` / `old_text` field emitted with RAW (unescaped) double quotes and/or raw
    /// control characters — the model wrote the value as if it were not inside a JSON string
    /// at all (verbatim 15BED3EA). The narrow regex repairs can't fix arbitrary unescaped
    /// quotes, but the SURROUNDING tool-call structure is known and clean, so we re-escape
    /// just that one field's value.
    ///
    /// Strategy: locate `"<field>":"`, then try every later `"` as the value's closing quote;
    /// for each, escape the candidate blob with `escapeForJSON` and re-validate the whole
    /// envelope. Among the reconstructions that parse into a real tool call whose `arguments`
    /// keys are ALL known (no fabricated key), keep the one with the MOST arguments — that is
    /// the split that preserves every trailing arg (`format`/`name`/`path`) rather than
    /// absorbing them into the blob. Returns `nil` (fail closed) if none qualify.
    ///
    /// Safety: runs only after strict parse AND the regex chain both fail (valid JSON never
    /// reaches here); every result is strict-re-validated, so it can only produce valid JSON
    /// or `nil` — never malformed bytes. Operates on the RAW `jsonText` (not the sanitized
    /// form) so `escapeForJSON` handles raw newlines and quotes in one pass without
    /// double-escaping.
    ///
    /// Residual ambiguity (accepted by design): when the field value itself contains a
    /// `","<knownkey>":"…"`-shaped fragment, the bytes are identical whether that fragment is
    /// real trailing args or literal content — so the max-arg split can truncate the content
    /// and treat the fragment as args. The known-key gate only blocks fabricated UNKNOWN keys,
    /// not this case. Biasing the other way (longest content) would break the observed gemma
    /// defect (a real `","path":"…"` tail this recovery exists to preserve), so max-arg is the
    /// better default and the truncation case is left as documented residual risk. Current
    /// behaviour pinned by `testReescape_embeddedKnownKeyFragment_residualAmbiguity`.
    static func parseAfterContentReescape(_ raw: String) -> [String: Any]? {
        for field in ["content", "new_text", "old_text"] {
            guard let opener = raw.range(of: "\"\(field)\":\"") else { continue }
            let valueStart = opener.upperBound
            let prefix = String(raw[..<valueStart])
            var best: (argCount: Int, dict: [String: Any])?
            var cursor = valueStart
            var tried = 0
            while tried < 500, let quote = raw[cursor...].firstIndex(of: "\"") {
                tried += 1
                let blob = String(raw[valueStart..<quote])
                let reconstructed = prefix + JSONUtilities.escapeForJSON(blob) + String(raw[quote...])
                if let dict = JSONUtilities.parseJSONDictionary(reconstructed),
                   dict["name"] is String,
                   let args = dict["arguments"] as? [String: Any],
                   args[field] != nil,
                   Set(args.keys).isSubset(of: knownToolArgumentKeys),
                   best == nil || args.count > best!.argCount
                {
                    best = (args.count, dict)
                }
                cursor = raw.index(after: quote)
            }
            if let best { return best.dict }
        }
        return nil
    }

    /// Applies all known repair patterns. Pure string transform — does NOT
    /// validate the result. The caller re-parses with `JSONSerialization` and
    /// falls back to `nil` if repair didn't help. All three repairs are idempotent
    /// on already-fixed input, so the order is not load-bearing today.
    static func repairCommonJSONDefects(_ raw: String) -> String {
        var s = raw
        s = repairUnescapedHTMLAttributeClose(s)
        s = repairMissingQuoteBeforeJSONKey(s)
        s = repairOverescapedKeyValuePair(s)
        // Bare keys last: the three above are byte-surgery on quoting defects, and running
        // them first means this pass sees the closest thing to well-formed JSON the chain
        // can produce. Nil (nothing of the kind present) leaves `s` alone.
        s = repairUnquotedJSONKeys(s) ?? s
        return s
    }

    /// `qwen3.5-9b-mlx` defect: inside a JSON string holding HTML, the model
    /// emits attribute closes as `\"foo('-')">` instead of `\"foo('-')\">` —
    /// the closing escape backslash before `"` is dropped when an attribute
    /// value ends with a parenthesised JS argument. The bare `"` then closes
    /// the JSON string mid-value and `>...` becomes a syntax error. Verbatim
    /// broken payload pinned in `HarmonyJSONDefectRepairTests.verbatimBrokenPayload`.
    ///
    /// Detection: `)">` immediately followed by something that is NOT JSON
    /// syntax (`,`/`}`/`]`/`:`/whitespace). The lookahead is critical —
    /// without it we would corrupt valid JSON like `{"key":"f()"} `, where
    /// `)` followed by `"` followed by `}` is a legitimate property close.
    /// All three characters (`)` + `"` + `>`) must appear together; a stray
    /// `>` after a quoted string close is exotic enough that mismatching it
    /// is far less likely than the attribute defect we are repairing.
    ///
    /// Replacement inserts a backslash before the bare `"`, recreating the
    /// escape the model omitted.
    static func repairUnescapedHTMLAttributeClose(_ raw: String) -> String {
        // Pattern is a compile-time literal that cannot fail. `try!` turns a
        // future typo into a deterministic crash in dev/CI rather than silently
        // disabling repairs for everyone (`try?` would collapse "regex broken"
        // into "no repair needed" with no signal).
        let regex = try! NSRegularExpression(pattern: #"\)">(?=[^,}\]:\s])"#)
        let range = NSRange(raw.startIndex..., in: raw)
        return regex.stringByReplacingMatches(
            in: raw, range: range, withTemplate: #")\\">"#)
    }

    /// `qwen3.5-9b-mlx` defect (Team Generator emitting `team_config`):
    /// at a JSON-object property boundary the model drops the OPENING quote of
    /// a key while keeping the closing quote and colon intact. Observed shapes:
    ///   - `}],artifacts":[...`   ← should be `}],"artifacts":[`
    ///   - `}],supervisor_requires":[...]`
    ///   - `,description":"..."` (less commonly)
    /// The closing quote is always present (the model keeps `":` together as
    /// a unit), only the opening one disappears. This is **stochastic**: the
    /// same request can drop the quote on attempts 1+2 and emit it correctly
    /// on attempt 3 — costing wasted retry traffic before delegation can
    /// proceed. Verbatim broken payload pinned in
    /// `HarmonyJSONDefectRepairTests.verbatimMissingKeyQuotePayload`.
    ///
    /// Detection: a JSON property separator (`{` or `,`), then optional insignificant
    /// whitespace (`\s*` — JSON allows it between tokens, and models emit `, key":`), then —
    /// with no intervening `"` — an unquoted identifier-shape token, then a closing `":`.
    /// Identifier shape (`[A-Za-z_][A-Za-z0-9_]*`) is narrow enough to avoid matching
    /// free-text inside string values; the trailing `":` confirms the model intended this as
    /// a key. The replacement drops the matched whitespace (insignificant in JSON).
    ///
    /// Replacement re-inserts the missing opening quote.
    static func repairMissingQuoteBeforeJSONKey(_ raw: String) -> String {
        // Same try!-on-compile-time-literal rationale as above.
        let regex = try! NSRegularExpression(pattern: #"([{,])\s*([A-Za-z_][A-Za-z0-9_]*)":"#)
        let range = NSRange(raw.startIndex..., in: raw)
        return regex.stringByReplacingMatches(
            in: raw, range: range, withTemplate: #"$1"$2":"#)
    }

    /// `gemma-4-26b-a4b` defect: the model backslash-escapes the quotes of an ENTIRE
    /// key:value pair at a property boundary, e.g.
    ///   {"content":"…",\"path\":\"src/core/__init__.py\"}
    /// The `content` pair is correctly formed; only `path` is over-escaped. Each `\"`
    /// sits at JSON-structural position (key open/close, value open/close) where a
    /// backslash is illegal, so strict parse rejects the whole envelope and the
    /// `write_file` call is silently dropped — sending the model into a malformed-JSON
    /// retry loop. Verbatim broken payload (responses BE3E536B / 27DF1B2F) pinned in
    /// `HarmonyJSONDefectRepairTests.verbatimOverescapedPairPayload`.
    ///
    /// Detection is deliberately narrow: a property boundary (`{` or `,`), then optional
    /// insignificant whitespace (`\s*` — gemma emits `…", \"path\":…` with a space after the
    /// comma; verbatim 80A90B36), then an escaped-quote identifier-shape key, an escaped `":`,
    /// then an escaped-quote string value whose body contains no further quote or backslash,
    /// then an escaped closing quote. The regex is flat (no string-state tracking), so it CAN mis-fire on a `,`
    /// inside a legitimate string value that itself contains `\"key\":\"…\"`-shaped text.
    /// That is safe only because of the call path, not the regex: `repairCommonJSONDefects`
    /// runs exclusively AFTER a strict `JSONSerialization` parse has already failed (valid
    /// JSON never reaches here), and `parseAfterRepair` RE-VALIDATES with `JSONSerialization`
    /// — so a mis-fire degrades to unparseable JSON → `nil` → retry nudge, never a corrupted
    /// dispatch. If a value contains internal escapes the value-body pattern `[^"\\]*`
    /// simply doesn't match and we fall through unchanged. Same try!-on-compile-time-literal
    /// rationale as the two repairs above.
    static func repairOverescapedKeyValuePair(_ raw: String) -> String {
        let regex = try! NSRegularExpression(
            pattern: #"([{,])\s*\\"([A-Za-z_][A-Za-z0-9_]*)\\":\\"([^"\\]*)\\""#)
        let range = NSRange(raw.startIndex..., in: raw)
        return regex.stringByReplacingMatches(
            in: raw, range: range, withTemplate: #"$1"$2":"$3""#)
    }

    // MARK: - Nudge Classification

    /// Classifies *why* a Harmony-markered response produced no parsed tool call.
    /// The step-flow-control nudge uses this to choose a retry message that
    /// actually names the defect, instead of always blaming "malformed JSON".
    enum HarmonyCallIssue: Equatable {
        /// A `<|call|>` block was present but its JSON couldn't be parsed.
        case malformedJSON
        /// Harmony framing was seen — a `<|channel|>` / `<|start|>` envelope — but no
        /// `<|call|>` block was ever opened, so there is no JSON to be malformed. This
        /// used to fold into `.malformedJSON`, which told the model to fix braces and
        /// quotes in an envelope that had none, and charged the parse-failure cap for a
        /// defect that isn't one. Worse, the escalation the cap produces names
        /// *"unescaped quotes inside string literals"* — a misdiagnosis aimed at the
        /// HUMAN, not just the model.
        ///
        /// Notably NOT this case any more: an envelope that resolved a recipient and had
        /// an empty body. `ChannelEnvelopeParser` now emits that as a zero-argument call,
        /// so it never reaches the classifier. What lands here is framing with no
        /// recipient, a reserved recipient, or a body that is prose rather than JSON.
        case noCallEnvelope
        /// JSON between `<|call|>…<|end|>` parsed fine but lacked a top-level tool
        /// name. `inferredToolName` is non-nil when shape inference recognises the
        /// payload — used to craft a concrete retry example for the model.
        case missingToolName(inferredToolName: String?)
        /// The buffer contains Harmony markers (specifically, `<|start|>`
        /// followed by a role identifier — `user`/`assistant`/`system`/
        /// `developer`/`tool`) but no envelope shape at all. The model emitted
        /// an inlined role turn rather than attempting to call a tool. Callers
        /// should fall through to the generic "did not call any tools" retry
        /// instead of falsely accusing the model of malformed JSON.
        case noEnvelopeAttempt
    }

    /// The shared locate-and-extract step for the JSON payload after the first
    /// `<|call|>` marker — `classifyHarmonyCallIssue` and
    /// `malformedJSONDiagnostic` both build on this single walk, so the
    /// classifier and the retry diagnostic can never describe different byte
    /// ranges of the same envelope.
    enum PostCallJSON {
        case noCallMarker
        case noObject           // marker present, next non-whitespace is not `{`
        case unbalanced         // braces never balance (beyond salvage)
        case extracted(String)  // the braced value (pre-sanitize)
    }

    static func postCallJSON(in text: String) -> PostCallJSON {
        guard let callRange = text.range(of: CallMarkerStrategy.callMarker) else {
            return .noCallMarker
        }
        let tail = text[callRange.upperBound...]
        let jsonStart = skipWhitespace(in: tail, from: tail.startIndex)
        guard jsonStart < tail.endIndex, tail[jsonStart] == "{" else {
            return .noObject
        }
        // Same `salvageEndMarker` the dispatch walk uses, so the classifier and the retry
        // diagnostic describe the same bytes that `extractCallObject` would have accepted.
        guard
            let (jsonText, _) = extractJSONBracedValue(
                in: tail, from: jsonStart, salvageEndMarker: CallMarkerStrategy.endMarker)
        else {
            return .unbalanced
        }
        return .extracted(jsonText)
    }

    /// Scans the assistant's text for the first `<|call|>…<|end|>` block and
    /// reports the nature of the parse failure. Safe to call on responses where
    /// only `<|channel|>` markers appear (returns `.noCallEnvelope`).
    static func classifyHarmonyCallIssue(in text: String) -> HarmonyCallIssue {
        // Same repair the parser applies, for the same reason: `postCallJSON` is gated on
        // a literal `<|call|>`, so a mangled sentinel would be classified `.noCallEnvelope`
        // ("you never attempted a call") when the model plainly did.
        //
        // Streaming normalizes only the PREFIX of `harmonyBuffer` — the snapshot taken when
        // the marker was first detected — and appends every later content delta RAW, so a
        // second mangled sentinel in the same reply arrives here untouched. Must stay in
        // lockstep with `malformedJSONDiagnostic`, which the caller pairs with this verdict.
        let text = HarmonySentinelNormalizer.normalize(text)
        if containsOnlyRoleMarkerStarts(in: text) {
            return .noEnvelopeAttempt
        }
        let jsonText: String
        switch postCallJSON(in: text) {
        case .noCallMarker:
            // No `<|call|>` block at all — nothing here is malformed JSON, because there
            // is no JSON. `.noObject` / `.unbalanced` DO mean a block was opened and its
            // payload is broken, so those keep `.malformedJSON`.
            return .noCallEnvelope
        case .noObject, .unbalanced:
            return .malformedJSON
        case .extracted(let extracted):
            jsonText = extracted
        }
        let sanitized = JSONUtilities.sanitizeJSONControlCharacters(jsonText)
        let dict: [String: Any]
        if let data = sanitized.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data, options: []),
           let strictDict = object as? [String: Any]
        {
            dict = strictDict
        } else if let repairedDict = parseAfterRepair(sanitized) {
            // Strict parse failed but a known-defect repair recovered the
            // envelope. The actual tool call dispatch path (`parseToolCallFromJSON`)
            // will also rescue it, so this is not a real "malformed" failure
            // from the role's perspective.
            dict = repairedDict
        } else {
            return .malformedJSON
        }

        // If any recognised tool-name field is present, the parser should have
        // succeeded — either the name was reserved (e.g. `commentary`) or something
        // novel tripped us. Fall back to the generic nudge rather than claiming
        // "missing name" falsely.
        let hasTopLevelName = stringValue(dict["name"]) != nil
            || stringValue(dict["tool_name"]) != nil
            || stringValue(dict["tool"]) != nil
            || stringValue(dict["function_name"]) != nil
            || (dict["function"] as? [String: Any]).flatMap { stringValue($0["name"]) } != nil
        if hasTopLevelName {
            return .malformedJSON
        }

        return .missingToolName(
            inferredToolName: ToolCallShapeRecognizer.inferToolNameFromShape(dict)?.name)
    }

    /// Re-derives a human-readable defect description for a `.malformedJSON`
    /// classification, so the retry nudge can attach the ACTUAL parser error
    /// instead of generic guesses. Kept separate from `classifyHarmonyCallIssue`
    /// (which discards the parse error) so `HarmonyCallIssue` stays Equatable
    /// and every switch site is untouched; both build on `postCallJSON` so the
    /// walk cannot drift.
    ///
    /// Returns nil when no concrete single-line defect can be named: no
    /// `<|call|>` marker at all, the JSON actually parses, OR the strict parse
    /// fails but `parseAfterRepair` recovers it — in the repaired case classify
    /// fell to `.malformedJSON` for a different reason (e.g. a reserved tool
    /// name), and a strict-parse error would mislead the model about JSON the
    /// pipeline can in fact accept. The caller keeps its generic hints for nil.
    static func malformedJSONDiagnostic(in text: String) -> String? {
        // Same normalization as `classifyHarmonyCallIssue`, and for the same reason: both
        // build on `postCallJSON`, whose marker test is an exact substring. Normalizing
        // only the classifier would have let the pair DISAGREE — classify sees `<|call|>`
        // and answers `.malformedJSON`, this walk sees the raw `<|tool_call>call|>`,
        // returns `.noCallMarker` → nil, and the model gets the generic
        // "missing brace / unescaped quote / trailing comma" guesses instead of the actual
        // parser error.
        //
        // Streaming normalizes only the PREFIX of `harmonyBuffer` — the snapshot taken when
        // the marker was first detected. Every later content delta is appended RAW, so a
        // second mangled sentinel in the same reply arrives here untouched. (An earlier
        // version of this note blamed the reasoning-channel branch of `envelopeSource`;
        // that branch is unreachable, because `sawHarmonyMarker` is only ever set together
        // with a non-empty `harmonyBuffer`.)
        let text = HarmonySentinelNormalizer.normalize(text)
        let jsonText: String
        switch postCallJSON(in: text) {
        case .noCallMarker:
            return nil
        case .noObject:
            return "no JSON object follows `<|call|>`"
        case .unbalanced:
            return "the JSON object's braces never balance"
        case .extracted(let extracted):
            jsonText = extracted
        }
        let sanitized = JSONUtilities.sanitizeJSONControlCharacters(jsonText)
        guard let data = sanitized.data(using: .utf8) else { return nil }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [])
            return nil
        } catch let error as NSError {
            if parseAfterRepair(sanitized) != nil { return nil }
            let detail = ((error.userInfo[NSDebugDescriptionErrorKey] as? String)
                ?? error.localizedDescription)
                .components(separatedBy: .newlines).first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            return detail.isEmpty ? nil : detail
        }
    }

    /// Returns true when the buffer's only envelope-shaped markers are
    /// `<|start|>` openings followed by role identifiers. Used by
    /// `classifyHarmonyCallIssue` to distinguish "inlined role turn"
    /// (no envelope attempt) from "envelope present but malformed."
    ///
    /// Predicate is intentionally narrow: any `<|call|>` or `<|channel|>` in
    /// the buffer, or any `<|start|>` followed by a non-role identifier
    /// (`commentary`, `final`, `functions.NAME`), means the model DID attempt
    /// an envelope and the failure is malformed-JSON-shaped — keep the
    /// existing classification.
    private static func containsOnlyRoleMarkerStarts(in text: String) -> Bool {
        if text.contains(CallMarkerStrategy.callMarker) { return false }
        if text.contains(ChannelMarkerStrategy.channelMarker) { return false }

        let startMarker = StartMarkerStrategy.startMarker
        guard text.range(of: startMarker) != nil else { return false }

        var searchStart = text.startIndex
        while let range = text.range(of: startMarker, range: searchStart..<text.endIndex) {
            let after = range.upperBound
            let remainder = text[after...]
            let trimmed = remainder.drop(while: { $0.isWhitespace })
            if !StartMarkerStrategy.remainderBeginsWithRoleMarker(trimmed) {
                return false
            }
            searchStart = after
        }
        return true
    }
}
