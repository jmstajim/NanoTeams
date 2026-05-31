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
