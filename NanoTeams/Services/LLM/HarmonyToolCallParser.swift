import Foundation

// MARK: - Strategy Protocol

/// Strategy for parsing tool calls from a specific marker format.
/// Implement this protocol to add new marker-based parsing formats (OCP).
nonisolated protocol ToolCallParsingStrategy: Sendable {
    func parse(from text: String) -> [StepToolCall]
}

// MARK: - Call Marker Strategy

/// Parses `<|call|>` format: `<|call|>{JSON}<|end|>` or `<|call|>tool_name {JSON}<|end|>`
nonisolated struct CallMarkerStrategy: ToolCallParsingStrategy {
    static let callMarker = "<|call|>"
    static let endMarker = "<|end|>"

    func parse(from text: String) -> [StepToolCall] {
        guard let firstMarkerRange = text.range(of: Self.callMarker) else { return [] }

        let tail = text[firstMarkerRange.lowerBound...]
        var cursor = tail.startIndex
        var results: [StepToolCall] = []

        while let markerRange = tail.range(of: Self.callMarker, range: cursor..<tail.endIndex) {
            var idx = markerRange.upperBound
            idx = ToolCallParsingHelpers.skipWhitespace(in: tail, from: idx)

            if idx >= tail.endIndex { break }

            if tail[idx] == "{" {
                // `extractCallObject`, not the bare walker: it adds the premature-closer
                // repair, which the walker cannot perform because it returns at the first
                // depth-0 close — several members too soon when the model closed early.
                if let (jsonText, endIdx) = ToolCallParsingHelpers.extractCallObject(
                    in: tail, from: idx, endMarker: Self.endMarker)
                {
                    if let call = ToolCallParsingHelpers.parseToolCallFromJSON(jsonText) {
                        results.append(call)
                        cursor = ToolCallParsingHelpers.advanceCursor(
                            in: tail, from: endIdx, endMarker: Self.endMarker)
                        continue
                    }
                    // The walked span didn't parse. When the block is `<|end|>`-delimited,
                    // fall THROUGH to the raw-body fallback below instead of dropping the
                    // call: a "successful" walk over unrepaired bytes can be poisoned by the
                    // very defect the repair chain exists to fix. Live case (CubeCraft
                    // task 8 run 0, qwen3.8:27b-mlx): a missing key-opening quote
                    // (`,path":`) inverted string parity, `old_text`'s value read as
                    // structure, its `]` anchored the mid-string EOF salvage, and the span
                    // came back truncated MID-VALUE — unrepairable, while the RAW body was
                    // fully recoverable (repair the quote, re-walk, pad the one missing
                    // brace). Without `<|end|>` the raw body is unbounded — keep the old
                    // advance-and-drop.
                    guard tail.range(of: Self.endMarker, range: idx..<tail.endIndex) != nil
                    else {
                        cursor = ToolCallParsingHelpers.advanceCursor(
                            in: tail, from: endIdx, endMarker: Self.endMarker)
                        continue
                    }
                }

                // Raw-body fallback — reached when the walker couldn't balance the span at
                // all, OR when its span failed to parse (see above). The repairs in
                // `parseToolCallFromJSON` cover defects the walker cannot (a missing key
                // OPENING quote — `,path":` instead of `,"path":` — flips string parity so
                // closing braces can be swallowed as string content), and
                // `parseAfterRepairAndRewalk` covers the composition the plain raw-body
                // parse cannot: repairs are regex-only with no brace padding, so a body
                // that ALSO dropped its trailing closer needs the repaired bytes re-walked
                // for the walker's EOF salvage to pad them. Well-formed (incl. multi-call)
                // envelopes never reach either arm.
                //
                // A `,"` junk tail no longer arrives here — the walker's mid-string EOF
                // salvage handles that shape — but an anchor marched past `<|end|>` by quote-
                // parity inversion still does, and this fallback is what recovers the LATER
                // envelope in that case. Note the raw body keeps everything before `<|end|>`,
                // so it cannot repair a trailing `,"` on its own: every re-escape split leaves
                // the stray comma-quote in place.
                if let endRange = tail.range(of: Self.endMarker, range: idx..<tail.endIndex) {
                    let rawBody = String(tail[idx..<endRange.lowerBound])
                    if let call = ToolCallParsingHelpers.parseToolCallFromJSON(rawBody)
                        ?? ToolCallParsingHelpers.parseAfterRepairAndRewalk(rawBody)
                    {
                        results.append(call)
                    }
                    cursor = endRange.upperBound
                    continue
                }
            }

            if let (name, nameEnd) = ToolCallParsingHelpers.extractIdentifier(in: tail, from: idx),
               !ChannelMarkerStrategy.reservedChannelNames.contains(name.lowercased()) {
                let argsIdx = ToolCallParsingHelpers.skipWhitespace(in: tail, from: nameEnd)
                if argsIdx < tail.endIndex, tail[argsIdx] == "{" {
                    if let (jsonText, endIdx) = ToolCallParsingHelpers.extractJSONBracedValue(
                        in: tail, from: argsIdx)
                    {
                        let args = ToolCallParsingHelpers.normalizeArgumentsJSONString(
                            JSONUtilities.sanitizeJSONControlCharacters(jsonText))
                        results.append(
                            StepToolCall(providerID: nil, name: name, argumentsJSON: args))
                        cursor = ToolCallParsingHelpers.advanceCursor(
                            in: tail, from: endIdx, endMarker: Self.endMarker)
                        continue
                    }
                }
            }

            // This `<|call|>` couldn't be extracted (reserved channel name,
            // malformed JSON, missing identifier). Advance past it so subsequent
            // legitimate `<|call|>TOOL{...}<|end|>` blocks in the same message
            // can still be parsed instead of dropping the rest.
            cursor = ToolCallParsingHelpers.advanceCursor(
                in: tail, from: idx, endMarker: Self.endMarker)
        }

        return results
    }
}

// MARK: - Start Marker Strategy

/// Parses two `<|start|>`-opened formats:
///   1. `<|start|>functions.TOOL_NAME<|message|>{JSON}` — canonical Harmony form.
///   2. `<|start|>commentary|final … to=NAME … <|constrain|>… <|message|>{JSON}` —
///      malformed variant emitted by `gpt-oss-20b` and similar models that mix
///      the `<|start|>` opening marker with channel-style framing. Without
///      this branch the envelope parses as zero tool calls, the engine sends
///      a "did not call any tools" retry, and `ModelTokenCleaner` strips the
///      `<|…|>` markers leaving residue like `commentary to=read_file json{…}`
///      visible in the activity feed.
///
/// Role markers (`<|start|>user…`, `<|start|>assistant…`, etc.) are also
/// emitted by buggy models — they're inlined next-turn content, NOT tool
/// calls. We skip them so they don't get mis-parsed.
nonisolated struct StartMarkerStrategy: ToolCallParsingStrategy {
    static let startMarker = "<|start|>"
    static let messageMarker = "<|message|>"
    static let endMarker = "<|end|>"

    /// Identifiers that mark an inlined role turn rather than a tool call.
    /// When `<|start|>` is followed by one of these, advance past and continue —
    /// never parse as a tool envelope.
    static let roleMarkers: Set<String> = [
        "user", "assistant", "system", "developer", "tool",
    ]

    /// Returns true if the content immediately after a `<|start|>` marker
    /// begins with one of the role identifiers. Looks at a bounded prefix
    /// because models inline next-turn content with no separator (e.g.
    /// `<|start|>userI've examined…`), so full-identifier equality on
    /// `extractIdentifier`'s output would miss the role token.
    static func remainderBeginsWithRoleMarker(_ remainder: Substring) -> Bool {
        let lowered = remainder.prefix(16).lowercased()
        return roleMarkers.contains(where: { lowered.hasPrefix($0) })
    }

    func parse(from text: String) -> [StepToolCall] {
        guard let firstMarkerRange = text.range(of: Self.startMarker) else { return [] }

        let tail = text[firstMarkerRange.lowerBound...]
        var cursor = tail.startIndex
        var results: [StepToolCall] = []

        // Forward progress is guaranteed by the `range(of: startMarker)` lookup
        // returning strictly later occurrences, NOT by `advanceCursor` moving
        // the cursor (which can no-op when `<|end|>` is absent). Do not change
        // to a `while cursor < tail.endIndex` loop without also adding a
        // defensive `cursor = markerRange.upperBound` bump when `advanceCursor`
        // doesn't make progress.
        while let markerRange = tail.range(of: Self.startMarker, range: cursor..<tail.endIndex) {
            var idx = markerRange.upperBound
            idx = ToolCallParsingHelpers.skipWhitespace(in: tail, from: idx)

            // Path 1: <|start|>functions.NAME<|message|>{JSON}
            let prefix = "functions."
            if tail[idx...].hasPrefix(prefix) {
                let afterPrefix = tail.index(idx, offsetBy: prefix.count)
                if let next = parseFunctionsEnvelope(in: tail, from: afterPrefix) {
                    results.append(next.call)
                    cursor = next.nextCursor
                    continue
                }
                cursor = ToolCallParsingHelpers.advanceCursor(
                    in: tail, from: afterPrefix, endMarker: Self.endMarker)
                continue
            }

            // Path 2a: role markers (user/assistant/system/developer/tool) — skip.
            // Path 2b: channel-style envelope (commentary/final/...) — delegate
            // to ChannelEnvelopeParser, bounded by the next <|start|> marker.
            if Self.remainderBeginsWithRoleMarker(tail[idx...]) {
                cursor = ToolCallParsingHelpers.advanceCursor(
                    in: tail, from: idx, endMarker: Self.endMarker)
                continue
            }

            let blockEnd =
                tail.range(of: Self.startMarker, range: idx..<tail.endIndex)?.lowerBound
                    ?? tail.endIndex
            if let envelope = ChannelEnvelopeParser.parseEnvelope(
                in: tail, cursorAfterOpening: idx, blockEnd: blockEnd)
            {
                results.append(envelope.call)
                cursor = envelope.nextStart
                continue
            }

            cursor = ToolCallParsingHelpers.advanceCursor(
                in: tail, from: idx, endMarker: Self.endMarker)
        }

        return results
    }

    /// Parses the post-`functions.` portion of a canonical envelope. Caller
    /// has already advanced past `<|start|>functions.`.
    private func parseFunctionsEnvelope(in tail: Substring, from idx: String.Index)
        -> (call: StepToolCall, nextCursor: String.Index)?
    {
        guard let (name, nameEnd) = ToolCallParsingHelpers.extractIdentifier(in: tail, from: idx),
              let messageRange = tail.range(of: Self.messageMarker, range: nameEnd..<tail.endIndex)
        else { return nil }

        var argsIdx = messageRange.upperBound
        argsIdx = ToolCallParsingHelpers.skipWhitespace(in: tail, from: argsIdx)
        guard argsIdx < tail.endIndex, tail[argsIdx] == "{" else { return nil }

        guard let (jsonText, endIdx) = ToolCallParsingHelpers.extractJSONBracedValue(
            in: tail, from: argsIdx)
        else { return nil }

        let args = ToolCallParsingHelpers.normalizeArgumentsJSONString(
            JSONUtilities.sanitizeJSONControlCharacters(jsonText))
        let call = StepToolCall(providerID: nil, name: name, argumentsJSON: args)
        let nextCursor = ToolCallParsingHelpers.advanceCursor(
            in: tail, from: endIdx, endMarker: Self.endMarker)
        return (call, nextCursor)
    }
}

// MARK: - Channel Envelope Parser (shared helper)

/// Parses a single channel-style envelope from `cursorAfterOpening` up to
/// `blockEnd` (exclusive). Shared between `ChannelMarkerStrategy` (called
/// after `<|channel|>`) and `StartMarkerStrategy`'s Path 2b (called after
/// `<|start|>` when content isn't `functions.NAME` or a role marker).
///
/// Recognised shapes (any opening marker — bounded by caller):
///   - `commentary|final to=NAME … <|message|>{JSON}`
///   - `commentary|final to="NAME" … <|message|>{JSON}` (quoted name)
///   - `commentary|final <|constrain|>NAME<|message|>{JSON}` (constrain-as-name fallback)
///   - `commentary|final to=NAME … {JSON}` (no `<|message|>`, plain `{` fallback)
///   - `commentary|final to=NAME <|message|>` (nothing after the marker → zero-arg `{}`)
///
/// The recipient is read from the HEADER only — the span before `<|message|>` — so body
/// text can never supply the tool name.
///
/// Returns nil when no tool name resolves, or when a name resolved but the body is
/// neither valid JSON nor empty.
nonisolated enum ChannelEnvelopeParser {
    static func parseEnvelope(
        in text: Substring, cursorAfterOpening: String.Index, blockEnd: String.Index
    ) -> (call: StepToolCall, nextStart: String.Index)? {
        // 0. Split header from body. The Harmony recipient (`to=NAME`) and the
        //    `<|constrain|>` hint both live in the HEADER — the span between the opening
        //    marker and `<|message|>`. Searching past it lets text inside the BODY supply
        //    the tool name, which stayed harmless only while both strategies below still
        //    required a `{`. The zero-argument arm added in step 2b removes that accident,
        //    so the search is bounded now: `<|channel|>final<|message|>… to=… ` prose is
        //    gpt-oss's single most common non-tool emission and must never mint a call.
        let messageRange = text.range(
            of: ChannelMarkerStrategy.messageMarker, range: cursorAfterOpening..<blockEnd)
        let headerEnd = messageRange?.lowerBound ?? blockEnd

        // 1. Resolve the tool name — try `to=NAME` first, then `<|constrain|>NAME`.
        var toolName: String?
        var nameEnd: String.Index = cursorAfterOpening

        if let toRange = text.range(of: "to=", range: cursorAfterOpening..<headerEnd) {
            let nameSearchStart = ToolCallParsingHelpers.skipWhitespace(
                in: text, from: toRange.upperBound)
            if let (name, end) = ToolCallParsingHelpers.extractIdentifierOrQuoted(
                in: text, from: nameSearchStart)
            {
                toolName = name
                nameEnd = end
            }
        }

        if toolName == nil,
           let constrainRange = text.range(
               of: ChannelMarkerStrategy.constrainMarker, range: cursorAfterOpening..<headerEnd)
        {
            let afterConstrain = constrainRange.upperBound
            if let (candidate, end) = ToolCallParsingHelpers.extractIdentifier(
                in: text, from: afterConstrain)
            {
                let lowered = candidate.lowercased()
                if !ChannelMarkerStrategy.isConstrainFormatKeyword(lowered),
                   !ToolCallParsingHelpers.reservedChannelNames.contains(lowered)
                {
                    toolName = candidate
                    nameEnd = end
                }
            }
        }

        guard let resolvedName = toolName else { return nil }

        // 2. Strategy 1: standard `<|message|>{JSON}` framing.
        if let messageRange {
            var jsonStart = messageRange.upperBound
            jsonStart = ToolCallParsingHelpers.skipWhitespace(in: text, from: jsonStart)
            if jsonStart < text.endIndex, text[jsonStart] == "{",
               let (jsonText, endIdx) = ToolCallParsingHelpers.extractJSONBracedValue(
                   in: text, from: jsonStart)
            {
                let (dispatchName, dispatchArgs) = ChannelMarkerStrategy.resolveDispatch(
                    channelName: resolvedName, innerJSON: jsonText)
                let call = StepToolCall(
                    providerID: nil, name: dispatchName, argumentsJSON: dispatchArgs)
                return (call, endIdx)
            }

            // 2b. Zero-argument envelope: `… to=NAME <|message|>` with nothing after it.
            //     The name resolved; only the body is absent. Emitting `{}` instead of nil
            //     is what lets a genuinely argument-less tool fire, and what lets a
            //     hallucinated name reach `executeToolCalls` and come back
            //     `tool_not_authorized` + "do not retry 'X'" — a far more useful answer than
            //     the "missing closing brace" retry this used to produce for an envelope
            //     that had no brace to miss.
            //
            //     `resolvedName` is used DIRECTLY, bypassing `resolveDispatch`: with no body
            //     there is no inner envelope whose `name` could out-rank the recipient.
            //
            //     The reserved-word guard is applied HERE because the `to=` path never
            //     applied it (only the `<|constrain|>` path does). That hole stayed masked
            //     while a JSON body was mandatory; the moment a bodyless envelope can mint a
            //     call, `… to=commentary<|message|>` would produce a tool named `commentary`.
            //     Widening the guard to the whole `to=` path is a separate behavioural
            //     change with its own test surface — deliberately not done here.
            //
            //     `nextStart` is `blockEnd`, which is where the caller's loop would resume
            //     anyway; both callers key their next search off it, so progress is
            //     guaranteed and two bodyless envelopes in a row both resolve.
            if text[messageRange.upperBound..<blockEnd].allSatisfy(\.isWhitespace),
               !ToolCallParsingHelpers.reservedChannelNames.contains(resolvedName.lowercased())
            {
                let call = StepToolCall(
                    providerID: nil, name: resolvedName, argumentsJSON: "{}")
                return (call, blockEnd)
            }
        }

        // 3. Strategy 2: plain `{` fallback — first `{` after the name, bounded by blockEnd.
        let fallbackSearchStart = ToolCallParsingHelpers.skipWhitespace(
            in: text[nameEnd..<blockEnd], from: nameEnd)
        if let firstBrace = text[fallbackSearchStart..<blockEnd].firstIndex(of: "{"),
           let (jsonText, endIdx) = ToolCallParsingHelpers.extractJSONBracedValue(
               in: text, from: firstBrace)
        {
            let (dispatchName, dispatchArgs) = ChannelMarkerStrategy.resolveDispatch(
                channelName: resolvedName, innerJSON: jsonText)
            let call = StepToolCall(
                providerID: nil, name: dispatchName, argumentsJSON: dispatchArgs)
            return (call, endIdx)
        }

        return nil
    }
}

// MARK: - Channel Marker Strategy

/// Parses `<|channel|>` tool call formats:
/// - `<|channel|>commentary to=TOOL_NAME ...<|message|>{JSON}` (with optional quotes around TOOL_NAME)
/// - `<|channel|>final <|constrain|>TOOL_NAME<|message|>{JSON}` (tool name in constrain marker)
nonisolated struct ChannelMarkerStrategy: ToolCallParsingStrategy {
    static let channelMarker = "<|channel|>"
    static let messageMarker = "<|message|>"
    static let constrainMarker = "<|constrain|>"

    /// Format keywords that appear after `<|constrain|>` but are NOT tool names.
    private static let constrainFormatKeywords: Set<String> = [
        "json", "text", "markdown", "xml", "html", "yaml",
    ]

    static func isConstrainFormatKeyword(_ lowered: String) -> Bool {
        constrainFormatKeywords.contains(lowered)
    }

    fileprivate static var reservedChannelNames: Set<String> {
        ToolCallParsingHelpers.reservedChannelNames
    }

    func parse(from text: String) -> [StepToolCall] {
        guard text.contains(Self.channelMarker) else { return [] }

        var results: [StepToolCall] = []
        var searchStart = text.startIndex
        let tail = Substring(text)

        while let channelRange = tail.range(
            of: Self.channelMarker, range: searchStart..<tail.endIndex)
        {
            let afterChannel = channelRange.upperBound

            // Determine the boundary for this channel block (next channel marker or end)
            let blockEnd =
                tail.range(of: Self.channelMarker, range: afterChannel..<tail.endIndex)?
                    .lowerBound ?? tail.endIndex

            if let envelope = ChannelEnvelopeParser.parseEnvelope(
                in: tail, cursorAfterOpening: afterChannel, blockEnd: blockEnd)
            {
                results.append(envelope.call)
                searchStart = envelope.nextStart
                continue
            }

            searchStart = afterChannel
        }

        return results
    }

    /// When the inner `<|message|>` JSON is a canonical tool-call envelope
    /// (`{"name":X,"arguments":{…}}`), the inner `name` reflects intent more
    /// reliably than the channel `to=` header — `arguments` being explicitly
    /// present signals "I'm calling tool X with these args", whereas `to=` is a
    /// routing header that some models populate from the *previously discussed*
    /// tool. Discriminator is the SHAPE of inner JSON, not just presence of
    /// `name`:
    /// - canonical envelope (`name` AND `arguments` both top-level) → inner name
    ///   wins, args are the unwrapped `arguments` sub-object
    /// - flat payload (`{"name":"X","content":"..."}`, e.g. real `create_artifact`
    ///   emission) → inner `name` is a parameter value, channel `to=` still wins,
    ///   the full JSON becomes the args
    ///
    /// The shape gate protects flat-payload tests (see
    /// `testChannelMarker_flatPayloadWithoutArguments_usesChannelName` and the
    /// `create_artifact` family) from regressing — without the gate, every
    /// `to=create_artifact <|message|>{"name":"X",…}` would dispatch as `X`.
    static func resolveDispatch(channelName: String, innerJSON: String) -> (
        name: String, argsJSON: String
    ) {
        if let envelope = canonicalEnvelope(in: innerJSON) {
            return (envelope.name, envelope.argsJSON)
        }
        let args = ToolCallParsingHelpers.normalizeArgumentsJSONString(
            JSONUtilities.sanitizeJSONControlCharacters(innerJSON))
        return (channelName, args)
    }

    /// Returns (innerName, serialised-arguments-object) iff `innerJSON` decodes to
    /// a dictionary with BOTH a non-empty string `name` AND a dictionary
    /// `arguments` at the top level. Reserved channel names (commentary, analysis,
    /// …) are rejected — same guard `parseToolCallFromJSON` uses, so a stray
    /// `{"name":"commentary","arguments":{}}` never resolves to a fake tool.
    /// Returns nil for any other shape (e.g. `arguments` as string or array,
    /// reserved name, missing `name`), signalling the caller to fall back to
    /// channel `to=` dispatch — pinned by the `argumentsAsString` /
    /// `argumentsAsArray` / `rejectsReservedInnerName` tests.
    private static func canonicalEnvelope(in innerJSON: String) -> (name: String, argsJSON: String)?
    {
        let sanitized = JSONUtilities.sanitizeJSONControlCharacters(innerJSON)
        // `data(using: .utf8)` on a Swift String is structurally non-failing
        // (Swift strings are valid Unicode by construction). The guard arm is
        // defensive — JSON parse failure is the only realistic miss.
        guard let data = sanitized.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let name = dict["name"] as? String, !name.isEmpty,
              !ToolCallParsingHelpers.reservedChannelNames.contains(name.lowercased()),
              let argumentsObject = dict["arguments"] as? [String: Any]
        else { return nil }
        // `argumentsObject` came from `JSONSerialization.jsonObject` so
        // `stableJSONString` should always succeed. Defensive fallback returns
        // the raw inner JSON (envelope wrapper included) so downstream
        // `INVALID_ARGS` quotes the offending payload — beats silent `{}`
        // which would dispatch the right tool with no args and confuse the log.
        let argsJSON = ToolCallParsingHelpers.stableJSONString(from: argumentsObject) ?? innerJSON
        return (name, argsJSON)
    }
}

// MARK: - Composite Parser

nonisolated struct HarmonyToolCallParser: Sendable {
    static let callMarker = CallMarkerStrategy.callMarker
    static let endMarker = CallMarkerStrategy.endMarker
    static let startMarker = StartMarkerStrategy.startMarker
    static let channelMarker = ChannelMarkerStrategy.channelMarker

    /// Single source of truth for "this content contains a Harmony tool-call
    /// envelope opening." Used by the streamer to flip into `harmonyBuffer` mode, and as
    /// the gate that decides whether recovery belongs to this parser or to
    /// `BareToolCallSalvage` — a marker present means the model committed to a call and
    /// the failure can be NAMED; absent, intent itself is what's in question. Keep bare
    /// `<|start|>` here — the function-prefix variant is a subset and adding both would
    /// be redundant.
    static let harmonyMarkers: [String] = [callMarker, startMarker, channelMarker]

    /// Longest verbatim marker, in characters — one input to
    /// `StreamMarkerWindow.harmonyNeedleSpan`, which bounds how far back the
    /// per-delta detection must look for a marker split across deltas.
    static let maxMarkerLength = harmonyMarkers.map(\.count).max() ?? 0

    private let strategies: [ToolCallParsingStrategy]

    static func defaultStrategies() -> [ToolCallParsingStrategy] {
        [CallMarkerStrategy(), StartMarkerStrategy(), ChannelMarkerStrategy()]
    }

    init(strategies: [ToolCallParsingStrategy] = HarmonyToolCallParser.defaultStrategies()) {
        self.strategies = strategies
    }

    func extractAllToolCalls(from text: String) -> [StepToolCall] {
        var results: [StepToolCall] = []

        // Repair a mangled OPENING sentinel first — every strategy below is gated on an
        // exact `<|call|>` / `<|start|>` / `<|channel|>` substring, so a spliced
        // `<|tool_call>call|>` reaches none of them. Normalizing at the parser (not only
        // at the streaming detection point) is what covers the callers that parse a
        // finished body with no marker-detection pass of their own: `TeamGenerationService`
        // and `DelegatedSupervisorAnswerService`. Idempotent, and a no-op for text without
        // the alien token.
        let text = HarmonySentinelNormalizer.normalize(text)

        func key(for call: StepToolCall) -> String {
            call.name.lowercased() + "|" + call.argumentsJSON
        }

        for strategy in strategies {
            let calls = strategy.parse(from: text)
            guard !calls.isEmpty else { continue }
            if results.isEmpty {
                results = calls
            } else {
                let existing = Set(results.map(key))
                for call in calls where !existing.contains(key(for: call)) {
                    results.append(call)
                }
            }
        }

        return results
    }
}
