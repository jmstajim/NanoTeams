import SwiftUI

/// The server page's Status card: the switches that decide whether anything below happens at
/// all, where the server stands, and what can be done to it.
///
/// Its own view so the page's layout can be measured at the Settings window's real widths — the
/// detail pane is about 509 pt at the window's default size and about 409 at its minimum
/// (`MCPServersSettingsViewTests`). Every decision on it is `MCPServerDetailPresentation`'s;
/// this only draws what that says.
struct MCPServerStatusCard: View {

    let row: MCPServerRow
    let presentation: MCPServerDetailPresentation
    /// Drives the Refresh pill's loader; whether it is enabled is the presentation's.
    let isRefreshing: Bool
    /// A switch row was flipped to the value given — the page attempts the row's own action.
    let onFlip: @MainActor (MCPServerDetailPresentation.SwitchRow, Bool) -> Void
    let onEdit: @MainActor () -> Void
    let onReconnect: @MainActor () -> Void
    let onRefresh: @MainActor () -> Void
    let onDelete: @MainActor () -> Void

    nonisolated static func approvalModeTagLabel(for config: MCPServerConfig) -> String {
        switch config.approvalMode {
        case .manual, .semiAutomatic:
            return config.approvalMode.displayName
        case .auto:
            return "Auto · \(config.judgeStrictness.displayName)"
        }
    }

    /// The power switch first, then the folder rule beneath it, then where the server stands,
    /// then what can be done to it. The actions live in the card's body: the `┤ STATUS ├` chip
    /// is a slot for a badge, and three pills drawn there straddled the border and overlapped
    /// the first row (F50).
    var body: some View {
        // "Server", not "Status": the card is the server — its name and address, its switches,
        // where it stands and what can be done to it — of which the status is one line.
        SettingsCard(header: "Server") {
            SettingsItemHeader(
                icon: "server.rack",
                title: row.config.effectiveDisplayName,
                subtitle: row.config.transport.http.urlString)

            switches

            badgeRow

            if let reason = row.status.reason {
                Text(reason)
                    .font(Typography.monoCaption)
                    .foregroundStyle(Colors.textTertiary)
                    .textSelection(.enabled)
            }
            if let line = presentation.protocolLine { caption(line) }
            if let line = presentation.selfReport { caption(line) }

            // No sentence about the missing token here: the badge says "Needs a token", the
            // list row says it, and the Tools card says where to paste it. A fourth line said
            // it in warning ink (until the design review of 2026-11-07).
            actionRow
        }
    }

    // MARK: - Switches

    /// Exactly the rows the presentation lists, in its order; each flip is handed back with the
    /// row it came from, so the page attempts that row's own action.
    private var switches: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            ForEach(presentation.switchRows) { switchRow in
                let indent = switchRow.isNested ? SettingsLayout.toggleIconSize : 0
                SettingsToggleRow(
                    title: switchRow.title, icon: switchRow.icon,
                    isOn: Binding(
                        get: { switchRow.isOn },
                        set: { on in onFlip(switchRow, on) }))
                    .padding(.leading, indent)
                    .opacity(switchRow.waitingNote == nil ? 1 : 0.55)
                if let note = switchRow.waitingNote {
                    caption(note)
                        .padding(.leading, indent + Spacing.s)
                }
            }
        }
    }

    // MARK: - Where it stands

    /// The status badge and its tags on one line where they fit, and the tags on a line of
    /// their own under the badge where they do not: every one is a fixed-size badge that cannot
    /// shrink, and "CONNECTED · 3 TO REVIEW · 1 APPROVED" + TRUSTED + SEMI-AUTOMATIC is wider
    /// than the pane at the Settings window's default size (until 2026-10-28).
    private var badgeRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.s) {
                statusBadge
                tags
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                statusBadge
                HStack(spacing: Spacing.s) {
                    tags
                }
            }
        }
    }

    private var statusBadge: some View {
        TerminalStatusBadge(
            glyph: MCPServerStatusStyle.glyph(for: row.status),
            label: row.subtitle,
            color: MCPServerStatusStyle.color(for: row))
    }

    @ViewBuilder
    private var tags: some View {
        if row.config.isTrusted {
            TerminalStatusBadge.tag(label: "trusted")
        }
        TerminalStatusBadge.tag(label: Self.approvalModeTagLabel(for: row.config))
    }

    // MARK: - What can be done to it

    /// Every action on the server inside the card — one row where the pills fit, and where they
    /// do not (the Settings window's default and minimum widths) the destructive one on a line
    /// of its own at the trailing edge, under the others. Removing is one of them: a whole card
    /// for one button spent a header and a footer on it, and its sentence is the confirmation's
    /// message and this pill's tooltip. Fixed-size pills cannot shrink, and the one row of four
    /// was wider than the pane: the page lost its margin, and at the minimum width "Remove
    /// server" was cut off (until 2026-10-28).
    private var actionRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.xs) {
                editPill
                reconnectPill
                refreshPill
                Spacer(minLength: 0)
                removePill
            }
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(spacing: Spacing.xs) {
                    editPill
                    reconnectPill
                    refreshPill
                }
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    removePill
                }
            }
        }
    }

    private var editPill: some View {
        SettingsPillButton(title: "Edit", icon: "pencil", action: onEdit)
    }

    private var reconnectPill: some View {
        SettingsPillButton(title: "Reconnect", icon: "arrow.clockwise", action: onReconnect)
            .disabled(!presentation.reconnectEnabled)
    }

    private var refreshPill: some View {
        SettingsPillButton(
            title: "Refresh tools", icon: "arrow.triangle.2.circlepath", isLoading: isRefreshing,
            action: onRefresh)
            .disabled(!presentation.refreshEnabled)
    }

    private var removePill: some View {
        SettingsPillButton(title: "Remove server", icon: "trash", isDestructive: true, action: onDelete)
            .help("Removing takes its approvals and its stored token with it.")
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Typography.caption)
            .foregroundStyle(Colors.textTertiary)
    }
}
