import SwiftUI

// MARK: - Team Board Top Bar

/// The Team Board's terminal-style navbar, modelled on
/// `DesignSystemByClaude/ui_kits/desktop/TeamBoard.jsx` (lines 354–368):
///
///   ┌────────────────────────────────────────────────────────────────────┐
///   │ task/<title>                          [pause]  ⟳  ⋯  ▣            │
///   │ <TEAM> · RUN #N                                                    │
///   └────────────────────────────────────────────────────────────────────┘
///
/// Replaces the native macOS `.toolbar` block on Team Board so the chrome above
/// the content is a single, fully-DS-aligned strip — no round AppKit bezels, no
/// duplicate title row. The native window title bar still renders the traffic
/// lights but is otherwise empty (macOS convention; we don't suppress the
/// title bar globally).
///
/// The right cluster is supplied by the parent via the `actions` slot so
/// TeamBoardView keeps its own action handlers + sheet state — TopBar just
/// hosts the layout + styling.
struct TeamBoardTopBar<Actions: View>: View {
    let taskTitle: String
    let teamName: String
    let runLabel: String?
    let engineState: TeamEngineState?
    let isHistoricalRun: Bool
    /// A run start is claimed but has not reached `engine.start()` yet — the navbar
    /// offers `pause` instead of a `start` that would be refused. Defaulted so the
    /// previews and any future host that has no access to the fact keep compiling into
    /// the pre-2026-08-27 behaviour rather than silently claiming "not initializing".
    var isInitializingRun: Bool = false
    let onPause: () -> Void
    let onResume: () -> Void
    let onStart: () -> Void
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.m) {
            titleColumn
            Spacer(minLength: Spacing.m)
            playPauseControl
            NavbarActionsCluster { actions }
        }
        .terminalTopBarChrome()
    }

    // MARK: - Title column

    private var titleColumn: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: 0) {
                Text("task/")
                    .font(Typography.termBase)
                    .foregroundStyle(Colors.textTertiary)
                Text(taskTitle)
                    .font(Typography.termBase)
                    .fontWeight(.semibold)
                    .foregroundStyle(Colors.textPrimary)
            }
            .lineLimit(1)
            .truncationMode(.tail)

            Text(subtitle)
                .font(Typography.term2xs)
                .tracking(Typography.labelTracking)
                .foregroundStyle(Colors.textTertiary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let team = teamName.uppercased()
        guard let run = runLabel?.uppercased(), !run.isEmpty else { return team }
        return "\(team) · \(run)"
    }

    // MARK: - Pause / Resume control

    /// Renders the run-control as a secondary terminal button with mono
    /// `pause` / `resume` / `start` text, per the JSX spec's
    /// `<Button size="sm" variant="secondary">`.
    @ViewBuilder
    private var playPauseControl: some View {
        switch TeamBoardRunControl.select(
            engineState: engineState,
            isHistoricalRun: isHistoricalRun,
            isInitializingRun: isInitializingRun
        ) {
        case .pause:
            Button("pause", action: onPause)
                .buttonStyle(.terminalSecondary)
                .controlSize(.small)
                .accessibilityLabel("Pause Run")
        case .resume:
            Button("resume", action: onResume)
                .buttonStyle(.terminalSecondary)
                .controlSize(.small)
                .accessibilityLabel("Resume Run")
        case .start:
            Button("start", action: onStart)
                .buttonStyle(.terminalSecondary)
                .controlSize(.small)
                .accessibilityLabel("Start Run")
        case nil:
            EmptyView()
        }
    }

}

// MARK: - Previews

#if DEBUG
#Preview("Top Bar Variants") {
    VStack(spacing: 0) {
        TeamBoardTopBar(
            taskTitle: "Implement dark mode",
            teamName: "FAANG Team",
            runLabel: "run #4",
            engineState: .running,
            isHistoricalRun: false,
            onPause: {}, onResume: {}, onStart: {}
        ) {
            Button { } label: { Label("Automation", systemImage: "arrow.triangle.2.circlepath") }
            Menu {
                Button("New Run") { }
                Button("Run History") { }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .navbarIconCell()
            Button { } label: { Label("Graph", systemImage: "sidebar.trailing") }
        }
        TeamBoardTopBar(
            taskTitle: "Tune embedding thresholds",
            teamName: "Engineering Team",
            runLabel: "run #2",
            engineState: .paused,
            isHistoricalRun: false,
            onPause: {}, onResume: {}, onStart: {}
        ) {
            Button { } label: { Label("Automation", systemImage: "arrow.triangle.2.circlepath") }
            Button { } label: { Label("More", systemImage: "ellipsis") }
            Button { } label: { Label("Graph", systemImage: "sidebar.trailing") }
        }
        TeamBoardTopBar(
            taskTitle: "Migration to Swift 6",
            teamName: "FAANG Team",
            runLabel: "run #7",
            engineState: .needsAcceptance,
            isHistoricalRun: false,
            onPause: {}, onResume: {}, onStart: {}
        ) {
            Button { } label: { Label("Review", systemImage: "eye.circle") }
                .tint(Colors.purple)
            Button { } label: { Label("Automation", systemImage: "arrow.triangle.2.circlepath") }
            Button { } label: { Label("More", systemImage: "ellipsis") }
            Button { } label: { Label("Graph", systemImage: "sidebar.trailing") }
        }
        TeamBoardTopBar(
            taskTitle: "Build failing on CI",
            teamName: "Engineering Team",
            runLabel: "run #3",
            engineState: .failed,
            isHistoricalRun: false,
            onPause: {}, onResume: {}, onStart: {}
        ) {
            Button { } label: { Label("Automation", systemImage: "arrow.triangle.2.circlepath") }
            Button { } label: { Label("More", systemImage: "ellipsis") }
            Button { } label: { Label("Graph", systemImage: "sidebar.trailing") }
        }
    }
    .frame(width: 800)
    .background(Colors.surfacePrimary)
}
#endif
