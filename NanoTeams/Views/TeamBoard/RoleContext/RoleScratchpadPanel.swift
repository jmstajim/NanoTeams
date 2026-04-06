import SwiftUI

/// Expandable disclosure panel displaying the selected role's scratchpad text.
struct RoleScratchpadPanel: View {
    let content: String
    @Binding var isExpanded: Bool

    var body: some View {
        RoleContextDisclosureSection(
            title: "Scratchpad",
            count: nil,
            icon: "note.text",
            color: Colors.yellow,
            isExpanded: $isExpanded
        ) {
            Text(content)
                .font(Typography.caption)
                .padding(Spacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                        .fill(Colors.yellowTint)
                )
                .padding(.horizontal, Spacing.standard)
                .padding(.bottom, Spacing.s)
        }
    }
}
