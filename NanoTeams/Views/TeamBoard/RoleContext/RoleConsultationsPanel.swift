import SwiftUI

/// Expandable disclosure panel listing teammate consultations for the selected role.
struct RoleConsultationsPanel: View {
    let consultations: [TeammateConsultation]
    @Binding var isExpanded: Bool

    var body: some View {
        RoleContextDisclosureSection(
            title: "Consultations",
            count: consultations.count,
            icon: "bubble.left.and.bubble.right",
            color: Colors.info,
            isExpanded: $isExpanded
        ) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(consultations) { consultation in
                    consultationCard(consultation)
                }
            }
            .padding(.horizontal, Spacing.standard)
            .padding(.bottom, Spacing.s)
        }
    }

    private func consultationCard(_ consultation: TeammateConsultation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "bubble.left.and.bubble.right")
                    .foregroundStyle(Colors.info)
                    .font(Typography.caption)
                Text("Asked \(consultation.consultedRole.displayName)")
                    .font(Typography.caption.bold())
                Spacer()
                StatusGlyph(
                    glyph: Self.statusGlyph(for: consultation.status),
                    color: Self.iconTint(for: consultation.status),
                    font: Typography.termSm
                )
            }
            Text(consultation.question)
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)
                .lineLimit(2)
            if let response = consultation.response {
                Text(response)
                    .font(Typography.caption)
                    .lineLimit(3)
                    .padding(6)
                    .background(
                        RoundedRectangle.squircle(CornerRadius.micro)
                            .fill(Self.responseTint(for: consultation.status))
                    )
            }
        }
        .padding(Spacing.s)
        .background(
            RoundedRectangle.squircle(CornerRadius.small)
                .fill(Colors.surfaceCard)
        )
    }

    /// Tint for the answer body keyed on outcome: green for a completed answer,
    /// red for a failed/empty consultation (whose `response` carries the reason),
    /// neutral otherwise. Static + pure so it's unit-testable without a view.
    static func responseTint(for status: ConsultationStatus) -> Color {
        switch status {
        case .completed: return Colors.successTint
        case .failed: return Colors.errorTint
        default: return Colors.neutralTint
        }
    }

    /// Status-glyph foreground, symmetric with `responseTint` so a failed
    /// consultation's icon reads red — not warning-orange over a red body.
    /// Static + pure for unit testing.
    static func iconTint(for status: ConsultationStatus) -> Color {
        switch status {
        case .completed: return Colors.success
        case .failed: return Colors.error
        default: return Colors.warning
        }
    }

    /// Terminal status glyph symmetric with `iconTint` — replaces the
    /// SF-Symbol status icon with the Monochrome+1 terminal vocabulary.
    static func statusGlyph(for status: ConsultationStatus) -> String {
        switch status {
        case .completed: return TerminalGlyph.done
        case .failed: return TerminalGlyph.failed
        default: return TerminalGlyph.working
        }
    }
}
