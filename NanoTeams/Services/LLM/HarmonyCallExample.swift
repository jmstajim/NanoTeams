import Foundation

/// The one owner of "what a tool call looks like" — the worked example the system prompt
/// ships and the illustration a retry nudge attaches.
///
/// Both surfaces used to build their own. The system prompt's version derives every value
/// from the tool's own schema, honouring `enumValues` so a verbatim copy cannot violate a
/// constraint; the nudges shipped the literal `{"param":"value"}`. A model copied that
/// placeholder verbatim — `read_file {"param":"value"}` → `INVALID_ARGS: Missing required
/// argument: path`, about a key that exists in no schema (`ornith-1.0-35b`, CastleSurvivors
/// 2026-09-08 07:30:07). Two independently drifting answers to one question is CLAUDE.md
/// #51; this type is the merge, and the prompt-side bytes are unchanged by it.
///
/// `nonisolated` because the app target defaults types to `@MainActor`; pure value-in /
/// value-out (house pattern: `ContextBudgetPolicy`, `HarmonyToolCallEnvelope`).
nonisolated enum HarmonyCallExample {

    /// Tools whose example body is safe to copy verbatim, in preference order.
    ///
    /// Read-only first, deliberately: a model that copies the illustration instead of
    /// adapting it should land on a call that observes the work folder, never one that
    /// writes a file or submits a junk artifact. `create_artifact` is last for that reason
    /// even though it is the system prompt's preferred example — there the example is the
    /// only one the model gets and the artifact name comes from the role's own enum, while
    /// here it is a correction the model is already failing to follow.
    static let preferredExampleTools: [String] = [
        ToolNames.readFile, ToolNames.listFiles, ToolNames.search,
        ToolNames.askSupervisor, ToolNames.updateScratchpad, ToolNames.waitForEvents,
        ToolNames.writeFile, ToolNames.createArtifact,
    ]

    /// A complete `<|call|>…<|end|>` envelope for a tool the role actually holds, or nil
    /// when it holds none of the candidates — in which case the caller must DROP the
    /// illustration rather than fall back to a placeholder id. `TOOL_NAME` is itself
    /// copyable, and a model that copies it earns a `tool_not_found`.
    static func envelope(preferring allowedToolNames: Set<String>) -> String? {
        guard let pick = toolAndArguments(preferring: allowedToolNames) else { return nil }
        return "<|call|>{\"name\":\"\(pick.name)\",\"arguments\":\(pick.argumentsJSON)}<|end|>"
    }

    /// The same pick, unassembled, for the one nudge that also illustrates the
    /// `<|channel|>…to=NAME<|message|>{…}` form.
    static func toolAndArguments(
        preferring allowedToolNames: Set<String>
    ) -> (name: String, argumentsJSON: String)? {
        guard let name = preferredExampleTools.first(where: allowedToolNames.contains),
              let schema = ToolHandlerRegistry.schema(named: name)
        else { return nil }
        return (name: name, argumentsJSON: argumentsJSON(for: schema.parameters))
    }

    /// Synthesize a `{key:placeholder,...}` JSON body for the schema's required
    /// parameters (sorted), or the first 2 properties (sorted) when no params
    /// are required. Placeholders respect each property's `enumValues` (so the
    /// example never violates an enum constraint) and `array.items.type` (so an
    /// array example shows a representative element).
    static func argumentsJSON(for schema: JSONSchema) -> String {
        let properties = schema.properties ?? [:]
        guard !properties.isEmpty else { return "{}" }
        let required = Set(schema.required ?? [])
        let reqKeys = properties.keys.filter { required.contains($0) }.sorted()
        let keys: [String] = reqKeys.isEmpty
            ? Array(properties.keys.sorted().prefix(2))
            : reqKeys
        let parts: [String] = keys.compactMap { key in
            guard let prop = properties[key] else { return nil }
            return "\"\(key)\":\(placeholder(for: prop))"
        }
        return "{\(parts.joined(separator: ","))}"
    }

    private static func placeholder(for prop: JSONSchemaProperty) -> String {
        // An enum-constrained parameter must use a valid enum value: small
        // models verbatim-copy the example and the runtime would reject an
        // out-of-enum placeholder.
        if let first = prop.enumValues?.first {
            return "\"\(first)\""
        }
        switch prop.type {
        case "integer", "number": return "0"
        case "boolean": return "true"
        case "array":
            if let itemType = prop.items?.type {
                return "[\(scalarPlaceholder(for: itemType))]"
            }
            return "[]"
        case "object": return "{}"
        default: return "\"...\""
        }
    }

    /// Scalar-only placeholder used inside `array.items` rendering — arrays of
    /// objects aren't a real shape in the current tool registry, so the leaf
    /// types are sufficient.
    private static func scalarPlaceholder(for type: String) -> String {
        switch type {
        case "integer", "number": return "0"
        case "boolean": return "true"
        default: return "\"...\""
        }
    }
}
