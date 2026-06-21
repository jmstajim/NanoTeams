import SwiftUI

struct ExploratorySearchIndexStatusCard: View {
    var coordinator: SearchIndexCoordinator?
    var onRebuild: () -> Void

    var body: some View {
        SettingsCard(
            header: "Index Status",
            systemImage: "text.magnifyingglass",
            footer: "Indexing watches the work folder and auto-rebuilds when files change."
        ) {
            if let coordinator {
                statusRow(
                    label: "Files indexed",
                    value: coordinator.fileCount.map { String($0) } ?? "—"
                )
                statusRow(
                    label: "Unique tokens",
                    value: coordinator.tokenCount.map { String($0) } ?? "—"
                )
                statusRow(
                    label: "Last built",
                    value: coordinator.lastBuiltAt.map { lastBuiltString(for: $0) } ?? "—"
                )
                HStack {
                    Text("Status")
                        .font(Typography.subheadline)
                        .foregroundStyle(Colors.textSecondary)
                    Spacer()
                    StatusGlyph(
                        glyph: coordinator.isBuilding ? TerminalGlyph.working : (coordinator.lastError != nil ? TerminalGlyph.failed : TerminalGlyph.idle),
                        color: coordinator.isBuilding ? Colors.accent : (coordinator.lastError != nil ? Colors.error : Colors.neutral),
                        animatesWork: coordinator.isBuilding
                    )
                    Text(coordinator.isBuilding ? "Indexing…" : "Idle (auto-updating)")
                        .font(Typography.subheadlineMedium)
                        .foregroundStyle(Colors.textPrimary)
                }
                if let err = coordinator.lastError {
                    Text(err)
                        .font(Typography.caption)
                        .foregroundStyle(Colors.error)
                }
                HStack {
                    Spacer()
                    SettingsPillButton(title: "Rebuild", icon: "arrow.clockwise") {
                        onRebuild()
                    }
                    .disabled(coordinator.isBuilding)
                }
            } else {
                Text("Exploratory Search is disabled. Enable it above to build an index.")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
            }
        }
    }

    private func statusRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(Typography.subheadline)
                .foregroundStyle(Colors.textSecondary)
            Spacer()
            Text(value)
                .font(Typography.subheadlineMedium)
                .monospacedDigit()
                .foregroundStyle(Colors.textPrimary)
        }
    }

    private func lastBuiltString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

#Preview("Index Status – disabled") {
    ExploratorySearchIndexStatusCard(coordinator: nil, onRebuild: {})
        .padding()
        .background(Colors.surfacePrimary)
}
