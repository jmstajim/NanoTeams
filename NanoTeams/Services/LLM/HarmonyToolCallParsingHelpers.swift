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
    static let maxSalvageDepth = 3

    static func extractJSONBracedValue(in s: Substring, from index: String.Index) -> (
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

        var end = i
        while end < s.endIndex {
            let ch = s[end]

            if inString {
                if escape {
                    escape = false
                } else if ch == "\\" {
                    escape = true
                } else if ch == "\"" {
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
                    if depth == 0 {
                        let jsonText = String(s[i...end])
                        let next = s.index(after: end)
                        return (jsonText, next)
                    }
                }
            }

            end = s.index(after: end)
        }

        // Walker reached end with unbalanced braces. Some models emit
        // `<|call|>{"name":"X","arguments":{…}<|end|>` — missing the outer `}`.
        // Salvage by truncating at the last `}`/`]` we saw (any depth) and padding
        // with synthetic closers. `maxSalvageDepth` guards against truly garbled
        // input; `lastCloseEnd != nil` guards against input with no observed
        // structure.
        if !inString, depth > 0, depth <= Self.maxSalvageDepth, let truncate = lastCloseEnd {
            let salvaged = String(s[i..<truncate]) + String(repeating: "}", count: depth)
            return (salvaged, truncate)
        }

        return nil
    }

    static func advanceCursor(
        in s: Substring, from index: String.Index, endMarker: String
    ) -> String.Index {
        if let endRange = s.range(of: endMarker, range: index..<s.endIndex) {
            return endRange.upperBound
        }
        return index
    }

    static func normalizeArgumentsJSONString(_ jsonText: String) -> String {
        guard let data = jsonText.data(using: .utf8) else { return jsonText }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return jsonText
        }
        if let dict = object as? [String: Any], let s = stableJSONString(from: dict) { return s }
        if let arr = object as? [Any], let s = stableJSONString(from: arr) { return s }
        return jsonText
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
        } else if let repairedDict = parseAfterRepair(sanitized) {
            // Strict parse failed. Apply known model-defect repairs and retry —
            // the program covers the model's weakness rather than asking it to
            // fix what it can't see (CORE_PRINCIPLES). When a repair succeeds,
            // the tool call dispatches normally and the model never knows its
            // first-emit JSON was broken.
            dict = repairedDict
        } else {
            return nil
        }

        let providerID = stringValue(dict["id"]) ?? stringValue(dict["call_id"])

        // Reserved-name guard applies to every shape below, not just the bare-identifier
        // path in `CallMarkerStrategy`. Without this, `{"name":"commentary",...}`
        // would bypass the marker-level filter and reach dispatch as a tool call.
        func acceptingName(_ name: String) -> String? {
            reservedChannelNames.contains(name.lowercased()) ? nil : name
        }

        if let name = stringValue(dict["name"]).flatMap(acceptingName) {
            let args = dict["arguments"] ?? dict["args"] ?? dict["parameters"] ?? dict["params"]
                ?? synthesizeArgumentsFromTopLevel(dict)
            return StepToolCall(
                providerID: providerID, name: name, argumentsJSON: normalizeArgumentsJSON(args))
        }

        if let toolName = (stringValue(dict["tool_name"]) ?? stringValue(dict["tool"])
            ?? stringValue(dict["function_name"])).flatMap(acceptingName)
        {
            let args = dict["arguments"] ?? dict["args"] ?? dict["parameters"] ?? dict["params"]
                ?? synthesizeArgumentsFromTopLevel(dict)
            return StepToolCall(
                providerID: providerID, name: toolName, argumentsJSON: normalizeArgumentsJSON(args))
        }

        if let fnDictAny = dict["function"] as? [String: Any],
            let fnName = stringValue(fnDictAny["name"]).flatMap(acceptingName)
        {
            let argsAny = fnDictAny["arguments"] ?? fnDictAny["args"]
            return StepToolCall(
                providerID: providerID, name: fnName, argumentsJSON: normalizeArgumentsJSON(argsAny)
            )
        }

        // Shape-based fallback: some models emit `{"arguments":{…}}` without a
        // top-level tool name — the `name` field lives inside `arguments` as a
        // tool parameter (e.g. artifact name for create_artifact). Infer the
        // tool from the argument signature when it's unambiguous.
        if let inferred = inferToolNameFromShape(dict) {
            return StepToolCall(
                providerID: providerID,
                name: inferred.name,
                argumentsJSON: normalizeArgumentsJSON(inferred.arguments))
        }

        return nil
    }

    /// When a tool call dict has a recognized name but no `arguments`/`args`/`parameters`/
    /// `params` key, gather all remaining top-level keys (excluding identifier/envelope
    /// fields) into a synthetic arguments dict.
    ///
    /// Handles model variants that emit the spec-violating shape
    /// `{"name":"X","content":"…"}` instead of the canonical
    /// `{"name":"X","arguments":{"content":"…"}}`. Observed in `gemma-4-26b-a4b`
    /// and similar models that emit tool args at the top level: the model puts
    /// `content` next to `name`, parser without this fallback sees `arguments`
    /// missing → tool receives empty args → returns `INVALID_ARGS` → model loops
    /// retrying the same broken format. With this synthesis the call resolves.
    ///
    /// Returns nil when there are no promotable keys (so the caller falls back to
    /// the existing nil-args path, which serialises to "").
    ///
    /// Return type is `Any?` (not `[String:Any]?`) so it composes cleanly with
    /// `dict["arguments"] ?? dict["args"] ?? … ?? synthesizeArgumentsFromTopLevel(dict)`
    /// in the parser. Mixing `Any?` with `[String:Any]?` in a `??` chain causes Swift
    /// to wrap the dict-optional as `Any.some(Optional<…>.none)`, which then bypasses
    /// `normalizeArgumentsJSON`'s nil-guard and falls through to `String(describing:)`
    /// — producing the literal string `"nil"` as `argumentsJSON`. Keeping the return
    /// `Any?` avoids that subtle double-wrap.
    static func synthesizeArgumentsFromTopLevel(_ dict: [String: Any]) -> Any? {
        // Keys that identify or wrap the call envelope itself — never promote them.
        // The four args-keys (`arguments`/`args`/`parameters`/`params`) are listed
        // for completeness even though synthesis only fires when they're absent.
        // Harmony framing fields (`type`/`channel`/`recipient`/`constrain`) and
        // OpenAI tool-call envelope fields (`type:"function"`) are also reserved
        // — promoting them would inject `{"type":"function", ...}` into a
        // tool's args dict and cause `INVALID_ARGS` rejections or, worse, silent
        // acceptance of garbage.
        let reserved: Set<String> = [
            "name", "tool_name", "tool", "function_name",
            "id", "call_id", "function",
            "arguments", "args", "parameters", "params",
            "type", "channel", "recipient", "constrain",
        ]
        let promoted = dict.filter { !reserved.contains($0.key) }
        return promoted.isEmpty ? nil : promoted
    }

    /// Fallback tool-name inference when no top-level identifier is present.
    /// Conservative: only fires on an unambiguous argument signature. Today this
    /// recognises `create_artifact` wrapped as `{"arguments":{…}}` — a pattern
    /// some local models produce when the top-level envelope is stripped.
    ///
    /// Returns `(toolName, unwrappedArguments)` on success — the caller serialises
    /// `unwrappedArguments` as the StepToolCall's `argumentsJSON`.
    static func inferToolNameFromShape(_ dict: [String: Any]) -> (name: String, arguments: Any?)? {
        if let inner = dict["arguments"] as? [String: Any],
           let name = recognizeToolFromArguments(inner) {
            return (name: name, arguments: inner)
        }
        return nil
    }

    /// Keys that unambiguously belong to a non-`create_artifact` tool. If any
    /// match, inference refuses to guess — the caller falls through to the
    /// generic "name missing" nudge rather than dispatching a wrong tool.
    private static let keysExclusiveToOtherTools: Set<String> = [
        "path", "old_text", "new_text",                 // file tools
        "question", "teammate",                         // supervisor / consultation
        "query",                                        // search
        "scheme",                                       // xcodebuild
        "topic", "participants",                        // request_team_meeting
        "target_role", "changes", "reasoning",          // request_changes
        "image_path", "prompt",                         // analyze_image
    ]

    private static func recognizeToolFromArguments(_ args: [String: Any]) -> String? {
        let keys = Set(args.keys)
        guard keys.isDisjoint(with: keysExclusiveToOtherTools) else { return nil }
        // Require BOTH of create_artifact's mandatory fields. `format` alone is
        // too generic — any future tool that accepts it would silently be
        // dispatched as create_artifact.
        guard keys.contains("name"), keys.contains("content") else { return nil }
        return "create_artifact"
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

    private static func stringValue(_ any: Any?) -> String? {
        guard let any else { return nil }
        if let s = any as? String, !s.isEmpty { return s }
        return nil
    }

    // MARK: - Defect Repair (covers known model weaknesses)

    /// Counts how many times `parseAfterRepair` recovered a parseable envelope
    /// from a strict-broken payload. Bumped on every successful repair, never
    /// on no-op transforms. Read via `repairFireCount` for diagnostics; reset
    /// via `_resetRepairFireCount()` in tests.
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

    /// Applies all known repair patterns. Pure string transform — does NOT
    /// validate the result. The caller re-parses with `JSONSerialization` and
    /// falls back to `nil` if repair didn't help. Both repairs are idempotent
    /// on already-fixed input, so the order is not load-bearing today.
    static func repairCommonJSONDefects(_ raw: String) -> String {
        var s = raw
        s = repairUnescapedHTMLAttributeClose(s)
        s = repairMissingQuoteBeforeJSONKey(s)
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
    /// Detection: a JSON property separator (`{` or `,`) followed *directly*
    /// (no intervening `"`) by an unquoted identifier-shape token, then a
    /// closing `":`. Identifier shape (`[A-Za-z_][A-Za-z0-9_]*`) is narrow
    /// enough to avoid matching free-text inside string values; the trailing
    /// `":` confirms the model intended this as a key.
    ///
    /// Replacement re-inserts the missing opening quote.
    static func repairMissingQuoteBeforeJSONKey(_ raw: String) -> String {
        // Same try!-on-compile-time-literal rationale as above.
        let regex = try! NSRegularExpression(pattern: #"([{,])([A-Za-z_][A-Za-z0-9_]*)":"#)
        let range = NSRange(raw.startIndex..., in: raw)
        return regex.stringByReplacingMatches(
            in: raw, range: range, withTemplate: #"$1"$2":"#)
    }

    // MARK: - Nudge Classification

    /// Classifies *why* a Harmony-markered response produced no parsed tool call.
    /// The step-flow-control nudge uses this to choose a retry message that
    /// actually names the defect, instead of always blaming "malformed JSON".
    enum HarmonyCallIssue: Equatable {
        /// Markers were seen (e.g. `<|channel|>`) but no `<|call|>{…}<|end|>` block
        /// was present, or the block's JSON couldn't be parsed at all.
        case malformedJSON
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

    /// Scans the assistant's text for the first `<|call|>…<|end|>` block and
    /// reports the nature of the parse failure. Safe to call on responses where
    /// only `<|channel|>` markers appear (returns `.malformedJSON`).
    static func classifyHarmonyCallIssue(in text: String) -> HarmonyCallIssue {
        if containsOnlyRoleMarkerStarts(in: text) {
            return .noEnvelopeAttempt
        }
        let callMarker = CallMarkerStrategy.callMarker
        guard let callRange = text.range(of: callMarker) else { return .malformedJSON }

        let tail = text[callRange.upperBound...]
        let jsonStart = skipWhitespace(in: tail, from: tail.startIndex)
        guard jsonStart < tail.endIndex, tail[jsonStart] == "{" else {
            return .malformedJSON
        }
        guard let (jsonText, _) = extractJSONBracedValue(in: tail, from: jsonStart) else {
            return .malformedJSON
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

        return .missingToolName(inferredToolName: inferToolNameFromShape(dict)?.name)
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
