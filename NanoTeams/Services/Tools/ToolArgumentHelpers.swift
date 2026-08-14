import Foundation

// MARK: - Reentrant Envelope Unwrap

/// Unwraps self-referential tool call envelopes.
///
/// When the Harmony parser already extracted a tool name, some models still
/// emit the full envelope at the args level:
/// `{"name": "<toolName>", "arguments": {...real args...}}`.
/// A handler dispatched for `<toolName>` would then take the literal `name`
/// key as a user-supplied argument — without this guard, `create_artifact`
/// could be invoked with the literal artifact name "create_artifact".
///
/// If outer `name` (a String) equals `expectedToolName` AND `arguments`
/// (if present) is a dict, return the inner dict. Extra outer keys are
/// tolerated — the outer envelope is malformed anyway.
///
/// Otherwise return `args` unchanged. Applied once per call at the
/// ToolRuntime dispatch boundary before the per-handler `handle(...)`.
nonisolated func unwrapReentrantEnvelope(_ args: [String: Any], expectedToolName: String) -> [String: Any] {
    guard let outerName = args["name"] as? String,
          let inner = args["arguments"] as? [String: Any]
    else {
        return args
    }
    // Canonicalize both sides — the outer `name` often mirrors the LLM's
    // raw emission (`functions.create_artifact`, `repo_browser.read_file`),
    // while `expectedToolName` is the dispatched canonical name. A strict
    // `==` would miss the prefixed form and pass the outer envelope through.
    let outerCanonical = ToolRegistry.resolveToolName(outerName)
    let expectedCanonical = ToolRegistry.resolveToolName(expectedToolName)
    guard outerCanonical == expectedCanonical else { return args }
    return inner
}

// MARK: - Argument Extraction Helpers

nonisolated func requiredString(_ args: [String: Any], _ key: String) throws -> String {
    if let value = args[key] as? String { return value }
    // Fallback: LLM passed a plain string instead of a JSON object
    if let raw = args["__raw_input__"] as? String {
        // Try to parse as JSON and extract the requested key
        if let data = raw.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = parsed[key] as? String {
            return value
        }
        return raw
    }
    throw ToolArgumentError.missingRequired(key)
}

/// A required string whose EMPTY value the callee cannot act on.
///
/// `requiredString` answers "was the key present", not "did the model supply a
/// value": `{"question": ""}` returns `""`. That distinction is invisible at the
/// call site and expensive downstream, because the callees that take free text
/// spend an LLM round-trip on it before anyone can notice —
/// `ask_teammate` sends `"<Role> asks: "` to a teammate, `request_changes`
/// convenes a whole voting meeting over `"Changes requested: \nReasoning: "`,
/// and `ask_supervisor`'s empty question is DROPPED by the dispatcher
/// (`+ToolResultDispatching`'s `!trimmed.isEmpty` guard) after the handler has
/// already reported `ok: true` — the model believes it parked for an answer that
/// will never arrive.
///
/// The ARRAY half of this same class was closed the other way round, and the
/// asymmetry is deliberate rather than accidental: `coerceStringArray` keeps an
/// explicitly empty `[String]` (its own comment says so), and the two
/// `requiredStringArray` call sites each guard emptiness themselves — `git_add`
/// with a comment naming this exact success-envelope-for-a-no-op shape,
/// `request_team_meeting` beside its participants list. Two sites is
/// cheap to do per-site; ten is not, and unlike a path list an empty free-text
/// argument has no site-specific meaning to preserve. Hence a helper here and
/// call-site guards there.
///
/// Deliberately NOT applied to every `requiredString`. Three exclusions, and the
/// second and third were both learned by getting them wrong first:
///
/// 1. **Empty is a real value.** `write_file`'s `content` and `edit_file`'s
///    `new_text` create an empty file and delete a span. `analyze_image`'s
///    `prompt` belongs here too — `VisionAnalysisService.systemPrompt` says
///    verbatim "If no question is given, describe the image concisely", so a
///    guard would make a shipped branch dead code.
/// 2. **An IDENTIFIER whose downstream failure ENUMERATES the legal values.**
///    `ask_teammate`'s `teammate` gets "Unknown teammate role: . Available
///    teammates: …"; `request_changes`'s `target_role` gets "Target role '' not
///    found in the team. Available roles: …". Replacing either with "must not be
///    empty" is strictly worse: it fixes a diagnosis that was already right and
///    deletes the only actionable half. The test for this exclusion is not "does
///    it fail" but "does the failure say what to send instead".
/// 3. **Nothing reads it.** `conclude_meeting`'s `decision` is echoed back in a
///    success envelope with no `ToolSignal` and no dispatcher arm; an empty one
///    buys neither a state change nor a round-trip, so rejecting it only spends a
///    correction turn.
///
/// What is left — and what this helper is for — are arguments whose empty value
/// produces a SUCCESS envelope or an expensive no-op AND whose rejection message
/// has nothing better to say.
///
/// Known and accepted gap: the schemas still advertise only `required`, which in
/// JSON Schema means the KEY must be present. `JSONSchema` has no `minLength`, so
/// the runtime is deliberately stricter than the advertisement rather than paying
/// schema tokens on every request to say so.
///
/// Validated on the trimmed value, returned VERBATIM — the same rule
/// `set_work_folder_context` states: leading and trailing structure of prose is
/// the author's, and trimming it here would silently reformat what the callee
/// records.
nonisolated func requiredNonEmptyString(_ args: [String: Any], _ key: String) throws -> String {
    let value = try requiredString(args, key)
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ToolArgumentError.invalidValue(key: key, detail: "must not be empty.")
    }
    return value
}

nonisolated func optionalString(_ args: [String: Any], _ key: String) -> String? {
    args[key] as? String
}

/// Best-effort string extraction with model-friendly recovery paths.
///
/// Tries `args[key]`, then the same key inside a stringified-JSON
/// `__raw_input__` blob. Non-String values are coerced via `String(describing:)` —
/// strict type-rejection is a contract small models can't reliably honor, so
/// coercion lets downstream validators (whitelists, ID matchers) produce the
/// actionable error. Trims whitespace; returns nil for absent / empty results.
nonisolated func extractString(_ args: [String: Any], _ key: String) -> String? {
    func nonEmpty(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    func lookup(in dict: [String: Any]) -> String? {
        if let s = dict[key] as? String { return nonEmpty(s) }
        if let v = dict[key] { return nonEmpty(String(describing: v)) }
        return nil
    }

    if let result = lookup(in: args) { return result }

    guard let raw = args["__raw_input__"] as? String,
          let data = raw.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return lookup(in: parsed)
}

/// Best-effort Int extraction, tolerant of the shapes small models actually emit.
///
/// Accepts a JSON number, a fractional number (truncated toward zero, matching
/// the historical `Int(Double)` behavior), or the number as a *string*
/// (`"501"`, `" 501 "`, `"501.0"`) — models routinely quote numerics, and
/// strict type-rejection is a contract they can't reliably honor (same
/// reasoning as `extractString` above).
///
/// Out-of-range and non-finite doubles resolve to `nil` rather than trapping:
/// `Int(1e300)` is a runtime crash, and that literal can arrive straight from
/// a model's JSON.
nonisolated private func coerceInt(_ value: Any?) -> Int? {
    if let intVal = value as? Int {
        return intVal
    }
    if let doubleVal = value as? Double {
        return Int(exactly: doubleVal.rounded(.towardZero))
    }
    if let stringVal = value as? String {
        let trimmed = stringVal.trimmingCharacters(in: .whitespacesAndNewlines)
        if let intVal = Int(trimmed) {
            return intVal
        }
        if let doubleVal = Double(trimmed) {
            return Int(exactly: doubleVal.rounded(.towardZero))
        }
    }
    return nil
}

nonisolated func optionalInt(_ args: [String: Any], _ key: String) -> Int? {
    coerceInt(args[key])
}

nonisolated func requiredInt(_ args: [String: Any], _ key: String) throws -> Int {
    if let intVal = coerceInt(args[key]) {
        return intVal
    }
    // Present but uncoercible is a different failure than absent — say so.
    // JSON `null` counts as absent: the model omitted a value, it didn't
    // supply a malformed one.
    if let value = args[key], !(value is NSNull) {
        throw ToolArgumentError.invalidValue(key: key, detail: "must be an integer")
    }
    throw ToolArgumentError.missingRequired(key)
}

/// Best-effort Bool extraction, tolerant of the same quoting habit `coerceInt`
/// absorbs — a model that quotes its integers quotes its booleans too.
///
/// This one matters more than the int case: a rejected bool leaves no `nil` for
/// the caller to notice, it silently becomes the handler's default, so the wrong
/// branch runs under a success envelope (`replace_all` rewriting one occurrence
/// instead of all, `include_line_numbers` re-adding a gutter the model asked to
/// drop). Only unambiguous spellings are honored; anything else keeps the
/// caller's default rather than inventing truthiness for a destructive flag.
nonisolated private func coerceBool(_ value: Any?) -> Bool? {
    if let boolVal = value as? Bool {
        return boolVal
    }
    if let intVal = value as? Int {
        // Exactly 0/1 — an out-of-range int is ambiguous garbage, not a boolean.
        // (JSON 0/1 already bridges through `as? Bool`; this covers the rest.)
        return intVal == 1 ? true : (intVal == 0 ? false : nil)
    }
    if let stringVal = value as? String {
        switch stringVal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }
    return nil
}

nonisolated func optionalBool(_ args: [String: Any], _ key: String, default defaultValue: Bool = false) -> Bool
{
    coerceBool(args[key]) ?? defaultValue
}

/// Best-effort `[String]` extraction. A one-element list emitted as a bare
/// string is the same emission quirk; so is a list of numbers, which does not
/// bridge to `[String]`. Rejecting either reads as "argument absent", which for
/// `search paths` silently drops the narrowing constraint and runs the search
/// over the whole tree while still reporting success.
nonisolated private func coerceStringArray(_ value: Any?) -> [String]? {
    // Exact match first, so an explicitly empty list stays empty rather than
    // collapsing to nil.
    if let arrayVal = value as? [String] {
        return arrayVal
    }
    if let stringVal = value as? String {
        let trimmed = stringVal.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : [trimmed]
    }
    if let anyArray = value as? [Any] {
        let strings = anyArray.compactMap { element -> String? in
            if element is NSNull { return nil }
            let text = (element as? String) ?? String(describing: element)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return strings.isEmpty ? nil : strings
    }
    return nil
}

nonisolated func optionalStringArray(_ args: [String: Any], _ key: String) -> [String]? {
    coerceStringArray(args[key])
}

nonisolated func requiredStringArray(_ args: [String: Any], _ key: String) throws -> [String] {
    try requiredStringArray(args, aliases: [key])
}

/// Resolves a string list from the first usable alias, for tools that accept
/// several spellings of the same argument (`paths`/`files`/`path`,
/// `participants`/`members`).
///
/// Chaining `try? requiredStringArray(a)` then `try? requiredStringArray(b)`
/// cannot tell "this key is absent, try the next alias" from "this key is
/// present but malformed", so a malformed first alias fell through the chain and
/// the model was told about a key it never sent — `git_add {"paths": 5}` reported
/// the whole alias list as missing, and `request_team_meeting {"participants": 5}`
/// reported `members`, which is not even in that tool's schema.
///
/// A usable value anywhere in the chain still wins: the model gave us something
/// we can act on. Only when nothing is usable does a malformed key get named, in
/// preference to reporting an omission that did not happen.
///
/// - Parameter display: what to name when every alias is absent. Defaults to the
///   alias list, so the model sees every spelling the tool accepts.
nonisolated func requiredStringArray(
    _ args: [String: Any], aliases: [String], display: String? = nil
) throws -> [String] {
    var malformedKey: String?
    for key in aliases {
        if let value = coerceStringArray(args[key]) {
            return value
        }
        if malformedKey == nil, let raw = args[key], !(raw is NSNull) {
            malformedKey = key
        }
    }
    if let malformedKey {
        throw ToolArgumentError.invalidValue(key: malformedKey, detail: "must be a list of strings")
    }
    throw ToolArgumentError.missingRequired(display ?? aliases.joined(separator: " / "))
}

// MARK: - Resilient Content Resolution

/// Known non-content keys that should never be treated as content fallbacks.
nonisolated private let nonContentKeys: Set<String> = [
    "path", "create_dirs", "encoding", "max_lines",
    "must_exist", "mode", "file_glob", "patch",
    "start_line", "end_line", "include_line_numbers",
    "new_text", "anchors", "replace_range", "occurrence",
    "match_strategy", "sort", "depth", "include_files",
    "include_dirs", "paths", "max_results", "context_before",
    "context_after", "max_match_lines", "query"
]

/// Common alternative argument names LLMs use instead of "content".
nonisolated private let contentAlternativeNames: [String] = [
    "text", "body", "file_content", "data", "value",
    "plan", "notes", "output", "message", "code", "source"
]

/// Resolves the "content" argument from a tool's args dictionary,
/// with fallback for common LLM argument naming mistakes.
///
/// Resolution order:
/// 1. `args["content"]` (exact match)
/// 2. Known alternative names: "text", "body", "file_content", etc.
/// 3. If exactly one non-excluded string value remains, use it.
nonisolated func resolveContentString(_ args: [String: Any], excludeKeys: Set<String> = []) -> String? {
    // 1. Exact match
    if let content = args["content"] as? String {
        return content
    }

    // 2. Known alternative names
    for alt in contentAlternativeNames {
        if let content = args[alt] as? String {
            return content
        }
    }

    // 3. Single remaining string value fallback
    let allExcluded = nonContentKeys.union(excludeKeys)
    let candidateEntries = args.filter { key, value in
        !allExcluded.contains(key) && value is String
    }
    if candidateEntries.count == 1, let content = candidateEntries.first?.value as? String {
        return content
    }

    return nil
}
