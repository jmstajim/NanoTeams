import Foundation
import Synchronization

/// Pure, stateless parsing/decoding of a `create_team` `team_config` payload
/// into a `GeneratedTeamBuilder.BuildResult`.
///
/// Owns everything between "raw model output string" and "validated team":
/// fenced/balanced-brace JSON extraction, wrapper unwrapping (tool-call shapes,
/// nested `team_config`, JSON-encoded inner strings), misplaced-sibling merge,
/// and the model-defect repair chain (interior unescaped quotes, missing array
/// close, double-escaped inner JSON). Separated from `TeamGenerationService`,
/// which owns the LLM call, the 3-path cascade, diagnostics, and the prompt.
///
/// Throws `TeamGenerationService.GenerationError` so the orchestrator's error
/// vocabulary stays single-sourced.
nonisolated enum TeamConfigParser {

    // MARK: - JSON Object Extraction

    /// Fenced blocks are a stronger signal of intent than the first balanced object,
    /// since models often wrap JSON in explanatory prose.
    static func extractJSONObject(from text: String) -> String? {
        // Prefer the first ```json code block when present.
        if let fence = text.range(of: "```json", options: .caseInsensitive),
           let closing = text.range(of: "```", range: fence.upperBound..<text.endIndex) {
            let inner = String(text[fence.upperBound..<closing.lowerBound])
            if let obj = scanBalancedObject(in: inner) { return obj }
        }
        // Any ``` fenced block.
        if let fence = text.range(of: "```"),
           let afterFence = text.index(fence.upperBound, offsetBy: 0, limitedBy: text.endIndex),
           let closing = text.range(of: "```", range: afterFence..<text.endIndex) {
            let inner = String(text[afterFence..<closing.lowerBound])
            if let obj = scanBalancedObject(in: inner) { return obj }
        }
        // Raw scan.
        return scanBalancedObject(in: text)
    }

    /// Respects string boundaries and `\` escapes so braces inside string literals
    /// don't perturb the depth counter.
    ///
    /// **Truncation salvage**: when the scanner reaches EOF with an unbalanced open
    /// object (`0 < depth ≤ 3`) and we're not stuck mid-string, pad the result
    /// with synthetic closing braces. Motivated by LM Studio / gpt-oss-20b
    /// occasionally truncating the stream mid-envelope — e.g. 1013 chars ending
    /// at `…]}"}` with final depth 1 (missing the outer `}`). Depth cap mirrors
    /// the policy in `ToolCallParsingHelpers.extractJSONBracedValue`.
    private static let maxSalvageDepth = 3
    private static func scanBalancedObject(in text: String) -> String? {
        var depth = 0
        var startIndex: String.Index?
        var inString = false
        var isEscaped = false
        var lastCloseEnd: String.Index?
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if isEscaped { isEscaped = false; i = text.index(after: i); continue }
            if inString {
                if c == "\\" { isEscaped = true }
                else if c == "\"" { inString = false }
            } else {
                switch c {
                case "\"": inString = true
                case "{":
                    if depth == 0 { startIndex = i }
                    depth += 1
                case "}":
                    depth -= 1
                    lastCloseEnd = text.index(after: i)
                    if depth == 0, let start = startIndex {
                        return String(text[start...i])
                    }
                default: break
                }
            }
            i = text.index(after: i)
        }
        // Salvage path: truncated stream with a shallow unbalanced open object.
        // Prefer the span up to the last observed `}` (dropping trailing junk),
        // then append synthetic closes.
        if !inString, let start = startIndex, depth > 0, depth <= maxSalvageDepth {
            let endIndex = lastCloseEnd ?? text.endIndex
            let body = String(text[start..<endIndex])
            return body + String(repeating: "}", count: depth)
        }
        return nil
    }

    // MARK: - Decode

    static func decodeTeamConfig(from argumentsJSON: String) throws -> GeneratedTeamBuilder.BuildResult {
        // Strict parse first; if that fails AND the input contains a `team_config`
        // wrapper, extract the inner JSON by brace-depth (ignoring quote state)
        // and decode that directly. Handles gpt-oss-20b inconsistently escaping
        // interior quotes — e.g. `"tools\":["read_file","write_file"]` mixed with
        // properly-escaped neighbors — which corrupts the outer string boundary.
        let dict: [String: Any]
        if let parsed = JSONUtilities.parseJSONDictionary(argumentsJSON) {
            dict = parsed
        } else if let extracted = extractInnerTeamConfig(from: argumentsJSON),
                  let parsed = parseDictionaryStripping(extracted) {
            // Inner extraction path: skip wrapper unwrapping, treat as flat config.
            return try decodeFromConfigDict(parsed)
        } else if let parsed = parseDictionaryStripping(argumentsJSON) {
            // No `team_config` substring for the extractor to isolate — e.g. a
            // model that returned the config as bare content (no tool-call
            // wrapper) with a dropped structural closer. Run the full repair
            // chain on the WHOLE payload, then unwrap normally. Without this a
            // wrapper-less single-drop config would throw even though the repair
            // could recover it.
            dict = parsed
        } else {
            throw TeamGenerationService.GenerationError.invalidResponse("Could not parse tool arguments as JSON")
        }

        // Accept multiple wrapper shapes the LLM may emit:
        //   1. `{team_config: {...}}`               — canonical nested form
        //   2. `{...}`                              — flat form
        //   3. `{create_team: {team_config: {...}}}` or `{create_team: {...}}` — tool-name wrapper
        //   4. `{name: "create_team", arguments: {team_config: {...}}}` — raw tool-call shape
        return try decodeFromConfigDict(Self.unwrapTeamConfig(dict))
    }

    private static func decodeFromConfigDict(_ configDict: [String: Any]) throws -> GeneratedTeamBuilder.BuildResult {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: configDict)
        } catch {
            throw TeamGenerationService.GenerationError.invalidResponse(error.localizedDescription)
        }

        let decoder = JSONCoderFactory.makeWireDecoder()
        let config: GeneratedTeamConfig
        do {
            config = try decoder.decode(GeneratedTeamConfig.self, from: data)
        } catch {
            throw TeamGenerationService.GenerationError.invalidResponse(describeDecodingError(error))
        }

        return GeneratedTeamBuilder.build(from: config)
    }

    /// Surface `DecodingError.codingPath` and `debugDescription` for trainer / UI
    /// diagnostics. `error.localizedDescription` on a `DecodingError` collapses
    /// to the generic `"The data couldn't be read because it isn't in the
    /// correct format."` — useless when triaging which specific field a model
    /// emitted incorrectly. This helper preserves the path and the throw-site
    /// `debugDescription` (which carries the DTO's own enum-allowed-values text
    /// for `.dataCorrupted` cases). Non-`DecodingError` errors fall through to
    /// `localizedDescription`.
    static func describeDecodingError(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return error.localizedDescription
        }
        let context: DecodingError.Context
        let prefix: String
        switch decodingError {
        case .typeMismatch(let type, let ctx):
            context = ctx
            prefix = "Type mismatch (expected \(type))"
        case .valueNotFound(let type, let ctx):
            context = ctx
            prefix = "Value not found (expected \(type))"
        case .keyNotFound(let key, let ctx):
            context = ctx
            prefix = "Key not found: \(key.stringValue)"
        case .dataCorrupted(let ctx):
            context = ctx
            prefix = "Data corrupted"
        @unknown default:
            return error.localizedDescription
        }
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        let pathSegment = path.isEmpty ? "" : " at `\(path)`"
        return "\(prefix)\(pathSegment): \(context.debugDescription)"
    }

    // MARK: - Wrapper Unwrapping

    /// When the OUTER JSON parse fails because the LLM inconsistently escaped
    /// interior quotes inside the `team_config` string envelope, search for
    /// the literal substring `"team_config":"` and walk forward by **brace
    /// depth alone** (ignoring quote tracking) to find the inner JSON object.
    /// Then JSON-string-unescape the captured span.
    ///
    /// Why brace-depth-only: the model has corrupted quote semantics here, so
    /// we can't trust `inString`. The risk is over-counting if an inner string
    /// value contains a literal `{` or `}` (rare in team configs).
    static func extractInnerTeamConfig(from s: String) -> String? {
        // Two wrapper shapes are observed in failing payloads:
        //   `"team_config":"{…}"`  — string-encoded inner JSON (decode escapes after extraction)
        //   `"team_config":{…}`    — object-form (no escape decode needed)
        let stringForm = s.range(of: "\"team_config\":\"")
        let objectForm = s.range(of: "\"team_config\":{")
        let needsUnescape: Bool
        let searchAfter: String.Index
        if let r = stringForm, (objectForm == nil || r.lowerBound < objectForm!.lowerBound) {
            needsUnescape = true
            searchAfter = r.upperBound
        } else if let r = objectForm {
            needsUnescape = false
            searchAfter = r.lowerBound  // the `{` is part of this match
        } else {
            return nil
        }
        // Find the first `{` from searchAfter — start of inner JSON.
        var pos = searchAfter
        while pos < s.endIndex, s[pos] != "{" { pos = s.index(after: pos) }
        guard pos < s.endIndex else { return nil }
        let innerStart = pos
        var depth = 0
        while pos < s.endIndex {
            let c = s[pos]
            if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 {
                    let captured = String(s[innerStart...pos])
                    return needsUnescape ? reUnescapeInnerJSON(captured) : captured
                }
            }
            pos = s.index(after: pos)
        }
        return nil
    }

    /// Peels tool-call envelopes until we find the dict that looks like the
    /// team config (has top-level `name` + `roles`). Handles models that emit
    /// `<|call|>{"create_team":{...}}` or the full OpenAI tool-call shape
    /// `{"name":"create_team","arguments":{"team_config":{...}}}` as bare JSON.
    private static func unwrapTeamConfig(_ dict: [String: Any]) -> [String: Any] {
        // Raw tool-call shape: {name: "create_team", arguments: {...}}
        if let name = dict["name"] as? String,
           name == ToolNames.createTeam,
           let args = dict["arguments"] as? [String: Any] {
            return unwrapTeamConfig(args)
        }
        // Partial tool-call shape: {arguments: {...}} — some models emit the
        // arguments envelope without the `name` field (observed on gpt-oss-20b).
        // Only recurse if `team_config` is present inside — otherwise an
        // accidental top-level `arguments` key would swallow a real team config.
        if let args = dict["arguments"] as? [String: Any],
           args["team_config"] != nil {
            return unwrapTeamConfig(args)
        }
        // gpt-oss/Harmony: team_config is sometimes a JSON-encoded string
        // (e.g. `"team_config":"{\"name\":...}"`). Parse and recurse.
        // A subset of models (observed on gpt-oss-20b) additionally double-escape
        // the inner JSON — so after the outer parse the string still contains
        // literal `\n`, `\"`, `\t` escape sequences that must be unescaped once
        // more before the inner JSON becomes parseable.
        if let encoded = dict["team_config"] as? String {
            if let parsed = parseDictionaryStripping(encoded) {
                return unwrapTeamConfig(parsed)
            }
            // Some models doubly-escape the inner JSON; unescape once more.
            let reUnescaped = reUnescapeInnerJSON(encoded)
            if let parsed = parseDictionaryStripping(reUnescaped) {
                return unwrapTeamConfig(parsed)
            }
        }
        // Nested team_config — possibly with misplaced sibling fields at the
        // wrapper level. `qwen3.5-9b-mlx` defect: emits supervisor_requires
        // (and occasionally other canonical team_config-level fields) as a
        // sibling of `team_config` instead of inside it. Merge sibling values
        // into the inner dict before returning so the user's intent isn't
        // silently dropped — without this, `decodeTeamConfig` sees an empty
        // `supervisor_requires` and only the auto-promote-orphans path can
        // recover, which misses any artifact that already has consumers.
        if let nested = dict["team_config"] as? [String: Any] {
            return mergeMisplacedSiblings(into: nested, from: dict)
        }
        // Single-key tool-name wrapper: {create_team: {...}}
        if let wrapped = dict[ToolNames.createTeam] as? [String: Any] {
            return unwrapTeamConfig(wrapped)
        }
        return dict
    }

    /// Canonical top-level keys of `team_config` per `GeneratedTeamConfig.CodingKeys`.
    /// MUST stay in sync with that enum — if `GeneratedTeamConfig` gains a new
    /// top-level field, add it here too so misplacements of the new field are
    /// recovered. Narrow whitelist (not "any sibling key") — anything outside this
    /// list is unrelated junk and must NOT be promoted into team_config or it
    /// would surface as `DecodingError` (unknown key) or, worse, silently bypass
    /// validation if `GeneratedTeamConfig` ever adopts permissive decoding.
    static let teamConfigSiblingKeys: Set<String> = [
        "name", "description",
        "supervisor_mode", "acceptance_mode",
        "roles", "artifacts", "supervisor_requires",
    ]

    /// Merges canonical sibling fields that the model misplaced at the wrapper
    /// level (next to `team_config`) into the inner team_config dict.
    /// Inside-team_config wins on conflict — if the model put the same key both
    /// inside and outside, the inside value is authoritative (the model probably
    /// only typo'd one of them; the structurally correct location takes priority).
    /// Idempotent: a second pass on already-merged input is a no-op.
    static func mergeMisplacedSiblings(
        into inner: [String: Any], from wrapper: [String: Any]
    ) -> [String: Any] {
        var merged = inner
        var didMerge = false
        for key in teamConfigSiblingKeys where wrapper[key] != nil && merged[key] == nil {
            merged[key] = wrapper[key]
            didMerge = true
        }
        if didMerge { _bumpSiblingMergeFireCount() }
        return merged
    }

    // MARK: - Sibling-merge diagnostics counter

    /// Counts how many times `mergeMisplacedSiblings` actually moved at least one
    /// canonical key from a wrapper into the inner team_config. Bumped on real
    /// merges only — calls where the inner dict already has every sibling key
    /// (or where the wrapper has none) do NOT bump. Process-global, the same
    /// shape as `ToolCallParsingHelpers.repairFireCount` — granularity is
    /// "total fires across the run of the app", which is what the train-app
    /// audit pass needs.
    private static let _siblingMergeFireCount = Atomic<Int>(0)

    /// Number of times the sibling-merge fix successfully recovered a misplaced
    /// canonical field. Read-only; reset via `_resetSiblingMergeFireCount()` in tests.
    static var siblingMergeFireCount: Int {
        _siblingMergeFireCount.load(ordering: .relaxed)
    }

    #if DEBUG
    static func _resetSiblingMergeFireCount() {
        _siblingMergeFireCount.store(0, ordering: .relaxed)
    }
    #endif

    private static func _bumpSiblingMergeFireCount() {
        _siblingMergeFireCount.wrappingAdd(1, ordering: .relaxed)
    }

    // MARK: - Defect Repair (covers known model weaknesses)

    /// Tries to parse `s` as a JSON dictionary. Attempts, in order:
    ///   1. strict parse,
    ///   2. parse the first balanced `{...}` span (strips trailing junk like an
    ///      extra `}` the LLM appended after the legitimate close),
    ///   3. repair interior unescaped `"` inside string values and re-parse.
    /// Observed on gpt-oss-20b: role prompts routinely contain unescaped quotes
    /// (`"Produce a "Decision Memo" artifact."`) which terminate the string
    /// prematurely for `JSONSerialization`.
    private static func parseDictionaryStripping(_ s: String) -> [String: Any]? {
        if let parsed = JSONUtilities.parseJSONDictionary(s) { return parsed }
        if let trimmed = scanBalancedObject(in: s),
           let parsed = JSONUtilities.parseJSONDictionary(trimmed) {
            return parsed
        }
        let repaired = repairUnescapedInteriorQuotes(s)
        if let parsed = JSONUtilities.parseJSONDictionary(repaired) { return parsed }
        if let trimmed = scanBalancedObject(in: repaired),
           let parsed = JSONUtilities.parseJSONDictionary(trimmed) {
            return parsed
        }
        if let injected = repairMissingArrayClose(s),
           let parsed = JSONUtilities.parseJSONDictionary(injected) {
            return parsed
        }
        if let injected = repairMissingArrayClose(repaired),
           let parsed = JSONUtilities.parseJSONDictionary(injected) {
            return parsed
        }
        // Single dropped structural closer at the roles boundary (Type A/B) —
        // the general repair `repairMissingArrayClose`'s `"}]` case does not cover.
        if let injected = repairStructuralCloserDrop(s),
           let parsed = JSONUtilities.parseJSONDictionary(injected) {
            return parsed
        }
        if let injected = repairStructuralCloserDrop(repaired),
           let parsed = JSONUtilities.parseJSONDictionary(injected) {
            return parsed
        }
        // No trailing-comma repair here on purpose. `JSONSerialization` accepts trailing
        // commas (pinned by `TeamConfigParserTests.testJSONSerialization_toleratesTrailingCommas`)
        // and `decodeFromConfigDict` re-serialises the dictionary before the strict
        // `JSONDecoder` sees anything, so such a repair could never fire — it would only add
        // two full-string passes to a path that has already failed six repairs for some
        // OTHER reason. When that pin goes red, add the repair back, composed with the
        // structural repairs above rather than only with `s`/`repaired`.
        return nil
    }

    /// Repairs the `"string"}]` → `"string"]}]` pattern: some models drop the
    /// inner array's closing `]` and jump straight to the outer object-close
    /// `}` and array-close `]`. Insert the missing `]` between the string and
    /// the `}`.
    ///
    /// The substring `"}]` also appears LEGITIMATELY when closing an array of
    /// objects whose last field has a string value (`[{"a":"b"}]`). Blanket
    /// replacement corrupts those. Instead try replacing each `"}]` occurrence
    /// INDEPENDENTLY (leaving the others untouched) and return the first
    /// candidate that parses. This isolates the buggy site from valid sites.
    /// Returns `nil` if no candidate parses or the pattern is not present.
    static func repairMissingArrayClose(_ s: String) -> String? {
        var positions: [String.Index] = []
        var cursor = s.startIndex
        while cursor < s.endIndex,
              let match = s.range(of: "\"}]", range: cursor..<s.endIndex) {
            positions.append(match.lowerBound)
            cursor = match.upperBound
        }
        guard !positions.isEmpty else { return nil }
        for pos in positions {
            let end = s.index(pos, offsetBy: 3)
            let candidate = s.replacingCharacters(in: pos..<end, with: "\"]}]")
            if JSONUtilities.parseJSONDictionary(candidate) != nil { return candidate }
        }
        return nil
    }

    /// Recovers from a SINGLE dropped structural closer (`}` or `]`) that the
    /// model emitted mid-payload — in practice at the `roles` array boundary —
    /// while STILL emitting a compensating extra closer at the very end. Brace
    /// COUNT then balances but POSITION is wrong, which defeats the `{`-only
    /// `scanBalancedObject` (it reaches depth 0 on a structurally-invalid span).
    ///
    /// Walks `s` string/escape-aware with a `{`/`[` stack and, at the FIRST
    /// structural mismatch, inserts the one correct missing closer:
    ///   - `]` while an object is open → the object lost its `}`
    ///     (Type A: `…["x"]]` → `…["x"]}]`)
    ///   - `}` while an array is open  → the array lost its `]`
    ///     (subsumes `repairMissingArrayClose`: `…["x"}]` → `…["x"]}]`)
    ///   - `:` while an array is open  → the array lost its `]` before a stray
    ///     key (Type B: `…{…},"artifacts":…` → `…{…}],"artifacts":…`)
    /// then trims the compensating trailing closer via `scanBalancedObject` and
    /// returns the candidate ONLY if it now parses. Returns `nil` when the input
    /// is already well-formed (no mismatch) or when a single insertion doesn't
    /// recover it (more than one drop — deliberately out of scope).
    ///
    /// Observed on `qwen3.5-35b-a3b`, which drops exactly one closer at the roles
    /// boundary on ~45% of corpus cases (3 unhandled variants beyond the `"}]`
    /// case `repairMissingArrayClose` already covered). Runs AFTER
    /// `repairMissingArrayClose` in the chain, so R4's pinned behavior is
    /// untouched — this is additive coverage for the two new variants.
    static func repairStructuralCloserDrop(_ s: String) -> String? {
        let chars = Array(s)
        var stack: [Character] = []
        var inString = false
        var isEscaped = false
        var arrayCommaIndex: Int?     // most recent `,` while an array is top-of-stack
        var lastStringOpenIndex: Int? // start of the most recently opened top-level string
        var insertAt: Int?
        var closer: Character = "}"
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if isEscaped { isEscaped = false; i += 1; continue }
            if inString {
                if c == "\\" { isEscaped = true }
                else if c == "\"" { inString = false }
                i += 1
                continue
            }
            switch c {
            case "\"":
                inString = true
                lastStringOpenIndex = i
            case "{", "[":
                stack.append(c)
                arrayCommaIndex = nil
            case "}":
                if stack.last == "{" { stack.removeLast(); arrayCommaIndex = nil }
                else if stack.last == "[" { insertAt = i; closer = "]" }
                // else: excess `}` (trailing junk) — not our drop, ignore.
            case "]":
                if stack.last == "[" { stack.removeLast(); arrayCommaIndex = nil }
                else if stack.last == "{" { insertAt = i; closer = "}" }
                // else: excess `]` — ignore.
            case ":":
                if stack.last == "[" {
                    // A key:value inside an array is impossible — the array's `]`
                    // was dropped before the preceding key. Close it before the
                    // separating `,` (or, absent one, before the key itself).
                    insertAt = arrayCommaIndex ?? lastStringOpenIndex
                    closer = "]"
                }
            case ",":
                if stack.last == "[" { arrayCommaIndex = i }
            default:
                break
            }
            if insertAt != nil { break }
            i += 1
        }
        guard let at = insertAt, at <= chars.count else { return nil }
        let candidate = String(chars[0..<at]) + String(closer) + String(chars[at...])
        let trimmed = scanBalancedObject(in: candidate) ?? candidate
        return JSONUtilities.parseJSONDictionary(trimmed) != nil ? trimmed : nil
    }

    /// Escapes `"` characters that appear inside string values but shouldn't
    /// have closed the enclosing string. Heuristic: when we see `"` while
    /// `inString`, look ahead past whitespace. If the next non-whitespace char
    /// is a structural JSON token (`,`, `}`, `]`, `:`) or EOF, treat as a
    /// proper close. Otherwise, insert `\` before the quote to escape it.
    ///
    /// Motivation: gpt-oss-20b emits role prompts with raw interior quotes
    /// (`"Produce a "Decision Memo" artifact."`). Standard JSON parsing fails,
    /// but the intent is obvious and recoverable.
    static func repairUnescapedInteriorQuotes(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.count)
        var inString = false
        var isEscaped = false
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if isEscaped {
                result.append(c)
                isEscaped = false
                i += 1
                continue
            }
            if inString {
                if c == "\\" {
                    result.append(c)
                    isEscaped = true
                    i += 1
                    continue
                }
                if c == "\"" {
                    // Lookahead past whitespace.
                    var j = i + 1
                    while j < chars.count, chars[j].isWhitespace { j += 1 }
                    let isProperClose = j >= chars.count || "},]:".contains(chars[j])
                    if isProperClose {
                        result.append(c)
                        inString = false
                    } else {
                        result.append("\\")
                        result.append(c)
                    }
                    i += 1
                    continue
                }
                result.append(c)
                i += 1
                continue
            }
            // Outside a string.
            if c == "\"" { inString = true }
            result.append(c)
            i += 1
        }
        return result
    }

    /// Applies one more round of JSON string unescaping to a value that has
    /// already been decoded from an outer JSON but still contains literal escape
    /// sequences (`\n`, `\"`, `\t`, `\r`, `\\`). Used to repair doubly-escaped
    /// nested JSON observed from models like gpt-oss-20b.
    ///
    /// Order matters: `\\` is replaced LAST so that an input `\\n` (which means
    /// the user actually wants a literal backslash followed by `n`) is preserved
    /// rather than being collapsed first into `\n` and then into a newline.
    static func reUnescapeInnerJSON(_ s: String) -> String {
        var result = s.replacingOccurrences(of: "\\\"", with: "\"")
        result = result.replacingOccurrences(of: "\\n", with: "\n")
        result = result.replacingOccurrences(of: "\\t", with: "\t")
        result = result.replacingOccurrences(of: "\\r", with: "\r")
        result = result.replacingOccurrences(of: "\\/", with: "/")
        result = result.replacingOccurrences(of: "\\\\", with: "\\")
        return result
    }
}
