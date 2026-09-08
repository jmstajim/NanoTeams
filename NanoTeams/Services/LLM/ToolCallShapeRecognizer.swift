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

        if let explicit = resolveExplicitName(in: dict) {
            return explicit
        }

        // Shape-based fallback: some models emit `{"arguments":{…}}` without a
        // top-level tool name — the `name` field lives inside `arguments` as a
        // tool parameter (e.g. artifact name for create_artifact). Infer the
        // tool from the argument signature when it's unambiguous.
        if let inferred = inferToolNameFromShape(dict) {
            return (name: inferred.name, arguments: inferred.arguments)
        }

        // The tool id written INSIDE the model's own `arguments` wrapper. Last, so every
        // shape that resolved before this branch existed resolves to the same bytes — only
        // payloads that used to return nil can reach here.
        if let nested = toolNameInsideArgumentsWrapper(dict) {
            return nested
        }

        return nil
    }

    /// A whole call envelope written one level too deep — the tool id sits inside
    /// `arguments`, where it reads as a parameter.
    ///
    /// Three shapes from one `ornith-1.0-35b` step (CastleSurvivors, 2026-09-08), all
    /// dropped, all costing a round trip:
    ///
    ///     {"arguments":{"path":"…","name":"read_file"},"type":"tool_call"}
    ///     {"arguments":{"name":"git_show","path":"…","rev":"dbce2bb"},"type":"tool_call"}
    ///     {"arguments":{"name":"read_lines","arguments":{"path":"…","start_line":1}}}
    ///
    /// R4.4.2 classifies that as S2 format mixing ("a whole envelope inside `arguments`"),
    /// and R4.3.4 sends a rule broken on 2+ turns of one step to a runtime check rather
    /// than to the prompt. R3.8.7 says which check: make the parser accept the form the
    /// model emits.
    ///
    /// **One unwrap, no recursion.** The inner dict is handed to `resolveExplicitName`, so
    /// the rules one level down are the identical ones — including the `function` branch,
    /// which a `resolve`-recursion would have mishandled (`function` is a reserved envelope
    /// key, so `synthesizeArgumentsFromTopLevel` would have stripped the arguments). Depth
    /// is structurally 1: no parameter to thread, no cap to tune.
    ///
    /// **Gated on the CANONICAL name — no alias resolution, deliberately.**
    /// `ToolRegistry.defaultAliases` maps `test` → `run_xcodetests`, `build` →
    /// `run_xcodebuild`, `exec` → `bash`, so `{"arguments":{"name":"test","path":"scripts/"}}`
    /// would launch a test run. The alias map is legitimate where intent is established;
    /// here the payload's own structure is evidence the model was confused about the
    /// protocol, and guessing an id on top of a provably wrong id POSITION is two guesses
    /// deep (the same reasoning `BareToolCallSalvage` records for bare words).
    ///
    /// The gate is also what keeps a legitimate `create_artifact` — whose `arguments.name`
    /// is an ARTIFACT title — from dispatching a tool that does not exist, and what makes
    /// the two-fault nudge for the residual case reachable: `tool_not_found` would name the
    /// id and stay silent about the position, so the model would fix the id and keep
    /// misplacing it.
    private static func toolNameInsideArgumentsWrapper(
        _ dict: [String: Any]
    ) -> (name: String, arguments: Any?)? {
        guard let wrapper = dict["arguments"] ?? dict["args"] ?? dict["parameters"]
            ?? dict["params"],
            let inner = wrapper as? [String: Any],
            let resolved = resolveExplicitName(in: inner),
            ToolNames.allNames.contains(resolved.name)
        else { return nil }
        return resolved
    }

    /// The keys that may carry the tool id. Single source for `resolveExplicitName` and
    /// `explicitToolName`; the classifier used to restate this list by hand, in
    /// `classifyHarmonyCallIssue`'s `hasTopLevelName`.
    static let toolNameKeys: [String] = ["name", "tool_name", "tool", "function_name"]

    /// The three EXPLICIT-name shapes with their arguments — extracted verbatim from
    /// `resolve` so the nested-envelope unwrap can run the identical rules one level down.
    ///
    /// The grouping is load-bearing and deliberately not flattened into one loop over
    /// `toolNameKeys`. `name` is tested alone; the remaining three are a `??` chain, so the
    /// FIRST PRESENT one wins and a reserved value there refuses the whole shape rather
    /// than falling through to its neighbour. Flattening would quietly change
    /// `{"tool_name":"commentary","tool":"read_file"}` from "refused" to "read_file".
    static func resolveExplicitName(
        in dict: [String: Any]
    ) -> (name: String, arguments: Any?)? {
        func acceptingName(_ name: String) -> String? {
            ToolCallParsingHelpers.reservedChannelNames.contains(name.lowercased()) ? nil : name
        }

        if let name = ToolCallParsingHelpers.stringValue(dict["name"]).flatMap(acceptingName) {
            let args = mergingSpilledSiblings(dict) ?? synthesizeArgumentsFromTopLevel(dict)
            return (name: name, arguments: args)
        }

        if let toolName = (ToolCallParsingHelpers.stringValue(dict["tool_name"])
            ?? ToolCallParsingHelpers.stringValue(dict["tool"])
            ?? ToolCallParsingHelpers.stringValue(dict["function_name"])).flatMap(acceptingName) {
            let args = mergingSpilledSiblings(dict) ?? synthesizeArgumentsFromTopLevel(dict)
            return (name: toolName, arguments: args)
        }

        if let fnDictAny = dict["function"] as? [String: Any],
           let fnName = ToolCallParsingHelpers.stringValue(fnDictAny["name"]).flatMap(acceptingName) {
            // All four wrapper keys, like every other branch. Reading only
            // `arguments`/`args` here was an asymmetry, not a rule: a model that nests its
            // call under `function` and names the wrapper `parameters` lost every argument.
            let argsAny = fnDictAny["arguments"] ?? fnDictAny["args"]
                ?? fnDictAny["parameters"] ?? fnDictAny["params"]
            return (name: fnName, arguments: argsAny)
        }

        return nil
    }

    /// The tool id read from an EXPLICIT key only, for callers that need to know whether the
    /// payload NAMES anything — the classifier, which must still see `{"name":"commentary"}`
    /// as name-bearing so it reports a parse failure rather than a missing name.
    ///
    /// Deliberately different from `resolveExplicitName` in two ways, because it answers a
    /// different question: no reserved-channel guard, and no grouping — any recognised key
    /// counts, which mirrors the OR that `hasTopLevelName` performed before this existed.
    static func explicitToolName(in dict: [String: Any]) -> String? {
        for key in toolNameKeys {
            if let value = ToolCallParsingHelpers.stringValue(dict[key]) { return value }
        }
        if let function = dict["function"] as? [String: Any] {
            return ToolCallParsingHelpers.stringValue(function["name"])
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
        let promoted = dict.filter { !reservedEnvelopeKeys.contains($0.key) }
        return promoted.isEmpty ? nil : promoted
    }

    /// Keys that identify or wrap the call envelope itself — never promote them into a
    /// tool's arguments. The four args-keys (`arguments`/`args`/`parameters`/`params`)
    /// are listed for completeness even though top-level synthesis only fires when
    /// they're absent. Harmony framing fields (`type`/`channel`/`recipient`/`constrain`)
    /// and OpenAI tool-call envelope fields (`type:"function"`) are also reserved —
    /// promoting them would inject `{"type":"function", …}` into a tool's args dict and
    /// cause `INVALID_ARGS` rejections or, worse, silent acceptance of garbage.
    static let reservedEnvelopeKeys: Set<String> = [
        "name", "tool_name", "tool", "function_name",
        "id", "call_id", "function",
        "arguments", "args", "parameters", "params",
        "type", "channel", "recipient", "constrain",
    ]

    /// Tool parameters the model wrote as SIBLINGS of `arguments` rather than inside it,
    /// in declaration-stable order.
    ///
    /// The shape comes from a model closing its `arguments` object one brace early —
    /// `{"name":"edit_file","arguments":{"new_text":…},"old_text":…,"path":…}` — which is
    /// perfectly valid JSON, so nothing upstream flags it, and the `??` chain in
    /// `resolve` used to short-circuit on the non-empty wrapper and drop the rest. That
    /// cost `gemma-4-26b-a4b-qat` two identical `INVALID_ARGS` round-trips in one step
    /// while it was sending every argument the tool required
    /// (`network_log.json`, 2026-08-13).
    ///
    /// A key already present INSIDE the wrapper is not reported and not merged: the
    /// model put a value where values belong, and a stray outer copy must not overwrite
    /// it. Callers use the returned list to tell the model what it mis-emitted; an empty
    /// list means nothing was recovered, so nothing is said.
    static func spilledSiblingKeys(from dict: [String: Any]) -> [String] {
        guard let wrapper = dict["arguments"] ?? dict["args"] ?? dict["parameters"]
            ?? dict["params"],
            let inner = wrapper as? [String: Any]
        else { return [] }
        return dict.keys
            .filter { !reservedEnvelopeKeys.contains($0) && inner[$0] == nil }
            .sorted()
    }

    /// The `arguments` wrapper with any spilled siblings folded in, or nil when the dict
    /// carries no wrapper at all (so `resolve` falls through to top-level synthesis).
    /// A non-dictionary wrapper — a model that serialised its arguments as a string — is
    /// returned untouched, because there is nothing to fold into.
    private static func mergingSpilledSiblings(_ dict: [String: Any]) -> Any? {
        guard let wrapper = dict["arguments"] ?? dict["args"] ?? dict["parameters"]
            ?? dict["params"]
        else { return nil }
        guard var inner = wrapper as? [String: Any] else { return wrapper }
        for key in spilledSiblingKeys(from: dict) { inner[key] = dict[key] }
        return inner
    }

    /// Where the payload put the tool id — a positive fact about its SHAPE, so it is
    /// `Equatable` and testable without first driving `resolve` to failure.
    ///
    /// Exists so `classifyHarmonyCallIssue` stops restating `resolve`'s key precedence by
    /// hand: the two lists had no shared constant and no test asserting they agreed, which
    /// is one edit away from a classifier that reports a missing name for a payload the
    /// parser dispatched.
    enum ToolNamePosition: Equatable {
        /// A recognised name key at the top level — including a reserved channel name, which
        /// is name-BEARING even though it never dispatches.
        case topLevel(String)
        /// The id was written inside the `arguments` wrapper, where it reads as a parameter.
        /// `isRegisteredTool` is what separates "the parser recovered this" from "two faults
        /// at once: wrong position AND an id that names nothing".
        case insideArguments(name: String, isRegisteredTool: Bool)
        /// No id anywhere. `inferredToolName` is the shape guess, when there is one.
        case absent(inferredToolName: String?)
    }

    /// Mirrors `resolve`'s precedence exactly — explicit keys, then shape inference, then
    /// the nested unwrap — so a payload that DISPATCHES can never be described here as one
    /// that failed to name a tool.
    static func toolNamePosition(in dict: [String: Any]) -> ToolNamePosition {
        if let explicit = explicitToolName(in: dict) {
            return .topLevel(explicit)
        }
        if let inferred = inferToolNameFromShape(dict)?.name {
            return .absent(inferredToolName: inferred)
        }
        if let nested = nestedExplicitToolName(in: dict) {
            return .insideArguments(
                name: nested, isRegisteredTool: ToolNames.allNames.contains(nested))
        }
        return .absent(inferredToolName: nil)
    }

    /// The explicit id inside the `arguments` wrapper, whatever the model called that
    /// wrapper. No registry gate — the caller decides what an unregistered id means.
    private static func nestedExplicitToolName(in dict: [String: Any]) -> String? {
        guard let wrapper = dict["arguments"] ?? dict["args"] ?? dict["parameters"]
            ?? dict["params"],
            let inner = wrapper as? [String: Any]
        else { return nil }
        return explicitToolName(in: inner)
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
