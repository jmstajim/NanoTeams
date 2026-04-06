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
                    .foregroundStyle(consultation.status == .completed ? Colors.success : Colors.warning)
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
                            .fill(Colors.successTint)
                    )
            }
        }
        .padding(Spacing.s)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                .fill(Colors.surfaceCard)
        )
    }
}
