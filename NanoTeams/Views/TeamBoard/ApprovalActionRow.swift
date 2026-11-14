import SwiftUI

/// A standing grant a card offers: its button's label, and — when the label alone does not say
/// what it grants — the tooltip that does. A value, so a card's choice of grant is a test's to
/// read (`MCPApprovalCardText.grant(offerAlways:)`) without hosting the card.
nonisolated struct ApprovalGrant: Hashable, Sendable {
    let label: String
    var help: String?

    init(label: String, help: String? = nil) {
        self.label = label
        self.help = help
    }
}

/// The decision row of an approval card — Allow, Deny and, where it is offered, a standing grant —
/// with an optional accessory after them (the `bash` card's "Ask AI"). ONE row for the three cards
/// the feed draws — `bash`, computer use, MCP — in the chat column, which can be 200 points wide.
///
/// **No label ever breaks.** Each arrangement is tried at the buttons' own sizes, widest first
/// (`ViewThatFits`): all on one row; Allow and Deny on one row, the grant below; one button per
/// line. Until 2026-10-28 each card drew one `HStack` with no fallback, and in a narrow
/// column the buttons were squeezed until "[ Allow ]" broke into "Allo / w" and the MCP card's
/// "[ Always allow this tool ]" into four lines. A button wider than the column on a line of its
/// own — a computer-use grant naming an app with a long name — is cut short (one line, its
/// whole label in the tooltip) rather than broken.
struct ApprovalActionRow<Accessory: View>: View {

    /// Which decision a button is — and so its style.
    nonisolated enum Kind: Sendable {
        case allow, deny, always
    }

    /// The standing grant, or `nil` when none is offered.
    let grant: ApprovalGrant?
    let onAllow: @MainActor () -> Void
    let onDeny: @MainActor () -> Void
    let onAlways: @MainActor () -> Void
    let accessory: Accessory

    init(
        grant: ApprovalGrant?,
        onAllow: @escaping @MainActor () -> Void,
        onDeny: @escaping @MainActor () -> Void,
        onAlways: @escaping @MainActor () -> Void,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.grant = grant
        self.onAllow = onAllow
        self.onDeny = onDeny
        self.onAlways = onAlways
        self.accessory = accessory()
    }

    static var allowLabel: String { "Allow" }
    static var denyLabel: String { "Deny" }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.xs) {
                allow
                deny
                always
                trailingAccessory
            }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.xs) {
                    allow
                    deny
                    trailingAccessory
                }
                always
            }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.xs) {
                    allow
                    deny
                }
                HStack(spacing: Spacing.xs) {
                    always
                    trailingAccessory
                }
            }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                allow
                deny
                always
                accessory
            }
        }
    }

    /// One decision button, as every arrangement draws it: its label on one line, in the style
    /// its kind takes. Static, so a layout test lays out the very button the row draws.
    static func button(
        _ label: String, kind: Kind, help: String? = nil, action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .lineLimit(1)
        }
        .buttonStyle(style(for: kind))
        .help(tooltip(label: label, help: help))
        .layoutProbe("approval-action:\(label)")
    }

    /// A decision button's tooltip: what it grants, when its label is short for it, else the
    /// label itself — so a label cut short on a narrow line is still readable whole.
    static func tooltip(label: String, help: String?) -> String {
        help ?? label
    }

    private static func style(for kind: Kind) -> TerminalButtonStyle {
        switch kind {
        case .allow: .terminalPrimary
        case .deny: .terminalDanger
        case .always: .terminalGhost
        }
    }

    private var allow: some View {
        Self.button(Self.allowLabel, kind: .allow, action: onAllow)
    }

    private var deny: some View {
        Self.button(Self.denyLabel, kind: .deny, action: onDeny)
    }

    @ViewBuilder
    private var always: some View {
        if let grant {
            Self.button(grant.label, kind: .always, help: grant.help, action: onAlways)
        }
    }

    /// The accessory at the far end of a row, as the `bash` card has always drawn "Ask AI".
    @ViewBuilder
    private var trailingAccessory: some View {
        if Accessory.self != EmptyView.self {
            Spacer(minLength: Spacing.s)
            accessory
        }
    }
}

extension ApprovalActionRow where Accessory == EmptyView {
    /// A row with nothing after its decisions — the computer-use and MCP cards.
    init(
        grant: ApprovalGrant?,
        onAllow: @escaping @MainActor () -> Void,
        onDeny: @escaping @MainActor () -> Void,
        onAlways: @escaping @MainActor () -> Void
    ) {
        self.init(grant: grant, onAllow: onAllow, onDeny: onDeny, onAlways: onAlways) { EmptyView() }
    }
}
