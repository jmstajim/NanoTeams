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
                        .font(Typography.termXs)
                        .foregroundStyle(Colors.textTertiary)
                }
                // Signature uppercase-mono section label (MonoLabel treatment).
                Text(title.uppercased())
                    .font(Typography.termXs)
                    .fontWeight(.medium)
                    .tracking(Typography.labelTracking)
                    .foregroundStyle(Colors.textSecondary)
            }
            .accessibilityAddTraits(.isHeader)

            Spacer()

            if let action, let actionLabel {
                Button(action: action) {
                    Text(actionLabel)
                        .font(Typography.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Colors.accent)
            }
        }
        .padding(.bottom, Spacing.xs)
    }
}

// MARK: - Empty State

/// Empty state with actionable guidance.
/// Hand-rolled VStack (not `ContentUnavailableView`) so the title + message
/// honor Typography tokens (mono everywhere) instead of falling back to
/// SF Pro inside Apple's opinionated empty-state chrome.
struct NTMSEmptyState: View {
    let title: String
    let message: String
    let systemImage: String
    var action: (() -> Void)?
    var actionLabel: String?

    var body: some View {
        VStack(spacing: Spacing.m) {
            Image(systemName: systemImage)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Colors.textTertiary)
                .accessibilityHidden(true)

            Text(title)
                .font(Typography.termLg)
                .foregroundStyle(Colors.textPrimary)
                .multilineTextAlignment(.center)

            Text(message)
                .font(Typography.termSm)
                .foregroundStyle(Colors.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

            if let action, let actionLabel {
                Button(actionLabel, action: action)
                    .buttonStyle(.terminalPrimary)
                    .padding(.top, Spacing.xs)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Search Empty State

/// Mono variant of `ContentUnavailableView.search(text:)`. Apple's stock
/// search-empty view uses SF Pro at the title/description level, which
/// breaks the "mono everywhere" rule. Drop-in replacement for
/// `ContentUnavailableView.search(text: searchText)` at every
/// no-results-for-query site (RoleListView, ArtifactListView,
/// ToolSelectionView).
struct NTMSSearchEmptyState: View {
    let searchText: String

    var body: some View {
        NTMSEmptyState(
            title: searchText.isEmpty ? "No Results" : "No Results for \"\(searchText)\"",
            message: "Try a different search.",
            systemImage: "magnifyingglass"
        )
    }
}

// MARK: - Bordered Text Editor

/// A view modifier that applies standard bordered styling to TextEditor.
/// Eliminates the duplicated background + overlay pattern used across sheets.
///
/// Pass `minHeight` to reserve initial editor size (the previous
/// `autovisorEditorStyle(minHeight:)` site — consolidated here so the
/// recessed-input look is one primitive across sheets + Autovisor surfaces).
struct BorderedTextEditorStyle: ViewModifier {
    let minHeight: CGFloat?

    init(minHeight: CGFloat? = nil) { self.minHeight = minHeight }

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .frame(minHeight: minHeight)
            .padding(Spacing.xs)
            .background(
                RoundedRectangle.squircle(CornerRadius.small)
                    .fill(Colors.surfacePrimary)
            )
            .overlay(
                RoundedRectangle.squircle(CornerRadius.small)
                    .strokeBorder(Colors.borderSubtle, lineWidth: 1)
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
                .font(Typography.subheadline)
                .foregroundStyle(Colors.textTertiary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented) {
            Text(text)
                .font(Typography.termBase)
                .frame(width: 240)
                .padding(Spacing.m)
        }
    }
}

// MARK: - Previews

#Preview("Section Headers") {
    VStack(alignment: .leading, spacing: 20) {
        NTMSSectionHeader(title: "Team Members")
        NTMSSectionHeader(title: "Artifacts", systemImage: "doc.text")
        NTMSSectionHeader(
            title: "Tool Configuration",
            systemImage: "wrench",
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
            systemImage: "plus.circle",
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
    /// Apply standard bordered styling to a TextEditor.
    /// `minHeight` (optional) reserves initial editor height; the enclosing
    /// `ScrollView` / `.frame(maxHeight:)` handles overflow.
    func borderedTextEditorStyle(minHeight: CGFloat? = nil) -> some View {
        modifier(BorderedTextEditorStyle(minHeight: minHeight))
    }

    /// Card style: surfaceCard fill, near-sharp corners, 1px hairline box border.
    /// The terminal pane look — depth is the border, not a shadow.
    /// Used by settings views (WorkFolder, LLM, General) for consistent card appearance.
    func cardStyle() -> some View {
        self
            .padding(Spacing.standard)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle.squircle(CornerRadius.medium).fill(Colors.surfaceCard))
            .overlay(
                RoundedRectangle.squircle(CornerRadius.medium)
                    .strokeBorder(Colors.borderSubtle, lineWidth: 1)
            )
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
            // Titled box-drawing card — the design's `┤ TITLE ├` cut-in pane.
            TerminalPane(title: header, contentPadding: Spacing.standard) {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    content()
                }
            }

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
                // `.inline` matches the system-icon footprint (14×14) so the
                // loader visually replaces the leading icon — button keeps
                // its resting size and reads as one symbol + label.
                if isLoading {
                    NTMSLoader(.inline)
                } else {
                    Image(systemName: icon)
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(Typography.captionSemibold)
            .foregroundStyle(isDestructive ? Colors.error : .secondary)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.xs)
            .background(
                RoundedRectangle.squircle(CornerRadius.small)
                    .fill(Colors.surfaceElevated)
                    .overlay(
                        RoundedRectangle.squircle(CornerRadius.small)
                            .strokeBorder(Colors.borderSubtle, lineWidth: 1)
                    )
            )
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings Stepper Control

/// Right-aligned numeric value cell + native `Stepper`. The shared atom used by
/// every settings stepper row. Renders `0` as the literal string `"Unlimited"` so
/// settings that treat zero as a sentinel get consistent presentation. The value
/// cell width comes from `SettingsLayout.stepperValueMinWidth` so callers can't
/// drift apart on column alignment.
struct SettingsStepperControl: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    /// Label shown when `value == 0`. Defaults to `"Unlimited"` for limit-style
    /// settings (e.g. `read_file` line cap) where zero means "no cap". Pass
    /// `nil` for count-style settings where zero is just zero.
    var zeroLabel: String? = "Unlimited"

    var body: some View {
        HStack(spacing: 4) {
            Text(displayValue)
                .monospacedDigit()
                .foregroundStyle(Colors.textSecondary)
                .frame(minWidth: SettingsLayout.stepperValueMinWidth, alignment: .trailing)
                .accessibilityHidden(true) // value is spoken by the adjustable stepper below
            TerminalStepperButtons(value: $value, range: range, step: step, valueText: displayValue)
        }
    }

    private var displayValue: String {
        if value == 0, let zeroLabel { return zeroLabel }
        return "\(value)"
    }
}

// MARK: - Settings Stepper Row

/// Icon-in-rounded-rect + title + `SettingsStepperControl`, with the same hover
/// shell as `SettingsToggleRow`. Use this in cards that mix toggle and stepper
/// settings so they share visual treatment. For LLM-style cards (no leading icon,
/// caption supported), use `LLMStepperSettingsRow` instead.
struct SettingsStepperRow: View {
    let title: String
    let icon: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    /// Forwarded to `SettingsStepperControl`. Defaults to `"Unlimited"` for
    /// limit-style settings; pass `nil` when zero is a real count.
    var zeroLabel: String? = "Unlimited"
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Spacing.m) {
            RoundedRectangle.squircle(CornerRadius.small)
                .fill(Colors.surfaceElevated)
                .frame(width: SettingsLayout.toggleIconSize, height: SettingsLayout.toggleIconSize)
                .overlay(
                    Image(systemName: icon)
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textSecondary)
                )
            Text(title)
                .font(Typography.subheadline)
            Spacer()
            SettingsStepperControl(value: $value, range: range, step: step, zeroLabel: zeroLabel)
        }
        .padding(.vertical, Spacing.xs)
        .padding(.horizontal, Spacing.s)
        .background(
            RoundedRectangle.squircle(CornerRadius.small)
                .fill(isHovered ? Colors.surfaceHover : .clear)
        )
        .trackHover($isHovered)
        .animation(Animations.quick, value: isHovered)
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
            RoundedRectangle.squircle(CornerRadius.small)
                .fill(Colors.surfaceElevated)
                .frame(
                    width: SettingsLayout.cardIconSize,
                    height: SettingsLayout.cardIconSize
                )
                .overlay(
                    Image(systemName: icon)
                        .font(Typography.subheadline)
                        .foregroundStyle(Colors.textSecondary)
                )

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                // Mono title — mixed-case + primary. This header carries dynamic
                // content for some callers (e.g. the work-folder name), so it must
                // not uppercase/dim or that content becomes an illegible all-caps slug.
                Text(title)
                    .font(Typography.termSm)
                    .fontWeight(.medium)
                    .foregroundStyle(Colors.textPrimary)
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
                RoundedRectangle.squircle(CornerRadius.medium)
                    .fill(tintColor.opacity(DynamicTintOpacity.background))
                    .frame(width: SheetLayout.headerIconSize, height: SheetLayout.headerIconSize)
                Image(systemName: systemImage)
                    .font(Typography.termXl)
                    .foregroundStyle(tintColor)
            }
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(Typography.termLg)
                    .foregroundStyle(Colors.textPrimary)
                Text(subtitle)
                    .font(Typography.subheadline)
                    .foregroundStyle(Colors.textSecondary)
            }
        }
    }
}

