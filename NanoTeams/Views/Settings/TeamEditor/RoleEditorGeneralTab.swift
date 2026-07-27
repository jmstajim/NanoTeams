import SwiftUI

// MARK: - General Tab

struct RoleEditorGeneralTab: View {
    @Binding var editorState: RoleEditorState
    let isEditingSupervisor: Bool

    private var resolvedIconForeground: Color {
        Color(hex: editorState.roleIconColor) ?? .white
    }

    private var resolvedIconBackground: Color {
        Color(hex: editorState.roleIconBackground) ?? Colors.accent
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                SettingsCard(header: "Identity", systemImage: "person.text.rectangle") {
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        HStack(spacing: Spacing.m) {
                            IconPickerButton(
                                selectedIcon: $editorState.roleIcon,
                                iconForeground: resolvedIconForeground,
                                iconBackground: resolvedIconBackground
                            )

                            TextField("Role Name", text: $editorState.roleName)
                                .textFieldStyle(.plain)
                                .terminalField()
                        }

                        ColorPaletteRow(selectedHex: $editorState.roleIconBackground, label: "Icon Color")
                    }
                }

                if !isEditingSupervisor {
                    SettingsCard(
                        header: "Execution",
                        systemImage: "play.circle",
                        footer: "When enabled, the role first explores the work folder with "
                            + "read-only tools and records what it found with update_scratchpad. "
                            + "Implementation then starts from those notes. Costs extra turns — "
                            + "worth it for roles that write code."
                    ) {
                        Toggle("Planning phase", isOn: $editorState.usePlanningPhase)
                            .toggleStyle(.terminal)
                    }
                }
            }
            .padding(Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Colors.surfacePrimary)
    }
}

// MARK: - Color Palette Row

/// Compact row of curated color circles for selecting a hex color.
private struct ColorPaletteRow: View {
    @Binding var selectedHex: String
    let label: String
    var body: some View {
        HStack(spacing: Spacing.s) {
            Text(label)
                .font(Typography.subheadline)
                .foregroundStyle(Colors.textSecondary)
                .frame(width: 80, alignment: .leading)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.xs) {
                    ForEach(Colors.pickerPalette, id: \.hex) { item in
                        colorCircle(item: item)
                    }
                }
                .padding(.vertical, Spacing.xxs)
            }
        }
    }

    private func colorCircle(item: (name: String, hex: String)) -> some View {
        let isWhite = item.hex == "#FFFFFF"
        let isLight = Colors.lightPaletteHexColors.contains(item.hex)
        let isSelected = selectedHex == item.hex
        let fillColor = Color(hex: item.hex) ?? Colors.textSecondary

        return Button {
            selectedHex = item.hex
        } label: {
            RoundedRectangle.squircle(CornerRadius.small)
                .fill(fillColor)
                .frame(width: 20, height: 20)
                .overlay {
                    if isWhite {
                        RoundedRectangle.squircle(CornerRadius.small).strokeBorder(Colors.borderSubtle, lineWidth: 1)
                    }
                }
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(Typography.term2xs.weight(.bold))
                            .foregroundStyle(isLight ? Colors.textPrimary : Colors.textOnAccent)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(item.name)
    }
}
// MARK: - Preview

#Preview {
    @Previewable @State var state = RoleEditorState(
        roleName: "Software Engineer",
        roleIcon: "laptopcomputer",
        roleIconColor: "#4FB985",
        roleIconBackground: "#F6F1EB"
    )
    RoleEditorGeneralTab(editorState: $state, isEditingSupervisor: false)
        .frame(width: 500, height: 400)
}
