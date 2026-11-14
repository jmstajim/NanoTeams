import SwiftUI

/// The header row of an activity list: what the list shows (a filter menu) on the left, and the
/// control that hides everything shown so far on the right.
///
/// One component for the Watchtower's Recent Activity and the External Autovisor pane's log, so
/// the two lists read and behave alike (Alex, 2026-11-08: «сделай чтобы активити можно было
/// очистить, синхронизируй с главным экраном»). Hiding deletes nothing: the caller moves the one
/// cutoff both lists read, `StoreConfiguration.timelineClearedUpToDate`, and every row at or
/// before it stops being shown — on both screens at once.
struct ActivityFilterBar: View {
    struct Option: Identifiable, Hashable {
        let id: Int
        let title: String
    }

    static let allLabel = "All tasks & chats"

    let options: [Option]
    let selection: Int?
    let onSelect: @MainActor (Int?) -> Void
    let isHideDisabled: Bool
    let onHide: @MainActor () -> Void

    var body: some View {
        HStack {
            Menu {
                Button(Self.allLabel) {
                    onSelect(nil)
                }

                if !options.isEmpty {
                    Divider()
                    ForEach(options) { option in
                        Button(option.title) {
                            onSelect(option.id)
                        }
                    }
                }
            } label: {
                HStack(spacing: Spacing.s) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(Colors.textSecondary)

                    Text(Self.label(for: selection, in: options))
                        .font(Typography.termBase)
                        .foregroundStyle(Colors.textPrimary)

                    Image(systemName: "chevron.down")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textTertiary)
                }
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, Spacing.s)
                .background(
                    RoundedRectangle.squircle(CornerRadius.small)
                        .fill(Colors.surfaceCard)
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)

            Spacer()

            HideActivityButton(isDisabled: isHideDisabled, action: onHide)
        }
    }

    /// The menu's title: the selected option's, or the "all" label when nothing is selected or
    /// the selection is no longer offered (its task was deleted).
    static func label(for selection: Int?, in options: [Option]) -> String {
        guard let selection, let option = options.first(where: { $0.id == selection }) else {
            return allLabel
        }
        return option.title
    }
}

// MARK: - Hide button

/// Hides the rows shown so far without deleting them.
private struct HideActivityButton: View {
    let isDisabled: Bool
    let action: @MainActor () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "eye.slash")
                .font(Typography.caption)
                .foregroundStyle(isHovered ? Colors.textPrimary : Colors.textSecondary)
        }
        .buttonStyle(.plain)
        .help("Hide timeline events")
        .accessibilityLabel("Hide timeline events")
        .disabled(isDisabled)
        .trackHover($isHovered)
    }
}
