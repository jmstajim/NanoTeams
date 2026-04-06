import SwiftUI

// MARK: - Design System Components

// MARK: - Background

/// App background fill
struct NTMSBackground: View {
    var body: some View {
        Colors.surfacePrimary
            .ignoresSafeArea()
    }
}

// MARK: - Section Header

/// Section header with optional action button
struct NTMSSectionHeader: View {
    let title: String
    var systemImage: String?
    var action: (() -> Void)?
    var actionLabel: String?

    var body: some View {
        HStack {
            HStack(spacing: Spacing.s) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityAddTraits(.isHeader)

            Spacer()

            if let action, let actionLabel {
                Button(action: action) {
                    Text(actionLabel)
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Colors.accent)
            }
        }
        .padding(.bottom, Spacing.xs)
    }
}

// MARK: - Empty State

/// Empty state with actionable guidance
struct NTMSEmptyState: View {
    let title: String
    let message: String
    let systemImage: String
    var action: (() -> Void)?
    var actionLabel: String?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if let action, let actionLabel {
                Button(actionLabel, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
        }
    }
}

// MARK: - Bordered Text Editor

/// A view modifier that applies standard bordered styling to TextEditor.
/// Eliminates the duplicated background + overlay pattern used across sheets.
struct BorderedTextEditorStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .padding(Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                    .fill(Colors.surfacePrimary)
            )
    }
}

// MARK: - Info Tip

/// ⓘ button that shows a help popover with explanatory text.
struct InfoTip: View {
    let text: String
    @State private var isPresented = false

    init(_ text: String) { self.text = text }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented) {
            Text(text)
                .font(.callout)
                .frame(width: 240)
                .padding(Spacing.m)
        }
    }
}

// MARK: - Previews

#Preview("Section Headers") {
    VStack(alignment: .leading, spacing: 20) {
        NTMSSectionHeader(title: "Team Members")
        NTMSSectionHeader(title: "Artifacts", systemImage: "doc.text.fill")
        NTMSSectionHeader(
            title: "Tool Configuration",
            systemImage: "wrench.fill",
            action: {},
            actionLabel: "Edit"
        )
    }
    .padding()
    .frame(width: 400)
    .background(Colors.surfacePrimary)
}

#Preview("Empty State") {
    VStack(spacing: 24) {
        NTMSEmptyState(
            title: "No Tasks",
            message: "Create a task to get started with your team.",
            systemImage: "tray",
            action: {},
            actionLabel: "New Task"
        )
        .frame(height: 200)

        Divider()

        NTMSEmptyState(
            title: "No Results",
            message: "Try adjusting your search criteria.",
            systemImage: "magnifyingglass"
        )
        .frame(height: 160)
    }
    .frame(width: 400)
    .background(Colors.surfacePrimary)
}

#Preview("Sheet Header") {
    VStack(spacing: 20) {
        SheetHeader(
            title: "Restart Role",
            subtitle: "Software Engineer will re-execute from scratch",
            systemImage: "arrow.counterclockwise",
            tintColor: Colors.warning
        )
        SheetHeader(
            title: "New Task",
            subtitle: "Create a task for the team to execute",
            systemImage: "plus.circle.fill",
            tintColor: Colors.success
        )
    }
    .padding()
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}

#Preview("Bordered Text Editor") {
    @Previewable @State var text = "You are a software engineer focused on clean, testable code..."
    TextEditor(text: $text)
        .frame(height: 120)
        .borderedTextEditorStyle()
        .padding()
        .frame(width: 400)
        .background(Colors.surfacePrimary)
}

extension View {
    /// Apply standard bordered styling to a TextEditor
    func borderedTextEditorStyle() -> some View {
        modifier(BorderedTextEditorStyle())
    }

    /// Card style: surfaceCard fill, radiusMedium corners, no border.
    /// Used by settings views (WorkFolder, LLM, General) for consistent card appearance.
    func cardStyle() -> some View {
        self
            .padding(Spacing.standard)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle.squircle(CornerRadius.medium).fill(Colors.surfaceCard))
    }
}

// MARK: - Settings Card

/// Reusable settings card with section header, card-styled content, and optional footer.
/// Pattern: NTMSSectionHeader above → content in cardStyle() → caption footer below.
struct SettingsCard<Content: View>: View {
    let header: String
    var systemImage: String?
    var footer: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            NTMSSectionHeader(title: header, systemImage: systemImage)

            VStack(alignment: .leading, spacing: Spacing.m) {
                content()
            }
            .cardStyle()

            if let footer {
                Text(footer)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
                    .padding(.horizontal, Spacing.xs)
            }
        }
    }
}

// MARK: - Settings Pill Button

/// Capsule-shaped action button for settings views.
/// Replaces duplicated pill button patterns across settings views.
struct SettingsPillButton: View {
    let title: String
    let icon: String
    var isLoading: Bool = false
    var isDestructive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: icon)
                Text(title)
                if isLoading { NTMSLoader(.small) }
            }
            .font(Typography.captionSemibold)
            .foregroundStyle(isDestructive ? Colors.error : .secondary)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.xs)
            .background(Capsule(style: .continuous).fill(Colors.surfaceElevated))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings Item Header

/// Icon-in-rounded-rect + title + subtitle header row for settings cards.
/// Used in server card (LLMSettingsView) and folder header (WorkFolderSettingsView).
struct SettingsItemHeader: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: Spacing.m) {
            RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                .fill(Colors.surfaceElevated)
                .frame(
                    width: SettingsLayout.cardIconSize,
                    height: SettingsLayout.cardIconSize
                )
                .overlay(
                    Image(systemName: icon)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                )

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(Typography.subheadlineSemibold)
                Text(subtitle)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Sheet Header

/// Standardized sheet header with icon, title, and subtitle.
/// Eliminates the duplicated icon-in-rounded-rect + title + subtitle pattern.
struct SheetHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var tintColor: Color = Colors.warning

    var body: some View {
        HStack(spacing: Spacing.m) {
            ZStack {
                RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                    .fill(tintColor.opacity(DynamicTintOpacity.background))
                    .frame(width: SheetLayout.headerIconSize, height: SheetLayout.headerIconSize)
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(tintColor)
            }
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

