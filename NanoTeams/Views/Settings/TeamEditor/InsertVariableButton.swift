import SwiftUI

// MARK: - Insert Variable Button

/// A button that shows a menu of available placeholder variables to insert.
struct InsertVariableButton: View {
    let placeholders: [(key: String, label: String, category: String)]
    let onInsert: (String) -> Void

    var body: some View {
        Menu {
            ForEach(groupedCategories, id: \.category) { group in
                Section(group.category.capitalized) {
                    ForEach(group.items, id: \.key) { item in
                        Button(item.label) {
                            onInsert("{\(item.key)}")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "plus")
                    .font(Typography.caption)
                Text("Insert Variable")
                    .font(Typography.caption)
                Image(systemName: "chevron.down")
                    .font(Typography.term2xs)
                    .foregroundStyle(Colors.textTertiary)
            }
            .foregroundStyle(Colors.textPrimary)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xxs)
            .background(
                RoundedRectangle.squircle(CornerRadius.small)
                    .fill(Colors.surfaceElevated)
            )
            .overlay(
                RoundedRectangle.squircle(CornerRadius.small)
                    .strokeBorder(Colors.borderSubtle, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var groupedCategories: [(category: String, items: [(key: String, label: String, category: String)])] {
        var groups: [String: [(key: String, label: String, category: String)]] = [:]
        for p in placeholders {
            groups[p.category, default: []].append(p)
        }
        let order = ["role", "context", "tools", "artifacts"]
        return order.compactMap { cat in
            guard let items = groups[cat] else { return nil }
            return (category: cat, items: items)
        }
    }
}

#Preview {
    InsertVariableButton(
        placeholders: [
            (key: "roleName", label: "Role Name", category: "role"),
            (key: "roleGuidance", label: "Role Guidance", category: "role"),
            (key: "teamRoles", label: "Team Roles", category: "context"),
            (key: "toolList", label: "Tool List", category: "tools"),
            (key: "expectedArtifacts", label: "Expected Artifacts", category: "artifacts"),
        ],
        onInsert: { _ in }
    )
    .padding()
    .background(Colors.surfacePrimary)
}
