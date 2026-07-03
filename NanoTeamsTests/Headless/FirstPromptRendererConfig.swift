import Foundation
@testable import NanoTeams

/// Configuration for the first-prompt renderer. Loaded from JSON.
///
/// The renderer takes a (team, role, supervisor-task brief) tuple and emits the
/// exact wire payload that `LLMExecutionService` would send on the first
/// `/api/v1/chat` request for that role's step execution — without LM Studio,
/// without running anything, without producing any `network_log.json`.
///
/// Output is a `{wire, render_meta}` envelope; the `wire` half is byte-comparable
/// to a real `network_log.json` record's `.body`. The `--from-logs` mode of the
/// driver script (`train_first_prompt.sh`) emits the same envelope shape, so
/// both surfaces are diff-friendly.
struct FirstPromptRendererConfig: Codable {
    // MARK: - Workfolder

    /// Absolute path to the workfolder root. Must contain `.nanoteams/internal/`
    /// with a valid `teams.json` — same shape `NTMSRepository.openOrCreateWorkFolder`
    /// reads at app launch.
    let projectPath: String

    // MARK: - Target

    /// (team, role) tuple. Exactly one of `id` or `name` must be set per side —
    /// the type makes illegal combinations unrepresentable.
    let target: ResolutionTarget

    // MARK: - Synthetic task input

    /// The body of the synthetic `## Supervisor Task` section that becomes
    /// the first `user` turn. Required because the first prompt's `input`
    /// directly depends on it.
    let supervisorTaskBrief: String

    // MARK: - Output

    /// Absolute path where the renderer writes the envelope JSON.
    let outputPath: String

    // MARK: - LLM-config knobs that affect wire payload

    /// Model name written to the wire payload's `.model` field. Default
    /// `"render-only"` makes it visually obvious in audits that the payload
    /// came from the renderer, not from a real LM Studio call.
    let modelName: String?

    /// Optional temperature (mirrors `LLMConfig.temperature`).
    let temperature: Double?

    /// Optional max tokens (mirrors `LLMConfig.maxTokens`). Default 4096 —
    /// matches `LLMProvider.lmStudio.defaultMaxTokens`.
    let maxTokens: Int?

    // MARK: - State-derived inputs the renderer can't infer

    /// App-wide instruction appended to the system prompt (mirrors
    /// `StoreConfiguration.globalContext`). Default `""`.
    let globalContext: String?

    /// `WorkFolderProjection.settings.selectedScheme` — when present, xcode
    /// tools (`run_xcodebuild`, `run_xcodetests`) survive `resolveToolSchemas`'s
    /// step 3.1 filter. When `nil`, they're stripped (same as runtime).
    let selectedScheme: String?

    /// Mirrors `LLMExecutionDelegate.visionLLMConfig != nil` — when `true`,
    /// `analyze_image` survives the step 3.2 filter. Default `false`.
    let visionConfigured: Bool?

    /// Mirrors `ComputerUsePolicy.isEnabled` (same threading as `visionConfigured`).
    /// Default `false` — the safe orchestrator-free default.
    let computerUseEnabled: Bool?

    // MARK: - Resolved helpers

    var resolvedModelName: String { modelName ?? "render-only" }
    var resolvedMaxTokens: Int { maxTokens ?? LLMProvider.lmStudio.defaultMaxTokens }
    var resolvedGlobalContext: String { globalContext ?? "" }
    var resolvedVisionConfigured: Bool { visionConfigured ?? false }
    var resolvedComputerUseEnabled: Bool { computerUseEnabled ?? false }
}

// MARK: - Targets

/// Wraps a (team, role) pair so callers can't construct half-specified configs.
struct ResolutionTarget: Codable {
    let team: TeamTarget
    let role: RoleTarget
}

/// Tagged target for a team. JSON form: `{"id": "..."}` or `{"name": "..."}`.
/// Decoder fails loudly on empty or both-set objects — illegal states never
/// reach `FirstPromptRenderer.resolveTeam`.
enum TeamTarget: Codable, Equatable {
    case id(String)
    case name(String)

    var displayHint: String {
        switch self {
        case .id(let v): return "id=\(v)"
        case .name(let v): return "name=\(v)"
        }
    }

    private enum CodingKeys: String, CodingKey { case id, name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decodeIfPresent(String.self, forKey: .id)
        let name = try c.decodeIfPresent(String.self, forKey: .name)
        switch (id, name) {
        case (let .some(value), nil) where !value.isEmpty:
            self = .id(value)
        case (nil, let .some(value)) where !value.isEmpty:
            self = .name(value)
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "team must specify exactly one of {\"id\": ...} or {\"name\": ...}"
            ))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .id(let v): try c.encode(v, forKey: .id)
        case .name(let v): try c.encode(v, forKey: .name)
        }
    }
}

/// Tagged target for a role within a team. Same constraints as `TeamTarget`.
enum RoleTarget: Codable, Equatable {
    case id(String)
    case name(String)

    var displayHint: String {
        switch self {
        case .id(let v): return "id=\(v)"
        case .name(let v): return "name=\(v)"
        }
    }

    private enum CodingKeys: String, CodingKey { case id, name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decodeIfPresent(String.self, forKey: .id)
        let name = try c.decodeIfPresent(String.self, forKey: .name)
        switch (id, name) {
        case (let .some(value), nil) where !value.isEmpty:
            self = .id(value)
        case (nil, let .some(value)) where !value.isEmpty:
            self = .name(value)
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "role must specify exactly one of {\"id\": ...} or {\"name\": ...}"
            ))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .id(let v): try c.encode(v, forKey: .id)
        case .name(let v): try c.encode(v, forKey: .name)
        }
    }
}
