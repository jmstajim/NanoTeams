import Foundation

/// Pure recognition of a tool call's *shape* from an already-parsed JSON
/// object. Extracted from `ToolCallParsingHelpers.parseToolCallFromJSON` so the
/// two concerns stop sharing a 120-line method:
///
/// - **Repair / recovery** (sanitize → regex repairs → re-escape, the
///   `maxSalvageDepth` salvage) stays in `ToolCallParsingHelpers`. It owns the
///   model-defect invariants and turns garbled bytes into a `[String: Any]`.
/// - **Shape recognition** (this enum) is the pure map from a clean dict to
///   `(toolName, rawArguments)`, covering the 5+ envelope variants models emit:
///   `{name}`, `{tool_name}`/`{tool}`/`{function_name}`, `{function:{…}}`, the
///   flat `create_artifact` payload, and signature-based inference. No bytes, no
///   repair, no `StepToolCall` — the caller serializes `arguments` and attaches
///   envelope metadata (provider id).
///
/// Mirrors the pure-policy pattern (`MessageKeyPolicy`, `DesignatedCoordinator-
/// Resolver`, `LoopRecoveryPolicy`, `VocabExpansionScorer`): each variant is
/// unit-testable in isolation, without the repair layer in the way.
///
/// The reserved-channel-name guard and the `stringValue` reader are NOT moved —
/// they are shared with the marker-level strategies in `HarmonyToolCallParser`
/// and live in `ToolCallParsingHelpers` (the shared-utilities namespace).
nonisolated enum ToolCallShapeRecognizer {

    /// Resolves a tool call's identity + raw (unserialized) arguments from a
    /// parsed JSON object, or `nil` when no recognizable shape is present.
    ///
    /// `arguments` is `Any?` (dict / array / string / nil) — the caller runs it
    /// through its own normalizer. Returning the raw value (rather than a
    /// serialized string) keeps this enum free of the serialization concern.
    static func resolve(from dict: [String: Any]) -> (name: String, arguments: Any?)? {
        // Reserved-name guard applies to every shape below, not just the
        // bare-identifier path in `CallMarkerStrategy`. Without this,
        // `{"name":"commentary",...}` would reach dispatch as a tool call.
        func acceptingName(_ name: String) -> String? {
            ToolCallParsingHelpers.reservedChannelNames.contains(name.lowercased()) ? nil : name
        }

        // Flat create_artifact emission: `{"content":…,"format":…,"name":"<Artifact>"}`
        // with NO `arguments` wrapper. Here the top-level `name` is the ARTIFACT
        // name (a create_artifact parameter), NOT the tool name — some models
        // collapse the canonical
        // `{"name":"create_artifact","arguments":{"name":"<Artifact>",…}}` into this
        // shape, putting the artifact name on the top-level `name` key. Without this
        // the artifact name mis-binds as the tool name (observed with `gemma-4-e4b`:
        // `<|call|>{…,"name":"Production Readiness"}` resolving to a tool literally
        // named "Production Readiness"). Gated on three conditions so it never
        // over-reaches:
        //   1. no `arguments`/`args`/… wrapper (it's a flat payload);
        //   2. the top-level `name` value is NOT itself a known tool — a legitimate
        //      flat call whose `name` IS a tool that also takes `content`
        //      (e.g. `update_scratchpad`) must stay that tool, not become
        //      create_artifact;
        //   3. the payload matches create_artifact's exact signature
        //      (`recognizeToolFromArguments`: `name`+`content`, no keys exclusive to
        //      other tools).
        // The whole flat dict becomes the args so the artifact `name`/`content`/
        // `format` survive. Checked BEFORE the generic top-level-`name` path so the
        // artifact name doesn't win as the tool name.
        let hasArgsWrapper = dict["arguments"] != nil || dict["args"] != nil
            || dict["parameters"] != nil || dict["params"] != nil
        if !hasArgsWrapper,
           let topLevelName = ToolCallParsingHelpers.stringValue(dict["name"]),
           !ToolNames.allNames.contains(topLevelName),
           recognizeToolFromArguments(dict) == ToolNames.createArtifact {
            return (name: ToolNames.createArtifact, arguments: dict)
        }

        if let name = ToolCallParsingHelpers.stringValue(dict["name"]).flatMap(acceptingName) {
            let args = dict["arguments"] ?? dict["args"] ?? dict["parameters"] ?? dict["params"]
                ?? synthesizeArgumentsFromTopLevel(dict)
            return (name: name, arguments: args)
        }

        if let toolName = (ToolCallParsingHelpers.stringValue(dict["tool_name"])
            ?? ToolCallParsingHelpers.stringValue(dict["tool"])
            ?? ToolCallParsingHelpers.stringValue(dict["function_name"])).flatMap(acceptingName) {
            let args = dict["arguments"] ?? dict["args"] ?? dict["parameters"] ?? dict["params"]
                ?? synthesizeArgumentsFromTopLevel(dict)
            return (name: toolName, arguments: args)
        }

        if let fnDictAny = dict["function"] as? [String: Any],
           let fnName = ToolCallParsingHelpers.stringValue(fnDictAny["name"]).flatMap(acceptingName) {
            let argsAny = fnDictAny["arguments"] ?? fnDictAny["args"]
            return (name: fnName, arguments: argsAny)
        }

        // Shape-based fallback: some models emit `{"arguments":{…}}` without a
        // top-level tool name — the `name` field lives inside `arguments` as a
        // tool parameter (e.g. artifact name for create_artifact). Infer the
        // tool from the argument signature when it's unambiguous.
        if let inferred = inferToolNameFromShape(dict) {
            return (name: inferred.name, arguments: inferred.arguments)
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
    /// in `resolve`. Mixing `Any?` with `[String:Any]?` in a `??` chain causes Swift
    /// to wrap the dict-optional as `Any.some(Optional<…>.none)`, which then bypasses
    /// the normalizer's nil-guard and falls through to `String(describing:)` — producing
    /// the literal string `"nil"` as `argumentsJSON`. Keeping the return `Any?` avoids
    /// that subtle double-wrap.
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
        return ToolNames.createArtifact
    }
}
