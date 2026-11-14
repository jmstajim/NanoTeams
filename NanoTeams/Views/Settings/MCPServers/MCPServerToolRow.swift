import SwiftUI

// MARK: - One tool's row

/// A tool row's one layout rule, apart from what it lays out, so a test can hold it at the
/// Settings pane's real widths with the badge, name column and controls the page draws.
///
/// One line where the name and the controls fit beside each other. Where they do not — an
/// approved tool's chip and pill beside a long name, at the Settings window's default or minimum
/// width — the controls go up beside the badge and the name takes the card's whole width, rather
/// than breaking an identifier over three lines (until 2026-10-28: its renders were
/// 620 points wide, and the default pane is about 509).
struct MCPServerToolRowLayout<Badge: View, Name: View, Controls: View>: View {
    let badge: Badge
    let name: Name
    let controls: Controls

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                badge
                name
                controls
            }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.s) {
                    badge
                    Spacer(minLength: 0)
                    controls
                }
                name
            }
        }
    }
}

/// What can be done to one tool: Always allow, on an approved tool of a Semi-automatic server,
/// and its review sheet. The actions are the page's; this only draws them.
struct MCPServerToolControls: View {
    let isApproved: Bool
    let offersAlwaysAllow: Bool
    /// What the connection's observed trust record says, read by the page in `body`.
    let alwaysAllowed: Bool
    let onAlwaysAllow: @MainActor (Bool) -> Void
    let onReview: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            if offersAlwaysAllow {
                Toggle("Always allow", isOn: Binding(
                    get: { alwaysAllowed },
                    set: { onAlwaysAllow($0) }))
                .toggleStyle(.terminalChip)
                .layoutProbe("always-allow")
            }
            SettingsPillButton(title: isApproved ? "View" : "Review", icon: "doc.text.magnifyingglass") {
                onReview()
            }
        }
    }
}
