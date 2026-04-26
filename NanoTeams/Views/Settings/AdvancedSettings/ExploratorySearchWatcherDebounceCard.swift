import SwiftUI

/// Settings card for the FSEvents debounce window used by the exploratory-search
/// file watcher. Read once at coordinator construction (folder open / toggle
/// flip) — live edits don't retune the active watcher; the user has to close
/// and reopen the folder for the new value to take effect.
struct ExploratorySearchWatcherDebounceCard: View {
    @Bindable var config: StoreConfiguration

    var body: some View {
        let intBinding = Binding<Int>(
            get: { Int(config.searchIndexWatcherDebounceSeconds.rounded()) },
            set: { config.searchIndexWatcherDebounceSeconds = TimeInterval($0) }
        )
        let lower = Int(AppDefaults.searchIndexWatcherDebounceSecondsMin.rounded(.up))
        let upper = Int(AppDefaults.searchIndexWatcherDebounceSecondsMax.rounded(.down))
        SettingsCard(
            header: "Update Delay",
            systemImage: "clock"
        ) {
            VStack(spacing: 0) {
                SettingsStepperRow(
                    title: "Update delay (seconds)",
                    icon: "clock",
                    value: intBinding,
                    range: lower...upper,
                    step: 1,
                    zeroLabel: nil
                )
                Text("How long the watcher waits after a file change before rebuilding the index. Applied on next folder open.")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, SettingsLayout.toggleIconSize + Spacing.m)
                    .padding(.bottom, Spacing.s)
            }
        }
    }
}
