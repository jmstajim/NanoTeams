import SwiftUI

/// Who drives the folder's Autovisor: the built-in manager model or an external agent over MCP.
/// One control for the two places that offer the choice — the Autovisor's start page and
/// Settings → Autovisor — so the labels and the captions cannot drift apart. Choosing persists
/// at once through the caller (`setAutovisorDriver`), so the two places never disagree either.
struct AutovisorDriverPicker: View {
    let selection: AutovisorDriver
    var isDisabled: Bool = false
    let onSelect: @MainActor (AutovisorDriver) -> Void

    var body: some View {
        HStack(spacing: Spacing.s) {
            ForEach(AutovisorDriver.allCases, id: \.self) { driver in
                Button(Self.label(for: driver)) {
                    // Re-selecting changes nothing, and `setAutovisorDriver` would still pause
                    // a parked manager on the way.
                    guard driver != selection else { return }
                    onSelect(driver)
                }
                .buttonStyle(driver == selection ? .terminalPrimary : .terminalSecondary)
                .accessibilityAddTraits(driver == selection ? .isSelected : [])
            }
        }
        .disabled(isDisabled)
    }

    nonisolated static func label(for driver: AutovisorDriver) -> String {
        switch driver {
        case .builtInModel: "Built-in Model"
        case .externalAgent: "External Agent (MCP)"
        }
    }

    /// What the choice changes, in one line: who supervises, and which tasks.
    nonisolated static func caption(for driver: AutovisorDriver) -> String {
        switch driver {
        case .builtInModel:
            "A model on your LLM server supervises every task here, on a timer and when a task needs it."
        case .externalAgent:
            "Claude Code, Codex, Cursor or another agent connects over MCP and supervises the tasks it creates."
        }
    }
}
