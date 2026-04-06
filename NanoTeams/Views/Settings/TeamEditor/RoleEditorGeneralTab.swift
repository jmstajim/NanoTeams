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
        Form {
            Section("Identity") {
                HStack(spacing: Spacing.m) {
                    IconPickerButton(
                        selectedIcon: $editorState.roleIcon,
                        iconForeground: resolvedIconForeground,
                        iconBackground: resolvedIconBackground
                    )

                    TextField("Role Name", text: $editorState.roleName)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                }

                ColorPaletteRow(selectedHex: $editorState.roleIconColor, label: "Icon Color")
                ColorPaletteRow(selectedHex: $editorState.roleIconBackground, label: "Background")
            }

            if !isEditingSupervisor {
                Section("Execution") {
                    Toggle("Use Planning Phase", isOn: $editorState.usePlanningPhase)

                    Text("When enabled, the LLM first creates a plan, then executes it. Recommended for complex roles.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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
                .font(.subheadline)
                .foregroundStyle(.secondary)
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
            Circle()
                .fill(fillColor)
                .frame(width: 20, height: 20)
                .overlay {
                    if isWhite {
                        Circle().strokeBorder(Colors.borderSubtle, lineWidth: 1)
                    }
                }
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(isLight ? Color.black : Color.white)
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
