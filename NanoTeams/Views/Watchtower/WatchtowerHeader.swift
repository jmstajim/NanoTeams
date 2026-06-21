import SwiftUI

// MARK: - Watchtower Header

/// Watchtower masthead — mirrors
/// `DesignSystemByClaude/ui_kits/desktop/Watchtower.jsx` lines 199-223:
///
///   figlet "nanoteams" banner (full width, mono, text-3 watermark)
///   ┌─ left cluster ───────────────────┐ ┌─ right cluster ────────────────────┐
///   │ ▌ WATCHTOWER                     │ │ [ AUTOVISOR · [ ] OFF ]  [ new ▸ ] │
///   │ N tasks need you█                │ │                                    │
///   │ $ watch --inbox · clears…        │ │                                    │
///   └──────────────────────────────────┘ └────────────────────────────────────┘
struct WatchtowerHeader: View {
    /// Number of items currently needing Supervisor attention (drives the
    /// "{N} tasks need you" headline). Caller counts notifications via
    /// `WatchtowerNotification.needsYouCount` (includes failed / timed-out).
    var needsYouCount: Int
    /// "new task" primary button (opens the QuickCapture overlay).
    var onNewTask: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Cursor blink half-period (seconds) — one full on→off→on cycle is `2 * blinkPeriod`.
    private static let blinkPeriod: TimeInterval = 0.55

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            figletBanner
            HStack(alignment: .top, spacing: Spacing.m) {
                // The action CTAs (Autovisor pill + "new task") are `.fixedSize`d in
                // `actionsCluster`, so they hold their intrinsic width and are NOT the
                // first to compress in a narrow window. Layout contention falls on the
                // headline (truncates) and the `lineLimit(1)` shortcut hints. The title
                // keeps `layoutPriority(1)` so it still wins over the shortcut hints.
                titleCluster
                    .layoutPriority(1)
                Spacer(minLength: Spacing.m)
                actionsCluster
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Figlet banner

    /// The «nanoteams» figlet masthead with a scan-decode reveal animation.
    /// Data + decode logic live in `WatchtowerFiglet` / `WatchtowerFigletBanner`
    /// (own file) so the layout-stability rationale and the testable frame math
    /// stay together there.
    private var figletBanner: some View {
        WatchtowerFigletBanner()
    }

    // MARK: - Title cluster

    private var titleCluster: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            MonoLabel(text: "watchtower", accent: true, marker: true)
            headline
            subtitle
        }
    }

    /// "{N} tasks need you█" when there's pending work — "need you" in accent,
    /// blinking █ cursor. Falls back to "all clear█" with a steady cursor when the
    /// inbox is empty. The cursor is concatenated INTO the accent run, glued by a
    /// non-breaking space (`\u{00A0}`), so it stays anchored to the end of "you" /
    /// "clear" no matter where the headline wraps (a sibling `Text` in an HStack
    /// would lock to the first-line baseline and float away from the last line
    /// when the headline wraps to multiple rows in a narrow window).
    ///
    /// The blink is driven by `TimelineView` — NOT by the SwiftUI animation system.
    /// Both `withAnimation { … }` AND `.animation(_:value:)` open animation
    /// transactions; SwiftUI then interpolates ALL animatable view deltas inside
    /// them with the same easeInOut curve, including soft layout shifts of sibling
    /// elements (figlet scale, actions cluster position) when the parent re-renders
    /// for unrelated reasons during the 0.55s window — that's the "drift" the user
    /// saw. `TimelineView` re-evaluates its content closure on each tick without an
    /// animation transaction, so the cursor flips foregroundStyle discretely (like
    /// a real terminal cursor) and `█`'s fixed mono advance width keeps layout
    /// rock-stable across the toggle.
    @ViewBuilder
    private var headline: some View {
        Group {
            if Self.shouldBlink(reduceMotion: reduceMotion, hasTasks: hasTasks) {
                TimelineView(.periodic(from: .now, by: Self.blinkPeriod)) { context in
                    headlineContent(showCursor: shouldShowCursor(at: context.date))
                }
            } else {
                // Nothing to animate: Reduce Motion pins a steady cursor and an
                // empty inbox renders no cursor at all. Render the content directly
                // so we DON'T mount a `TimelineView` that would re-evaluate its
                // closure every `blinkPeriod` forever with identical output.
                headlineContent(showCursor: true)
            }
        }
        .font(Typography.term2xl)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityHeadline)
    }

    /// Whether the cursor should blink — only when motion is allowed AND there is
    /// pending work. Reduce Motion (steady cursor) or an empty inbox (no cursor)
    /// renders a static headline, so the `TimelineView` and its forever ticks are
    /// mounted only when there is genuinely something to animate. Pure + nonisolated
    /// for tests.
    nonisolated static func shouldBlink(reduceMotion: Bool, hasTasks: Bool) -> Bool {
        !reduceMotion && hasTasks
    }

    /// Pure phase calculation — keeps the `TimelineView` closure thin. Only reached
    /// when `shouldBlink` is true (motion allowed + pending tasks); the leading
    /// `guard` is defensive belt-and-suspenders.
    private func shouldShowCursor(at date: Date) -> Bool {
        guard !reduceMotion else { return true }
        return Int(date.timeIntervalSinceReferenceDate / Self.blinkPeriod) % 2 == 0
    }

    /// Concatenated `Text` so the cursor stays glued to the end of the accent
    /// phrase (`\u{00A0}` non-breaking space) across multi-line wrap. The cursor
    /// is rendered ONLY when there are pending tasks — `all clear` is a resting
    /// state with no terminal cursor (nothing to type at).
    private func headlineContent(showCursor: Bool) -> Text {
        let accent = Text(accentPhrase).foregroundStyle(Colors.accent)
        guard hasTasks else { return accent }
        let cursorTail = "\u{00A0}\(TerminalGlyph.cursor)"
        let cursor = Text(cursorTail).foregroundStyle(showCursor ? Colors.accent : Color.clear)
        return Text(prefixText).foregroundStyle(Colors.textPrimary) + accent + cursor
    }

    private var hasTasks: Bool { needsYouCount > 0 }
    private var prefixText: String { hasTasks ? "\(needsYouCount) tasks " : "" }
    private var accentPhrase: String { hasTasks ? "need you" : "all clear" }
    private var accessibilityHeadline: String {
        hasTasks ? "\(needsYouCount) tasks need you" : "all clear"
    }

    /// "$ watch --inbox · open a task or chat to clear it".
    private var subtitle: some View {
        HStack(spacing: Spacing.xs) {
            Text("$")
                .foregroundStyle(Colors.textQuaternary)
                .accessibilityHidden(true)
            Text("watch --inbox · open a task or chat to clear it")
                .foregroundStyle(Colors.textTertiary)
        }
        .font(Typography.caption)
    }

    // MARK: - Actions cluster (right side)

    /// Right-side column: AUTOVISOR + "new task" controls on top, the global
    /// keyboard-shortcut hints stacked beneath them. Leading-aligned so the
    /// shortcut hints row starts at the AUTOVISOR button's left edge. The top
    /// row is the widest, so it still spans the cluster width and the "new task"
    /// CTA keeps hugging the window's right edge (the cluster is trailing-placed
    /// in the parent HStack via Spacer).
    private var actionsCluster: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                // Autovisor state is snapshot-derived and the Autovisor manager
                // reassigns the snapshot on every memory write during a review pass.
                // Reading it inside this leaf (rather than passing it from
                // `WatchtowerView.body`) keeps that churn from re-evaluating the whole
                // Watchtower body (figlet + timeline + notifications) — CLAUDE.md #11.
                WatchtowerAutovisorPill()
                Button("new task", action: onNewTask)
                    .buttonStyle(.terminalPrimary)
                    .keyboardShortcut("n", modifiers: .command)
            }
            // Pin the two CTAs at their intrinsic width so they are NOT the first
            // thing to compress in a narrow window. Contention falls instead on the
            // headline (truncates) and the `lineLimit(1)` shortcut hints below.
            .fixedSize(horizontal: true, vertical: false)
            shortcutHints
        }
    }

    // MARK: - Shortcut hints

    private var shortcutHints: some View {
        HStack(spacing: Spacing.s) {
            HStack(spacing: Spacing.xxs) {
                ForEach(["⌃", "⌥", "⌘"], id: \.self) { key in
                    shortcutKey(key)
                }
            }
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.s) {
                    shortcutKey("0")
                    Text("Quick Task")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textTertiary)
                        .lineLimit(1)
                    InfoTip("Open the floating overlay panel to create a task, answer a question, or send a chat message.\n\nShortcut: ⌃ ⌥ ⌘ 0")
                }
                HStack(spacing: Spacing.s) {
                    shortcutKey("K")
                    Text("Context Capture")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textTertiary)
                        .lineLimit(1)
                    InfoTip("Capture the current selection (text or files) from any app and attach it to the Quick Task panel.\n\nShortcut: ⌃ ⌥ ⌘ K")
                }
            }
        }
    }

    private func shortcutKey(_ key: String) -> some View {
        Text(key)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Colors.textSecondary)
            .frame(minWidth: 20, minHeight: 20)
            .background(
                RoundedRectangle.squircle(CornerRadius.micro)
                    .fill(Colors.surfaceElevated)
            )
    }
}

// MARK: - Autovisor Pill (leaf)

/// "AUTOVISOR [ ] OFF" / "AUTOVISOR [x] ON" pill toggle — matches the JSX header
/// masthead AUTOVISOR control (Watchtower.jsx:216-220). Reads + writes the
/// snapshot-derived Autovisor state itself so its high-frequency churn (manager
/// memory writes during a review pass) stays isolated to this leaf (CLAUDE.md #11).
///
/// Setup intercept: an OFF→ON click while the manager `needsSetup` routes to
/// `AutovisorSetupView` instead of toggling. Rationale — flipping `enabled = true`
/// silently seeds the goal to `AutovisorConstants.defaultGoal` (the "explore &
/// wait" placeholder), and the user has no obvious surface to find/edit it, so
/// the manager runs with a placeholder until they happen to open Settings. Making
/// the pill the discoverable doorway eliminates that hidden state. The gate is the
/// shared `store.autovisorNeedsSetup` — the SAME predicate `autovisorDetail` routes
/// on — so the intercept always lands on the setup pane, never on the chat (the
/// prior local `goalNeedsSetup` could route to setup while the detail pane, gated
/// on `autovisorTaskID == nil`, showed the chat instead for a created-then-disabled
/// manager). Toggling OFF is never intercepted — disabling is always immediate.
struct WatchtowerAutovisorPill: View {
    @Environment(NTMSOrchestrator.self) private var store

    private var enabled: Bool { store.workFolder?.settings.autovisorEnabled ?? false }

    /// Whether the manager isn't ready to run (never created, or disabled with an
    /// unset goal) — the shared routing predicate, so the pill's intercept and the
    /// detail-pane setup-vs-chat decision can't diverge.
    private var needsSetup: Bool { store.autovisorNeedsSetup }

    var body: some View {
        // Hidden in default storage (no real work folder) — the Autovisor can't
        // be enabled there (`AutovisorPolicy.canEnable`), so showing a toggle that
        // persists `ON` while `ensureAutovisorTask` no-ops would be a dead control.
        // Matches the old `QuickAction.makeActions` `hasWorkFolder` gate the
        // redesign dropped.
        if AutovisorPolicy.canEnable(hasRealWorkFolder: store.hasRealWorkFolder) {
            pill
        }
    }

    /// Dispatches the click per the setup-intercept rule above.
    private func handleTap() {
        if !enabled && needsSetup {
            NotificationCenter.default.post(name: .navigateToAutovisor, object: nil)
            return
        }
        let next = !enabled
        Task { await store.setAutovisorEnabled(next) }
    }

    private var pill: some View {
        Button(action: handleTap) {
            HStack(spacing: Spacing.xs) {
                Text("AUTOVISOR")
                    .font(Typography.term2xs.weight(.medium))
                    .tracking(Typography.labelTracking)
                    .foregroundStyle(Colors.textTertiary)
                Text(enabled ? "[x]" : "[ ]")
                    .font(Typography.term2xs)
                    .foregroundStyle(enabled ? Colors.accent : Colors.textTertiary)
                Text(enabled ? "ON" : "OFF")
                    .font(Typography.term2xs.weight(.medium))
                    .tracking(Typography.labelTracking)
                    .foregroundStyle(enabled ? Colors.accent : Colors.textTertiary)
            }
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs)
            .background(
                RoundedRectangle.squircle(CornerRadius.small)
                    .fill(Colors.surfaceElevated)
            )
            .overlay(
                RoundedRectangle.squircle(CornerRadius.small)
                    .strokeBorder(Colors.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel("Autovisor")
        .accessibilityValue(enabled ? "On" : "Off")
        .accessibilityHint(accessibilityHintText)
        .accessibilityAddTraits(enabled ? [.isSelected] : [])
    }

    private var helpText: String {
        if enabled { return "Autovisor is on — click to turn off" }
        if needsSetup { return "Set up Autovisor — pick a goal first" }
        return "Autovisor is off — click to turn on"
    }

    private var accessibilityHintText: String {
        if enabled { return "Turns Autovisor off" }
        if needsSetup { return "Opens the Autovisor setup pane" }
        return "Turns Autovisor on"
    }
}

// MARK: - Preview

#Preview {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    VStack(spacing: Spacing.l) {
        WatchtowerHeader(
            needsYouCount: 3,
            onNewTask: {}
        )
        Spacer()
    }
    .padding(Spacing.l)
    .frame(width: 760, height: 300)
    .background(Colors.surfacePrimary)
    .environment(store)
}
