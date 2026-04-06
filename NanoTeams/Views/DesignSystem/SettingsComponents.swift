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

            Divider()

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
                Text("FAANG Team").font(.subheadline)
                Text("Startup Team").font(.subheadline)
                Text("Quest Party").font(.subheadline)
            }
            .listStyle(.sidebar)
        },
        detail: {
            VStack {
                Text("Team Configuration")
                    .font(.headline)
                Text("8 members, 7 artifacts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        },
        emptyDetail: {
            Text("Select a team")
                .foregroundStyle(.secondary)
        }
    )
    .frame(width: 700, height: 300)
}

// MARK: - Settings Empty State

/// Empty state for settings
struct SettingsEmptyState: View {
    let title: String
    let systemImage: String
    let description: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(description)
        } actions: {
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(Typography.captionSemibold)
                        .foregroundStyle(Colors.surfaceBackground)
                        .padding(.horizontal, Spacing.m)
                        .padding(.vertical, Spacing.xs)
                        .background(Capsule(style: .continuous).fill(Colors.accent))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Search Field

/// Pure SwiftUI search/filter field with magnifying glass icon and clear button.
/// Uses `.roundedBorder` text field style for native macOS appearance.
/// Used in RoleListView, ArtifactListView, MainLayoutView.
struct SearchFieldView: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.subheadline)
                .accessibilityHidden(true)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .onSubmit { onSubmit?() }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.s)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                .fill(Colors.surfacePrimary)
        )
    }
}

