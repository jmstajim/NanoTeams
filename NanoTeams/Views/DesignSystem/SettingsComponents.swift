import SwiftUI

// MARK: - Settings Design System Components

// MARK: - Settings Master-Detail Layout

/// Standardized master-detail layout for settings views
struct SettingsMasterDetailView<Master: View, Detail: View, EmptyDetail: View>: View {
    let master: Master
    let detail: Detail
    let emptyDetail: EmptyDetail
    let hasSelection: Bool

    init(
        hasSelection: Bool,
        @ViewBuilder master: () -> Master,
        @ViewBuilder detail: () -> Detail,
        @ViewBuilder emptyDetail: () -> EmptyDetail
    ) {
        self.hasSelection = hasSelection
        self.master = master()
        self.detail = detail()
        self.emptyDetail = emptyDetail()
    }

    var body: some View {
        HStack(spacing: 0) {
            master
                .frame(width: SettingsLayout.listWidth)
                .scrollContentBackground(.hidden)
                .background(Colors.surfacePrimary)

            TerminalDivider(axis: .vertical)

            Group {
                if hasSelection {
                    detail
                } else {
                    emptyDetail
                }
            }
            .frame(minWidth: SettingsLayout.detailMinWidth, maxWidth: .infinity)
            .background(Colors.surfacePrimary)
        }
    }
}

// MARK: - Previews

#Preview("Search Field") {
    @Previewable @State var text = ""
    @Previewable @State var filledText = "sorting algorithm"
    VStack(spacing: 16) {
        SearchFieldView(placeholder: "Filter roles...", text: $text)
        SearchFieldView(placeholder: "Search tools...", text: $filledText)
    }
    .padding()
    .frame(width: 300)
    .background(Colors.surfacePrimary)
}

#Preview("Settings Empty State") {
    SettingsEmptyState(
        title: "No Team Selected",
        systemImage: "person.3",
        description: "Select a team from the list to view its configuration.",
        actionTitle: "Create Team",
        action: {}
    )
    .frame(width: 400, height: 300)
    .background(Colors.surfacePrimary)
}

#Preview("Master-Detail Layout") {
    SettingsMasterDetailView(
        hasSelection: true,
        master: {
            List {
                Text("FAANG Team").font(Typography.subheadline)
                Text("Startup Team").font(Typography.subheadline)
                Text("Quest Party").font(Typography.subheadline)
            }
            .listStyle(.sidebar)
        },
        detail: {
            VStack {
                Text("Team Configuration")
                    .font(Typography.termLg)
                Text("8 members, 7 artifacts")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        },
        emptyDetail: {
            Text("Select a team")
                .foregroundStyle(Colors.textSecondary)
        }
    )
    .frame(width: 700, height: 300)
}

// MARK: - Settings Empty State

/// Empty state for settings.
/// Thin wrapper over `NTMSEmptyState` so the title + description stay mono;
/// the action button styling is identical (accent capsule → `.terminalPrimary`).
struct SettingsEmptyState: View {
    let title: String
    let systemImage: String
    let description: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        NTMSEmptyState(
            title: title,
            message: description,
            systemImage: systemImage,
            action: action,
            actionLabel: actionTitle
        )
    }
}

// MARK: - Search Field

/// Pure SwiftUI search/filter field with magnifying glass icon and clear button.
/// Used in RoleListView, ArtifactListView, ToolSelectionView.
///
/// Draws the standard input chrome like every other field. It used to fill `surfacePrimary` with
/// NO border — and all three hosts are `surfacePrimary` panes, so the field had no separation from
/// its background at all. Routing it through `InputSurface` is what gives it the hairline; the
/// radius moves 3 → 2 with the rest of the tree. "Search field" is not a different kind of input.
struct SearchFieldView: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: (() -> Void)? = nil

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Typography.termBase)
            .onSubmit { onSubmit?() }
            .inputSurface(.field) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Colors.textSecondary)
                    .font(Typography.termBase)
                    .accessibilityHidden(true)
            } trailing: {
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle")
                            .foregroundStyle(Colors.textSecondary)
                            .font(Typography.termBase)
                    }
                    .buttonStyle(.plain)
                }
            }
    }
}

