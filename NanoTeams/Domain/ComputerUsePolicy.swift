import Foundation

// MARK: - Constants

nonisolated enum ComputerUseConstants {
    /// After raising/activating the target app, wait this long before posting the click/type so
    /// window ordering settles — otherwise the event can race ahead of the raise and land on
    /// whatever window was previously frontmost.
    static let activationSettleMilliseconds = 150
}

// MARK: - Execution Mode

/// How the computer-use tools resolve an action that requires review.
nonisolated enum ComputerUseMode: String, Codable, CaseIterable, Hashable, Sendable {
    /// Computer-use is disabled — every action is denied.
    case off
    /// Every click / type / key / scroll pauses for human Allow/Deny. In a no-human
    /// context (autonomous / Autovisor / headless) the action is denied.
    case manual
    /// Actions are resolved by the one-shot LLM judge (`ComputerUseJudgeService`) —
    /// no human in the loop.
    case auto

    private static let metadata: [ComputerUseMode: (displayName: String, description: String)] = [
        .off: ("Off", "Computer Use is disabled. Roles cannot see or control the screen."),
        .manual: ("Manual", "You approve every click, keystroke, and scroll before it happens — with a preview of the target."),
        .auto: ("Auto", "An LLM judge approves or denies each action for you, at the strictness set below."),
    ]

    var displayName: String { Self.metadata[self]?.displayName ?? rawValue }
    var settingDescription: String { Self.metadata[self]?.description ?? "" }
}

/// How strict the Auto judge should be when ruling on a computer-use action.
/// `.off` disables the judge entirely — in Auto mode every action that passes the
/// hard deny rules (self-guard, out-of-bounds, blocklists, app allowlist) runs
/// without review. Scoped to Auto: Manual mode always asks the human, regardless
/// of the stored (hidden) safety level.
nonisolated enum ComputerUseRestrictionLevel: String, Codable, CaseIterable, Hashable, Sendable {
    // Declaration order = `allCases` order = the Settings segmented picker's
    // left-to-right order (loosest first). Raw values persist by string, so
    // reordering is storage-safe.
    case off
    case permissive
    case standard
    case strict

    private static let metadata: [ComputerUseRestrictionLevel: (displayName: String, description: String, guidance: String)] = [
        .off: (
            "Off",
            "No review — every action runs without the judge. Blocked patterns and the app allowlist still apply.",
            // Never reaches the judge (`evaluate` step 8 allows before the gate
            // consults it); non-empty only to satisfy the metadata completeness
            // contract pinned by `testMetadata_nonEmpty`.
            "Approve every action."
        ),
        .permissive: (
            "Permissive",
            "Approves most in-app actions; denies only clearly destructive or dangerous ones.",
            "Approve most in-app actions. Deny only clearly destructive or dangerous ones: irreversible deletion, "
                + "financial transactions, disabling security, or system-wide changes."
        ),
        .standard: (
            "Standard",
            "Approves ordinary app operation; denies destructive, financial, credential, or system-level actions.",
            "Approve ordinary operation of the target app: clicking controls, typing, scrolling, navigating. "
                + "Deny destructive actions (deleting files/data), financial actions (purchases, transfers), "
                + "entering credentials or secrets, changing system settings, or acting outside the target app."
        ),
        .strict: (
            "Strict",
            "Approves only obviously safe clicks and typing inside the target app; denies anything that could delete, send, purchase, or leave the app.",
            "Approve ONLY clearly safe actions inside the intended target app: clicking non-destructive controls, "
                + "typing into ordinary text fields, scrolling. Deny anything that could delete data, send a message, "
                + "make a purchase, change system settings, enter credentials, or interact with an app other than the target."
        ),
    ]

    var displayName: String { Self.metadata[self]?.displayName ?? rawValue }
    var settingDescription: String { Self.metadata[self]?.description ?? "" }
    /// Injected verbatim into the judge system prompt.
    var judgeGuidance: String { Self.metadata[self]?.guidance ?? "" }
}

// MARK: - Action

/// A single computer-use action. Reused as the `ToolSignal.computerUse` payload AND as the
/// unit the permission service classifies. Coordinates are in **image-pixel** space.
nonisolated enum ComputerUseAction: Hashable, Sendable {
    case capture(target: String, windowTitle: String?)
    case click(x: Int, y: Int, button: String, double: Bool, target: String?)
    case typeText(text: String, target: String?)
    case pressKey(keys: String, target: String?)
    case scroll(x: Int, y: Int, dx: Int, dy: Int, target: String?)

    /// The app the action targets, if any. `nil` for a whole-screen capture or an
    /// action with no explicit target (applies to the frontmost app).
    var appTargetSpec: String? {
        switch self {
        case .capture(let target, _):
            let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || t.caseInsensitiveCompare("screen") == .orderedSame
                || t.caseInsensitiveCompare("display") == .orderedSame { return nil }
            return t
        case .click(_, _, _, _, let target), .scroll(_, _, _, _, let target):
            return normalizedTarget(target)
        case .typeText(_, let target), .pressKey(_, let target):
            return normalizedTarget(target)
        }
    }

    private func normalizedTarget(_ target: String?) -> String? {
        guard let t = target?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// Compact one-liner for tight UI (logs / list rows). Type text is truncated for display —
    /// NEVER use this where a security decision is made (judge / approval), because the
    /// truncated value differs from what actually runs. Use `detail` there.
    var summary: String {
        switch self {
        case .typeText(let text, _):
            let shown = text.count > 60 ? String(text.prefix(60)) + "…" : text
            return "Type “\(shown)”"
        default:
            return detail
        }
    }

    /// FULL, untruncated human-readable description of the action. This is the value the judge
    /// and the human approval card must see so the reviewer validates exactly what will run —
    /// there is no divergence between the reviewed text and the typed text.
    var detail: String {
        switch self {
        case .capture(let target, let wt):
            let base = appTargetSpec == nil ? "the whole screen" : target
            return "Screenshot \(base)" + (wt.map { " · “\($0)”" } ?? "")
        case .click(let x, let y, let button, let double, _):
            return "\(double ? "Double " : "")\(button)-click at (\(x), \(y))"
        case .typeText(let text, _):
            return "Type “\(text)”"
        case .pressKey(let keys, _):
            return "Press \(keys)"
        case .scroll(let x, let y, let dx, let dy, _):
            return "Scroll (\(dx), \(dy)) at (\(x), \(y))"
        }
    }
}

// MARK: - Permission Decision

/// Result of evaluating a `ComputerUseAction` against a `ComputerUsePolicy`. `deny > ask > allow`.
nonisolated enum ComputerUsePermissionDecision: Hashable, Sendable {
    case allow
    case deny(reason: String)
    case ask(reason: String)
}

// MARK: - Policy

/// App-level configuration for the computer-use feature. Assembled from `StoreConfiguration`
/// and surfaced to `LLMExecutionService` through `LLMStateDelegate.computerUsePolicy`.
///
/// IMPORTANT: never carries a credential — `Codable`, could be logged. The judge's LM Studio
/// token lives only in the Keychain and is resolved at request time.
nonisolated struct ComputerUsePolicy: Codable, Hashable, Sendable {
    var mode: ComputerUseMode
    var restrictionLevel: ComputerUseRestrictionLevel

    /// Single source of truth for "the feature is on at all" — schema resolution,
    /// runtime classification, and UI all key off this instead of re-spelling
    /// `mode != .off`.
    var isEnabled: Bool { mode != .off }
    /// Bundle ids / app names the tools may target. Empty = any app.
    var targetAppAllowlist: [String]
    /// Regex/substring patterns that force-deny `ui_type` (e.g. secrets). Empty by default.
    var blockedTypingPatterns: [String]
    /// Regex/substring patterns that force-deny `ui_key` combos. Empty by default —
    /// the user opted out of a built-in dangerous-hotkey denylist.
    var blockedKeyCombos: [String]
    /// Activate + raise the target window before a click/type so input lands there. On by default.
    var raiseTargetWindowBeforeClick: Bool
    /// Gate only the FIRST `screen_capture` per run, then auto-allow captures. On by default.
    var gateFirstCaptureOnly: Bool
    /// Optional dedicated LLM override for the Auto judge. Token resolved from Keychain by URL.
    var judgeOverride: LLMOverride?

    init(
        mode: ComputerUseMode = .manual,
        restrictionLevel: ComputerUseRestrictionLevel = .standard,
        targetAppAllowlist: [String] = [],
        blockedTypingPatterns: [String] = [],
        blockedKeyCombos: [String] = [],
        raiseTargetWindowBeforeClick: Bool = true,
        gateFirstCaptureOnly: Bool = true,
        judgeOverride: LLMOverride? = nil
    ) {
        self.mode = mode
        self.restrictionLevel = restrictionLevel
        self.targetAppAllowlist = targetAppAllowlist
        self.blockedTypingPatterns = blockedTypingPatterns
        self.blockedKeyCombos = blockedKeyCombos
        self.raiseTargetWindowBeforeClick = raiseTargetWindowBeforeClick
        self.gateFirstCaptureOnly = gateFirstCaptureOnly
        self.judgeOverride = judgeOverride
    }

    /// Tolerant decoder so a legacy JSON round-trips with safe defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = try c.decodeIfPresent(ComputerUseMode.self, forKey: .mode) ?? .manual
        self.restrictionLevel = try c.decodeIfPresent(ComputerUseRestrictionLevel.self, forKey: .restrictionLevel) ?? .standard
        self.targetAppAllowlist = try c.decodeIfPresent([String].self, forKey: .targetAppAllowlist) ?? []
        self.blockedTypingPatterns = try c.decodeIfPresent([String].self, forKey: .blockedTypingPatterns) ?? []
        self.blockedKeyCombos = try c.decodeIfPresent([String].self, forKey: .blockedKeyCombos) ?? []
        self.raiseTargetWindowBeforeClick = try c.decodeIfPresent(Bool.self, forKey: .raiseTargetWindowBeforeClick) ?? true
        self.gateFirstCaptureOnly = try c.decodeIfPresent(Bool.self, forKey: .gateFirstCaptureOnly) ?? true
        self.judgeOverride = try c.decodeIfPresent(LLMOverride.self, forKey: .judgeOverride)
    }
}
