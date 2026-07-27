import SwiftUI

/// The ⓘ that sits beside every **Goal** label, carrying what the Autovisor's
/// manager can and cannot do — and turning into a warning when the goal in the
/// editor asks it for a capability it lacks.
///
/// Why a tip and not validation: the manager's toolset is a fact the user cannot
/// be expected to hold in their head, and the failure it prevents is expensive
/// but not certain — a goal naming `write_file` for its WORKERS is perfectly
/// correct. So this never blocks Enable and never disables a control.
///
/// Anti-nag, three ways: evaluation is debounced, the lenient scan
/// (`scanUserAuthored`) suppresses lines addressed to workers, and it stays in
/// the neutral state while the goal is still the unset default. There is no
/// Dismiss — an icon that never moves the layout has nothing to dismiss, which
/// is the whole reason this replaced the banner it grew out of.
///
/// Self-contained by design: it reads the host's goal string directly rather
/// than sharing state with `AutovisorGoalComposer`, so each of the three goal
/// surfaces drops it next to its own label with no bindings and no state lifting.
///
/// Carries NO `.keyboardShortcut` / `.focusable` (nor does `InfoTip`): on the
/// Settings surface this button is hosted inside `TerminalPane`'s title-chip
/// `.overlay`, which is in the ancestor chain of the `NSScrollView`-backed goal
/// editor — responder-participating content there re-enters SwiftUI's display
/// list on every CoreAnimation frame the scroll view emits (CLAUDE.md #50).
struct AutovisorGoalLintTip: View {
    let goal: String
    /// Sized to the label it sits beside — `termXs` matches `MonoLabel(.sm)`;
    /// hosts on a 10pt label (Watchtower card, the `┤ GOAL ├` chip) pass `term2xs`.
    var font: Font = Typography.termXs

    @State private var findings: [AutovisorGoalLint.Finding] = []
    @State private var lintTask: Task<Void, Never>?

    var body: some View {
        InfoTip(
            AutovisorGoalLintCopy.popover(for: findings),
            systemImage: AutovisorGoalLintCopy.symbolName(for: findings),
            tint: findings.isEmpty ? Colors.textTertiary : Colors.warning,
            font: font,
            accessibilityLabel: AutovisorGoalLintCopy.accessibilityLabel(for: findings)
        )
        .onAppear { scheduleLint(debounced: false) }
        .onChange(of: goal) { _, _ in scheduleLint(debounced: true) }
        .onDisappear { lintTask?.cancel() }
    }

    /// Debounced so the icon cannot flicker mid-keystroke, and silent while the
    /// goal is still unset — the seeded default placeholder must never warn.
    ///
    /// The `debounced: false` first pass is load-bearing now that the icon is
    /// always on screen: `.task(id:)` (or an unconditional sleep) would render
    /// the neutral ⓘ and then visibly flip it to a warning a second after the
    /// pane opens on an already-offending saved goal.
    private func scheduleLint(debounced: Bool) {
        lintTask?.cancel()
        let goal = goal
        guard !AutovisorPolicy.goalIsUnset(goal) else {
            findings = []
            return
        }
        lintTask = Task { @MainActor in
            if debounced {
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
            }
            findings = AutovisorGoalLint.scanUserAuthored(goal)
        }
    }
}

// MARK: - Copy

/// The pure findings → (symbol, copy, label) mapping behind the tip, split out so
/// the wording and the token-list truncation are testable without rendering a view.
nonisolated enum AutovisorGoalLintCopy {

    /// Names the gap in terms of what the manager CAN do, then where the missing
    /// half actually happens — a capability sentence on its own states a limit
    /// and leaves the reader nowhere to go, and delegation IS the mechanism
    /// (`create_managed_task` → a team whose workers do have write and shell).
    static let capability =
        "The Autovisor's manager can read files, read git and delegate — "
        + "it has no shell, write or build tools. Anything that has to be "
        + "written, built or run goes to a team it delegates to."

    /// The goal-specific half, or `nil` when the goal is clean.
    static func detail(for findings: [AutovisorGoalLint.Finding]) -> String? {
        guard !findings.isEmpty else { return nil }

        let tools = findings.filter { $0.kind != .selfDirectedBuildClaim }
        if tools.isEmpty {
            return "This goal tells it to build or run something itself. "
                + "If that's meant for the teams it delegates to, say so in the goal."
        }
        let names = Array(Set(tools.map(\.token))).sorted()
        let shown = names.prefix(3).joined(separator: ", ")
        let suffix = names.count > 3 ? ", …" : ""
        return "This goal names \(shown)\(suffix). "
            + "If that's meant for the teams it delegates to, you can ignore this."
    }

    static func popover(for findings: [AutovisorGoalLint.Finding]) -> String {
        guard let detail = detail(for: findings) else { return capability }
        return capability + "\n\n" + detail
    }

    static func symbolName(for findings: [AutovisorGoalLint.Finding]) -> String {
        findings.isEmpty ? "info.circle" : "exclamationmark.triangle"
    }

    static func accessibilityLabel(for findings: [AutovisorGoalLint.Finding]) -> String {
        findings.isEmpty
            ? "About the Autovisor manager's tools"
            : "Goal capability warning"
    }
}

#Preview("AutovisorGoalLintTip") {
    VStack(alignment: .leading, spacing: Spacing.l) {
        HStack(spacing: Spacing.xs) {
            MonoLabel(text: "Goal", marker: true)
            AutovisorGoalLintTip(goal: "Keep the test suite green and report findings.")
        }
        HStack(spacing: Spacing.xs) {
            MonoLabel(text: "Goal", size: .xs)
            AutovisorGoalLintTip(
                goal: "Then call write_file yourself and run the build.",
                font: Typography.term2xs
            )
        }
    }
    .padding(Spacing.xl)
    .frame(width: 360, alignment: .leading)
    .background(Colors.surfaceCard)
}
