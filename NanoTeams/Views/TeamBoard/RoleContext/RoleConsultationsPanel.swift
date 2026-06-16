import SwiftUI

/// Expandable disclosure panel listing teammate consultations for the selected role.
struct RoleConsultationsPanel: View {
    let consultations: [TeammateConsultation]
    @Binding var isExpanded: Bool

    var body: some View {
        RoleContextDisclosureSection(
            title: "Consultations",
            count: consultations.count,
            icon: "bubble.left.and.bubble.right.fill",
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
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .foregroundStyle(Colors.info)
                    .font(.caption)
                Text("Asked \(consultation.consultedRole.displayName)")
                    .font(Typography.caption.bold())
                Spacer()
                Image(systemName: consultation.status.icon)
                    .foregroundStyle(Self.iconTint(for: consultation.status))
                    .font(.caption)
            }
            Text(consultation.question)
                .font(Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let response = consultation.response {
                Text(response)
                    .font(Typography.caption)
                    .lineLimit(3)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.micro, style: .continuous)
                            .fill(Self.responseTint(for: consultation.status))
                    )
            }
        }
        .padding(Spacing.s)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
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
}
