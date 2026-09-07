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

    /// Mirrors `StoreConfiguration.computerUseMode` — the MODE, not a switch, because the
    /// resolver reads the mode against whether a human is there to approve
    /// (`ApprovalGatedAvailability.forComputerUse`): Manual with no human withholds all five
    /// tools, Semi-automatic with no human the mutating trio. Raw values `off` /
    /// `manual` / `semiAutomatic` / `auto`; a typo fails the load, not the render. Default
    /// `.manual` — the fresh-install value `StoreConfiguration` applies — so a render is
    /// what the first request of a fresh install would carry. Until 2026-09-07 this was a
    /// Bool defaulting to `false` (= Off), which is NOT what a fresh install ships: every
    /// render of a role holding computer-use tools (Assistant, Coding Assistant, the
    /// Autovisor manager) lacked their five schemas and nothing said so.
    let computerUseMode: ComputerUseMode?

    /// Mirrors `StoreConfiguration.bashMode` (raw values `off` / `alwaysConfirm` / `manual`
    /// / `auto` — `manual` is Semi-automatic, the legacy spelling). Read against the same
    /// presence answer: Off or Manual with no human withholds `bash` + `bash_output`.
    /// Default `BashConstants.defaultMode` (Manual), the fresh-install value.
    let bashMode: BashExecutionMode?

    /// Which call site's first prompt to render. `step` (default) is the step run loop's
    /// first request — `buildChatMessages` plus the real `buildRequest`. `consultation` and
    /// `meeting` render the system prompt and toolset of those side calls through
    /// `PromptBuilder.buildWirePromptPreview`, the same seam the Settings preview uses
    /// (byte-parity with the runtime pinned by `PromptBuilderWirePreviewTests`); their user
    /// turns are runtime-dynamic (the question, the transcript) and are not rendered. Until
    /// 2026-09-07 the renderer knew one kind, so the observer of a Discussion Club meeting —
    /// the surface that carried both "Call one tool per response." and "None available" —
    /// could not be audited offline (playbook REC.10 / KF4).
    let kind: RenderKind?

    // MARK: - Resolved helpers

    var resolvedKind: RenderKind { kind ?? .step }

    var resolvedModelName: String { modelName ?? "render-only" }
    /// The production default when the config carries no `globalContext` — the same
    /// fallback `StoreConfiguration` applies — so a render is byte-identical to the first
    /// request a fresh install sends. Until 2026-09-06 the default here was the EMPTY string:
    /// every render (and every audit numbered from one) lacked the `## Global guidance`
    /// section, three playbook Checks could not be executed on a render, and nothing said so.
    /// An explicit `""` still renders without the section (the user cleared the setting).
    var resolvedGlobalContext: String { globalContext ?? AppDefaults.globalContext }
    var resolvedVisionConfigured: Bool { visionConfigured ?? false }
    var resolvedComputerUseMode: ComputerUseMode { computerUseMode ?? .manual }
    var resolvedBashMode: BashExecutionMode { bashMode ?? BashConstants.defaultMode }
}

// MARK: - Render kind

/// Raw values are what `--kind` passes; a typo fails the load, not the render.
enum RenderKind: String, Codable {
    case step
    case consultation
    case meeting

    var wireKind: WirePromptKind {
        switch self {
        case .step: return .stepExecution
        case .consultation: return .consultation
        case .meeting: return .meeting
        }
    }
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
