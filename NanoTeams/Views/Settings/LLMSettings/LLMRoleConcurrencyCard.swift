import SwiftUI

/// How hard the app is allowed to lean on the server it just configured.
///
/// Sits between the model card and the downloaded-models card so the LLM tab reads as one
/// sentence: which server → which model → **how we load it** → what it has on disk → what
/// happens when a call fails.
///
/// A menu rather than a segmented control: the two labels differ in length by a factor of
/// five, and equal-width segments would either truncate one or waste the row on the other.
struct LLMRoleConcurrencyCard: View {
    @Bindable var config: StoreConfiguration

    var body: some View {
        SettingsCard(
            header: "Parallel Roles",
            systemImage: "square.stack.3d.up",
            footer: Self.footer
        ) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack {
                    Text("Roles running at once (per task)")
                        .font(Typography.subheadline)
                    Spacer()
                    TerminalPicker(
                        selection: $config.roleConcurrencyMode,
                        options: RoleConcurrencyMode.allCases.map { ($0, $0.displayName) }
                    )
                    .frame(maxWidth: 260)
                }

                Text(config.roleConcurrencyMode.explanation)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
            }
        }
    }

    /// Everything the limit does NOT cover. A one-line label that says "one at a time"
    /// promises an absolute, and every clause below is a way that promise is not kept — so
    /// they ship with the control instead of being discovered during a run.
    private static let footer = """
    Per task — a delegated team gets its own allowance. \
    "As many as the provider allows" = no limit: neither server reports its capacity. \
    Consultations and meetings run inside a role's slot; vision, judges, team generation \
    and compaction aren't limited at all. Takes effect on the next role to start.
    """
}

#Preview("Parallel Roles") {
    ScrollView {
        LLMRoleConcurrencyCard(config: StoreConfiguration())
            .padding()
    }
    .background(Colors.surfacePrimary)
}
