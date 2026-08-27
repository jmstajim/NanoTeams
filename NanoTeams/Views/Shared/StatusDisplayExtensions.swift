import SwiftUI

// MARK: - StepStatus Display Extensions

extension StepStatus {
    private static let displayLabelMap: [StepStatus: String] = [
        .pending: "Pending",
        .running: "Running",
        .paused: "Paused",
        .needsSupervisorInput: "Needs Supervisor input",
        .needsApproval: "Needs review",
        .failed: "Failed",
        .done: "Done",
    ]

    var displayLabel: String {
        Self.displayLabelMap[self] ?? rawValue
    }

    private static let shortDisplayLabelOverrides: [StepStatus: String] = [
        .needsSupervisorInput: "Needs Supervisor",
        .needsApproval: "Needs review",
    ]

    var shortDisplayLabel: String {
        Self.shortDisplayLabelOverrides[self] ?? displayLabel
    }

    private static let tintColorMap: [StepStatus: Color] = [
        .pending: Colors.neutral,
        .running: Colors.info,
        .paused: Colors.warning,
        .needsSupervisorInput: Colors.gold,
        .needsApproval: Colors.purple,
        .failed: Colors.error,
        .done: Colors.success,
    ]

    var tintColor: Color { // periphery:ignore
        Self.tintColorMap[self] ?? Colors.neutral
    }

    private static let systemImageNameMap: [StepStatus: String] = [
        .pending: "circle.dotted",
        .running: "circle.inset.filled",
        .paused: "pause.circle",
        .needsSupervisorInput: "questionmark.bubble",
        .needsApproval: "checkmark.seal",
        .failed: "xmark.circle",
        .done: "checkmark.circle",
    ]

    var systemImageName: String {
        Self.systemImageNameMap[self] ?? "circle"
    }
}

// MARK: - TaskStatus Display Extensions

extension TaskStatus {
    private static let tintColorMap: [TaskStatus: Color] = [
        .running: Colors.info,
        .done: Colors.success,
        .paused: Colors.warning,
        .waiting: Colors.neutral,
        .needsSupervisorInput: Colors.gold,
        .needsSupervisorAcceptance: Colors.purple,
        .failed: Colors.error,
    ]

    var tintColor: Color {
        Self.tintColorMap[self] ?? Colors.neutral
    }

    private static let systemImageNameMap: [TaskStatus: String] = [
        .running: "circle.inset.filled",
        .done: "checkmark.circle",
        .paused: "pause.circle",
        .waiting: "circle",
        .needsSupervisorInput: "questionmark.bubble",
        .needsSupervisorAcceptance: "eye.circle",
        .failed: "xmark.circle",
    ]

    var systemImageName: String {
        Self.systemImageNameMap[self] ?? "circle"
    }

    // MARK: - Chat Mode Overrides

    func displayLabel(isChatMode: Bool) -> String {
        guard isChatMode else { return displayLabel }
        switch self {
        case .running, .needsSupervisorInput, .paused: return "Chat"
        default: return displayLabel
        }
    }

    func tintColor(isChatMode: Bool) -> Color {
        guard isChatMode else { return tintColor }
        switch self {
        case .running, .needsSupervisorInput, .paused: return Colors.textTertiary
        default: return tintColor
        }
    }

    func systemImageName(isChatMode: Bool) -> String {
        guard isChatMode else { return systemImageName }
        switch self {
        case .running, .needsSupervisorInput, .paused: return "bubble.left.and.bubble.right"
        default: return systemImageName
        }
    }
}

// MARK: - TeamEngineState Display Extensions

extension TeamEngineState {
    /// One canonical visual descriptor for a team engine state — terminal glyph,
    /// lowercase label, foreground color, and the matching tint background.
    ///
    /// Single source of truth shared by the Team Board navbar badge
    /// (`TeamBoardTopBar`) and the delegation-layer graph pills
    /// (`GraphPanelView`) so the same engine state never renders two different
    /// colors. Colors mirror the `TaskStatus` / `StepStatus` semantic palette
    /// above (running→info, paused→warning, needsAcceptance→purple,
    /// needsSupervisorInput→gold, done→success, failed→error, idle→tertiary).
    nonisolated struct Display {
        let glyph: String
        let label: String
        let color: Color
        let tint: Color
    }

    /// Resolves the display descriptor for an optional engine state. `nil`
    /// (no engine yet) and `.pending` both read as idle. `isChatMode` swaps the
    /// `.running` label from "working" to "chat" (the navbar badge distinction).
    /// `nonisolated` (the body only reads nonisolated `Colors` / `TerminalGlyph`)
    /// so it's callable from tests even though `TeamEngineState` is `@MainActor`.
    nonisolated static func display(for state: TeamEngineState?, isChatMode: Bool = false) -> Display {
        switch state {
        case .running:
            return Display(glyph: TerminalGlyph.working,
                           label: isChatMode ? "chat" : "working",
                           color: Colors.info, tint: Colors.infoTint)
        case .paused:
            return Display(glyph: TerminalGlyph.paused, label: "paused",
                           color: Colors.warning, tint: Colors.warningTint)
        case .needsAcceptance:
            return Display(glyph: TerminalGlyph.review, label: "review",
                           color: Colors.purple, tint: Colors.purpleTint)
        case .needsSupervisorInput:
            return Display(glyph: TerminalGlyph.prompt, label: "needs input",
                           color: Colors.gold, tint: Colors.warningTint)
        case .done:
            return Display(glyph: TerminalGlyph.done, label: "done",
                           color: Colors.success, tint: Colors.neutralTint)
        case .failed:
            return Display(glyph: TerminalGlyph.failed, label: "failed",
                           color: Colors.error, tint: Colors.errorTint)
        case .pending, .none:
            return Display(glyph: TerminalGlyph.idle, label: "idle",
                           color: Colors.textTertiary, tint: Colors.dimTint)
        }
    }
}

// MARK: - Run Initialization Display

/// The one word for the window between "the Supervisor pressed Send / Play" and
/// `engine.start()` — the agent-instruction and role-skill rescans that feed the first
/// prompt, then the engine coming up.
///
/// One constant because two surfaces render it — the activity feed's trailing loader row
/// and the Quick Capture working header — and a word spelled twice is a word that drifts
/// (CLAUDE.md #123). The decision belongs to the value; the surfaces only draw it
/// (CLAUDE.md #107). `RunInitializationDisplayPinTests` holds the literal to this file, so
/// a third surface inherits the same word rather than inventing one.
///
/// Vocabulary it sits in, all of it already on screen for the phases either side of this
/// one: `Thinking…`, `Waiting`, `Processing 42%`, `Generating…`. The trailing ellipsis is
/// that family's "a process is live" mark — the sidebar, which shows only the braille
/// spinner and keeps its own `TaskStatus` label, deliberately renders no text from here.
nonisolated enum RunInitializationDisplay {
    static let caption = "Initializing…"
}
