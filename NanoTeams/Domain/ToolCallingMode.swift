import Foundation

// MARK: - ToolCallingMode

/// How a request advertises tools and how the reply names the calls it makes.
///
/// `.native` hands the provider the tool schemas on its own `tools` field and reads the
/// calls back from its structured `tool_calls` — the provider renders the model's chat
/// template and parses the model's own call syntax, whatever family that is. `.promptTaught`
/// is the house protocol: the catalog is prose inside the system prompt and the model is
/// taught to answer `<|call|>{…}<|end|>`, parsed by `HarmonyToolCallParser`.
///
/// Two modes and no third: a value per model family would be the hardcode this type exists
/// to avoid (task 90, 2026-09-13 — the taught sentinel is multi-token for every model it
/// was measured on, and each family already has a native syntax the provider knows).
///
/// Persisted on the step (`StepExecution.toolCallingMode`) because a transcript written
/// under one mode cannot be replayed under the other: a Harmony wire re-sent as native
/// `tool_calls` would hand the model calls it never made in that syntax.
nonisolated enum ToolCallingMode: String, Codable, Hashable, Sendable, CaseIterable {
    case native
    case promptTaught
}

// MARK: - ToolCallingPreference

/// What the user asked for in Settings → LLM. `auto` follows the provider's capability
/// report; the two explicit values override it in either direction, for a server whose
/// report is wrong or a model the user wants measured under the other protocol.
nonisolated enum ToolCallingPreference: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case auto
    case native
    case promptTaught

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Auto"
        case .native: "Native"
        case .promptTaught: "Prompt-taught"
        }
    }

    /// One line under the picker saying what the choice does.
    var explanation: String {
        switch self {
        case .auto:
            "Native when the server reports the model was trained for tool use, prompt-taught otherwise."
        case .native:
            "Always send the tool schemas on the provider's own tools field, whatever the server reports."
        case .promptTaught:
            "Always teach the call format in the system prompt and parse the reply as text."
        }
    }
}

// MARK: - ToolCallingModeResolver

/// The one rule that turns a preference and a provider's answer into a mode.
///
/// Fail-closed toward `.promptTaught`: `nil` means the provider could not say (transport
/// failure, a server build with no capability metadata, a model it has not listed), and the
/// protocol this app controls end to end is the one to fall back on — a native request to a
/// model that was never trained for it is a grammar-forced call to a tool it did not choose.
nonisolated enum ToolCallingModeResolver {
    static func resolve(preference: ToolCallingPreference, providerSupport: Bool?) -> ToolCallingMode {
        switch preference {
        case .native: return .native
        case .promptTaught: return .promptTaught
        case .auto: return providerSupport == true ? .native : .promptTaught
        }
    }
}
