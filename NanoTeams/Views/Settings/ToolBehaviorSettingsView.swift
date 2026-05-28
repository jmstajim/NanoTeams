import SwiftUI

// MARK: - Tool Behavior Settings View

struct ToolBehaviorSettingsView: View {
    @Environment(StoreConfiguration.self) var config

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                readFileCard
                searchCard
            }
            .padding(Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Colors.surfacePrimary)
    }

    // MARK: - read_file Card

    private var readFileCard: some View {
        @Bindable var config = config
        return SettingsCard(
            header: "File reads",
            systemImage: "doc.text"
        ) {
            VStack(spacing: 0) {
                SettingsStepperRow(
                    title: "Line limit",
                    icon: "doc.text",
                    value: $config.readFileMaxLines,
                    range: AppDefaults.readFileMaxLinesMin...AppDefaults.readFileMaxLinesMax,
                    step: 25
                )

                Text("Caps the number of lines a single `read_file` or `read_lines` call can return. `read_file` rejects oversized files with a hint pointing the LLM at `read_lines`; `read_lines` silently truncates oversized ranges (the LLM paginates via `start_line`). Set to 0 (Unlimited) to disable the cap.")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, SettingsLayout.toggleIconSize + Spacing.m)
                    .padding(.bottom, Spacing.s)
            }
        }
    }

    // MARK: - search Card

    private var searchCard: some View {
        @Bindable var config = config
        return SettingsCard(
            header: "`search`",
            systemImage: "magnifyingglass"
        ) {
            VStack(spacing: 0) {
                SettingsStepperRow(
                    title: "Max results",
                    icon: "list.number",
                    value: $config.searchMaxResults,
                    range: AppDefaults.searchMaxResultsMin...AppDefaults.searchMaxResultsMax,
                    step: 5
                )

                Text("Default cap on the number of `search` hits returned when the LLM doesn't pass `max_results`. The LLM can override per-call.")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, SettingsLayout.toggleIconSize + Spacing.m)
                    .padding(.bottom, Spacing.s)

                SettingsStepperRow(
                    title: "Context lines before",
                    icon: "arrow.up.to.line",
                    value: $config.searchContextBefore,
                    range: AppDefaults.searchContextMin...AppDefaults.searchContextMax,
                    step: 1,
                    zeroLabel: nil
                )

                Text("Default number of source lines included before each match when the LLM doesn't pass `context_before`. The LLM can override per-call.")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, SettingsLayout.toggleIconSize + Spacing.m)
                    .padding(.bottom, Spacing.s)

                SettingsStepperRow(
                    title: "Context lines after",
                    icon: "arrow.down.to.line",
                    value: $config.searchContextAfter,
                    range: AppDefaults.searchContextMin...AppDefaults.searchContextMax,
                    step: 1,
                    zeroLabel: nil
                )

                Text("Default number of source lines included after each match when the LLM doesn't pass `context_after`. The LLM can override per-call.")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, SettingsLayout.toggleIconSize + Spacing.m)
                    .padding(.bottom, Spacing.s)
            }
        }
    }
}

// MARK: - Preview

#Preview("Tool Behavior Settings") {
    @Previewable @State var config = StoreConfiguration()
    ToolBehaviorSettingsView()
        .environment(config)
        .frame(width: 500, height: 600)
}
