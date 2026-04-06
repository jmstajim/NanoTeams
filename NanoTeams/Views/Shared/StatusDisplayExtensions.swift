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
        .paused: "pause.circle.fill",
        .needsSupervisorInput: "questionmark.bubble.fill",
        .needsApproval: "checkmark.seal.fill",
        .failed: "xmark.circle.fill",
        .done: "checkmark.circle.fill",
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
        .done: "checkmark.circle.fill",
        .paused: "pause.circle.fill",
        .waiting: "circle",
        .needsSupervisorInput: "questionmark.bubble.fill",
        .needsSupervisorAcceptance: "eye.circle.fill",
        .failed: "xmark.circle.fill",
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
        case .running, .needsSupervisorInput, .paused: return "bubble.left.and.bubble.right.fill"
        default: return systemImageName
        }
    }
}
