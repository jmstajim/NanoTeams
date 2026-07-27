import SwiftUI

// MARK: - Terminal Status Glyphs

/// The design's signature "glyph carries status" language. These are mono TEXT
/// characters rendered in SF Mono — distinct from SF Symbol icons. Paired with
/// brightness on the neutral ramp, they tell states apart without relying on
/// color (Monochrome+1 discipline).
///
/// `nonisolated` (like the other token enums, e.g. `Colors`) so these pure string
/// constants are usable from nonisolated contexts — the shared
/// `TeamEngineState.display` descriptor and its tests reference them off the main
/// actor.
nonisolated enum TerminalGlyph {
    static let idle      = "●"
    static let ready     = "●"
    static let working   = "▸"
    static let done      = "✓"
    static let accepted  = "✓"
    static let review    = "◆"
    static let revision  = "↻"
    static let failed    = "✗"
    static let meeting   = "◆"
    static let skipped   = "·"
    static let paused    = "‖"

    static let prompt    = "›"
    static let cursor    = "█"
    static let bullet    = "●"
}

// MARK: - Status → Glyph

extension RoleExecutionStatus {
    private static let glyphMap: [RoleExecutionStatus: String] = [
        .idle: TerminalGlyph.idle,
        .ready: TerminalGlyph.ready,
        .working: TerminalGlyph.working,
        .needsAcceptance: TerminalGlyph.review,
        .accepted: TerminalGlyph.accepted,
        .revisionRequested: TerminalGlyph.revision,
        .done: TerminalGlyph.done,
        .failed: TerminalGlyph.failed,
        .skipped: TerminalGlyph.skipped,
    ]
    /// Terminal status glyph (`●▸✓✗◆ …`). Pairs with `color` + brightness.
    var glyph: String { Self.glyphMap[self] ?? TerminalGlyph.bullet }

    /// Contextual glyph honoring meeting / paused overrides.
    func glyph(isInMeeting: Bool, isPaused: Bool) -> String {
        if isInMeeting { return TerminalGlyph.meeting }
        if isPaused && self == .working { return TerminalGlyph.paused }
        return glyph
    }
}
extension TaskStatus {
    private static let glyphMap: [TaskStatus: String] = [
        .running: TerminalGlyph.working,
        .done: TerminalGlyph.done,
        .paused: TerminalGlyph.paused,
        .waiting: TerminalGlyph.idle,
        .needsSupervisorInput: TerminalGlyph.prompt,
        .needsSupervisorAcceptance: TerminalGlyph.review,
        .failed: TerminalGlyph.failed,
    ]
    var glyph: String { Self.glyphMap[self] ?? TerminalGlyph.bullet }

    /// Chat-mode override: a chat task shows the prompt marker, not a status glyph.
    func glyph(isChatMode: Bool) -> String {
        guard isChatMode else { return glyph }
        switch self {
        case .running, .needsSupervisorInput, .paused: return TerminalGlyph.prompt
        default: return glyph
        }
    }
}

// MARK: - Status Glyph Badge

/// A status glyph rendered at a fixed mono size with its status color — the
/// canonical inline status marker (replaces SF-Symbol status dots in the
/// terminal language). When `working`, animates via `NTMSLoader` (rotating
/// stick + glitch bursts) using the supplied `font` for baseline alignment.
struct StatusGlyph: View {
    let glyph: String
    let color: Color
    var animatesWork: Bool = false
    var font: Font = Typography.termSm

    var body: some View {
        if animatesWork {
            NTMSLoader(font: font, color: color)
        } else {
            Text(glyph)
                .font(font)
                .foregroundStyle(color)
                .accessibilityHidden(true)
        }
    }
}
