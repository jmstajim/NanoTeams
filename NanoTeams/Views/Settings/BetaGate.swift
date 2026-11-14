import SwiftUI

/// The two settings tabs that reach OUTSIDE this app — `External Agents`, which hosts a server
/// other programs connect to, and `MCP Servers`, which connects this app's roles to servers
/// somebody else runs — stand behind a screen that says so before the person can use them: what the
/// feature does, what it cannot promise, and a plain-language disclaimer. One button acknowledges
/// it, and the acknowledgement is remembered per feature (`StoreConfiguration.acknowledgedBetaFeatures`).
///
/// A gate PER FEATURE rather than one for the app: the two carry different risks and the person
/// is accepting different things. Acknowledging the inbound server says nothing about the
/// third-party servers they may later connect.
///
/// The copy is pure and lives here, so the wording is testable and the view draws only what it is
/// handed — the same split as `ExternalAgentsSettingsPresentation`.
nonisolated enum BetaFeature: String, CaseIterable, Sendable {
    /// Stored in `acknowledgedBetaFeatures` under the tab's pre-2026-11-08 name: a new
    /// spelling would put the gate back up in front of everyone who has already accepted it.
    case externalAgents = "agentAccess"
    case mcpServers = "mcpServers"
}

nonisolated struct BetaGateCopy: Equatable, Sendable {
    let title: String
    let icon: String
    /// What the feature actually does, in the person's terms — the thing they are about to turn
    /// on, not a feature list.
    let whatItDoes: String
    /// What can go wrong, named specifically. Generic "use at your own risk" tells a person
    /// nothing they can act on; these are the facts that decide whether they should proceed.
    let risks: [String]
    let buttonTitle: String

    /// The same for both, because it is about the software rather than the feature. Plain
    /// language on purpose: a person who cannot read it has not been warned by it.
    static let disclaimer =
        "This feature is in beta. It is provided as is, without warranty of any kind, and it may "
        + "change or stop working in any release. You are responsible for what you connect it to "
        + "and for what runs because of it. To the fullest extent permitted by law, the authors "
        + "accept no liability for any loss or damage arising from its use, including lost, "
        + "corrupted or disclosed data."

    static func copy(for feature: BetaFeature) -> BetaGateCopy {
        switch feature {
        case .externalAgents:
            BetaGateCopy(
                title: "External Agents",
                icon: HostedMCPConstants.symbolName,
                whatItDoes:
                    "NanoTeams hosts a server on this Mac so an outside coding agent can create "
                    + "tasks in the open work folder, run them, answer their questions and close "
                    + "them. The server listens on this machine only.",
                risks: [
                    "An agent you give a token to acts in this work folder with your own rights, and the tasks it starts run local models that read and write files there and can run commands.",
                    "Anything already running on this Mac as you can reach a loopback port. The token is what keeps web pages and other apps out — it is not a defence against programs you have already allowed to run.",
                    "If you allow an agent, it can also replace the folder's Work Folder Context. Roles of your own tasks read it too, on every team whose prompt includes it, and NanoTeams keeps no earlier version of it to restore.",
                    "A token is a secret. Anyone who obtains one can do everything above until you revoke it.",
                ],
                buttonTitle: "I understand and accept")
        case .mcpServers:
            BetaGateCopy(
                title: "MCP Servers",
                icon: "server.rack",
                whatItDoes:
                    "Connects your roles to tools, resources and prompts that run on servers you "
                    + "configure — this app's own, or someone else's.",
                risks: [
                    "A server is software another party controls. Its tool descriptions reach the model, and a call does whatever that server does, with whatever credentials and access you gave it.",
                    "NanoTeams pins every tool, resource and prompt by hash and approves each call outside the calling model, which narrows this considerably — but it cannot make an untrustworthy server safe.",
                    "What you send to a server leaves this Mac. Treat anything a task may pass to it as disclosed to whoever runs it.",
                ],
                buttonTitle: "I understand and accept")
        }
    }
}

/// Draws the gate, or the tab behind it once the person has acknowledged this feature. Both tabs
/// wrap their whole body in this, so there is no path to the content that skips it.
struct BetaGate<Content: View>: View {
    let feature: BetaFeature
    @ViewBuilder let content: () -> Content

    @Environment(StoreConfiguration.self) private var configuration

    var body: some View {
        if configuration.hasAcknowledgedBeta(feature) {
            content()
        } else {
            BetaGateScreen(
                copy: BetaGateCopy.copy(for: feature),
                onAccept: { configuration.acknowledgeBeta(feature) })
        }
    }
}

/// The screen itself — no store, so every state renders from a `#Preview`.
struct BetaGateScreen: View {
    let copy: BetaGateCopy
    let onAccept: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                header
                Text(copy.whatItDoes)
                    .font(Typography.termBase)
                    .foregroundStyle(Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: Spacing.s) {
                    MonoLabel(text: "Before you start", marker: true)
                    ForEach(copy.risks, id: \.self) { risk in
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                            StatusGlyph(
                                glyph: TerminalGlyph.bullet,
                                color: Colors.warning,
                                font: Typography.term2xs)
                            Text(risk)
                                .font(Typography.caption)
                                .foregroundStyle(Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Text(BetaGateCopy.disclaimer)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Spacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle.squircle(CornerRadius.small).fill(Colors.surfaceOverlay))

                Button(action: onAccept) {
                    Text(copy.buttonTitle)
                        .font(Typography.subheadlineMedium)
                        .foregroundStyle(Colors.textOnAccent)
                        .padding(.horizontal, Spacing.standard)
                        .padding(.vertical, Spacing.s)
                        .background(
                            RoundedRectangle.squircle(CornerRadius.small).fill(Colors.accent))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .help("\(copy.buttonTitle) (⌘↩)")
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.xl)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NTMSBackground())
    }

    private var header: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: copy.icon)
                .font(Typography.term2xl)
                .foregroundStyle(Colors.accent)
            Text(copy.title)
                .font(Typography.termXl)
                .foregroundStyle(Colors.textPrimary)
            // A micro tag, and 10px type never wraps (`MicroTypeNeverWrapsPinTests`).
            Text("BETA")
                .font(Typography.term2xs)
                .lineLimit(1)
                .foregroundStyle(Colors.warning)
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, Spacing.xxs)
                .background(
                    RoundedRectangle.squircle(CornerRadius.small).fill(Colors.warningTint))
        }
    }
}
