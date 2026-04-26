import Speech
import SwiftUI

/// Dictation settings — pick which on-device languages to use for voice
/// dictation, download missing models.
///
/// Philosophy: the runtime dictation path never downloads anything on its
/// own. Downloads happen here, on explicit user action. At runtime, the
/// service intersects the user's selection with currently-installed models.
struct DictationSettingsView: View {

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                if #available(macOS 26, iOS 26, visionOS 26, *) {
                    modernContent
                } else {
                    unsupportedCard
                }
            }
            .padding(Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Colors.surfacePrimary)
    }

    // MARK: - Content

    @available(macOS 26, iOS 26, visionOS 26, *)
    @ViewBuilder
    private var modernContent: some View {
        privacyCard
        DictationLanguagesCard()
    }

    private var privacyCard: some View {
        SettingsCard(
            header: "Privacy",
            systemImage: "lock.shield",
            footer: "All dictation runs entirely on your Mac using Apple's on-device speech recognition. No audio or transcripts leave your device."
        ) {
            SettingsItemHeader(
                icon: "checkmark.shield.fill",
                title: "On-device only",
                subtitle: "No Speech Recognition permission dialog and no network access."
            )
        }
    }

    private var unsupportedCard: some View {
        SettingsCard(
            header: "Not available",
            systemImage: "exclamationmark.triangle",
            footer: "Dictation uses Apple's SpeechAnalyzer framework, which ships on macOS 26 and later."
        ) {
            SettingsItemHeader(
                icon: "mic.slash",
                title: "Requires macOS 26 or later",
                subtitle: "Update your operating system to enable dictation."
            )
        }
    }
}

// MARK: - Languages Card

@available(macOS 26, iOS 26, visionOS 26, *)
private struct DictationLanguagesCard: View {

    @Environment(StoreConfiguration.self) private var config
    @State private var models: [DictationModelCatalog.ModelInfo] = []
    @State private var isLoading = true
    @State private var installing: Set<String> = []
    @State private var installTasks: [String: Task<Void, Never>] = [:]
    @State private var removing: Set<String> = []
    @State private var pendingRemoval: DictationModelCatalog.ModelInfo?
    @State private var lastErrorMessage: String?

    var body: some View {
        SettingsCard(
            header: "Languages",
            systemImage: "globe",
            footer: "Pick which languages can be recognized. Uninstalled models must be downloaded once before they can be used. The active session runs at most 3 languages in parallel."
        ) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                if let message = lastErrorMessage {
                    Text(message)
                        .font(Typography.caption)
                        .foregroundStyle(Colors.error)
                }

                if isLoading && models.isEmpty {
                    HStack {
                        NTMSLoader(.small)
                        Text("Loading supported languages…")
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, Spacing.s)
                } else if models.isEmpty {
                    Text("No languages are supported on this device.")
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(models) { model in
                        LanguageRow(
                            model: model,
                            isSelected: config.dictationLocaleIdentifiers.contains(model.id),
                            isInstalling: installing.contains(model.id),
                            isRemoving: removing.contains(model.id),
                            onToggle: { toggle(model: model) },
                            onDownload: { startInstall(model: model) },
                            onCancelDownload: { cancelInstall(model: model) },
                            onRemove: { pendingRemoval = model }
                        )
                    }
                }
            }
        }
        .task {
            await refresh()
        }
        .confirmationDialog(
            "Remove dictation model?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { model in
            Button("Remove \(model.displayName)", role: .destructive) {
                let captured = model
                pendingRemoval = nil
                Task { await remove(model: captured) }
            }
            Button("Cancel", role: .cancel) {
                pendingRemoval = nil
            }
        } message: { model in
            Text("This frees up disk space. You can download \(model.displayName) again anytime.")
        }
    }

    private func toggle(model: DictationModelCatalog.ModelInfo) {
        var current = config.dictationLocaleIdentifiers
        if let index = current.firstIndex(of: model.id) {
            current.remove(at: index)
        } else if model.status == .installed {
            // Only allow selecting locales whose models are actually installed;
            // otherwise dictation would silently skip them at runtime.
            current.append(model.id)
        }
        config.dictationLocaleIdentifiers = current
    }

    /// Fired from the button tap. Creates ONE cancellable Task and stores it
    /// BEFORE the download starts, so the cancel button always has a handle.
    private func startInstall(model: DictationModelCatalog.ModelInfo) {
        // Guard against double-taps.
        guard !installing.contains(model.id) else { return }

        installing.insert(model.id)
        lastErrorMessage = nil

        let locale = model.locale
        let modelID = model.id
        let displayName = model.displayName

        let task = Task {
            defer {
                // Idempotent cleanup — `cancelInstall` may have already
                // cleared these. Running again is safe.
                Task { @MainActor in
                    self.installing.remove(modelID)
                    self.installTasks.removeValue(forKey: modelID)
                    await self.refresh()
                }
            }

            do {
                try await DictationModelCatalog.install(locale: locale)
            } catch is CancellationError {
                // User cancelled — silent, `cancelInstall` already reverted UI.
            } catch {
                // Apple occasionally reports cancel as a cocoa domain error.
                let ns = error as NSError
                let isCancelled = ns.domain == NSCocoaErrorDomain
                    && ns.code == NSUserCancelledError
                if !isCancelled {
                    await MainActor.run {
                        self.lastErrorMessage = "Couldn't download \(displayName): \(error.localizedDescription)"
                    }
                }
            }
        }

        installTasks[model.id] = task
    }

    /// Cancels an in-flight download. The UI responds instantly — even if
    /// Apple's `downloadAndInstall()` blocks in XPC waiting for a remote
    /// operation to finish, we release the locale reservation out-of-band
    /// (which is the authoritative way to undo an install on macOS 26) and
    /// clear the row's spinner state immediately.
    private func cancelInstall(model: DictationModelCatalog.ModelInfo) {
        // 1. UI feedback — instant. Row reverts to "Download" button.
        installing.remove(model.id)

        // 2. Best-effort Task cancel. May or may not abort the in-flight
        //    `downloadAndInstall()` promptly.
        installTasks[model.id]?.cancel()
        installTasks.removeValue(forKey: model.id)

        // 3. Authoritative cleanup. `AssetInventory.release(reservedLocale:)`
        //    cancels the reservation — this is what actually stops the
        //    download + undoes any partial/completed install, independent
        //    of whether Apple's XPC download honored progress.cancel().
        let locale = model.locale
        Task {
            _ = await AssetInventory.release(reservedLocale: locale)
            await refresh()
        }
    }

    private func remove(model: DictationModelCatalog.ModelInfo) async {
        removing.insert(model.id)
        defer { removing.remove(model.id) }
        lastErrorMessage = nil

        // Removing a model invalidates its selection — drop from the user's
        // dictation list BEFORE the actual uninstall so no runtime start
        // races against a half-removed model.
        if let index = config.dictationLocaleIdentifiers.firstIndex(of: model.id) {
            config.dictationLocaleIdentifiers.remove(at: index)
        }

        await DictationModelCatalog.uninstall(locale: model.locale)
        await refresh()
        // A `false` return from uninstall only indicates "wasn't reserved by
        // us"; the model might still be installed system-wide. Confirm via
        // refreshed status — if the row is still `.installed`, the remove
        // action didn't actually take effect.
        if let refreshed = models.first(where: { $0.id == model.id }),
           refreshed.status == .installed {
            lastErrorMessage = "Couldn't remove \(model.displayName). Manage it in System Settings → General → Language & Region."
        }
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        models = await DictationModelCatalog.allLocales()
    }
}

// MARK: - Row

@available(macOS 26, iOS 26, visionOS 26, *)
private struct LanguageRow: View {
    let model: DictationModelCatalog.ModelInfo
    let isSelected: Bool
    let isInstalling: Bool
    let isRemoving: Bool
    let onToggle: () -> Void
    let onDownload: () -> Void
    let onCancelDownload: () -> Void
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Spacing.m) {
            checkbox

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(model.displayName)
                    .font(Typography.subheadlineMedium)
                    .foregroundStyle(Colors.textPrimary)
                Text(statusText)
                    .font(Typography.caption)
                    .foregroundStyle(statusColor)
            }

            Spacer()

            trailingAction
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.s)
        .background(
            RoundedRectangle.squircle(CornerRadius.small)
                .fill(isHovered ? Colors.surfaceHover : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: tapAction)
        .trackHover($isHovered)
        .animationWithReduceMotion(Animations.quick, value: isHovered)
    }

    private var checkbox: some View {
        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
            .font(.title3)
            .foregroundStyle(isSelected ? Colors.accent : Colors.textTertiary)
    }

    @ViewBuilder
    private var trailingAction: some View {
        switch model.status {
        case .installed:
            HStack(spacing: Spacing.s) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Colors.success)
                SettingsPillButton(
                    title: isRemoving ? "Removing…" : "Remove",
                    icon: "trash",
                    isLoading: isRemoving,
                    isDestructive: true,
                    action: onRemove
                )
                .disabled(isRemoving)
            }
        case .supported:
            if isInstalling {
                HStack(spacing: Spacing.xs) {
                    NTMSLoader(.small)
                    SettingsPillButton(
                        title: "Cancel",
                        icon: "xmark.circle",
                        isDestructive: true,
                        action: onCancelDownload
                    )
                }
            } else {
                SettingsPillButton(
                    title: "Download",
                    icon: "arrow.down.circle",
                    action: onDownload
                )
            }
        case .downloading:
            // Model reports `.downloading` via AssetInventory. If it's our
            // own in-flight task (`isInstalling`), offer Cancel. Otherwise
            // the download was started elsewhere (e.g. System Settings) and
            // we can't cancel it from here.
            if isInstalling {
                HStack(spacing: Spacing.xs) {
                    NTMSLoader(.small)
                    SettingsPillButton(
                        title: "Cancel",
                        icon: "xmark.circle",
                        isDestructive: true,
                        action: onCancelDownload
                    )
                }
            } else {
                SettingsPillButton(title: "Downloading…", icon: "arrow.down.circle", isLoading: true, action: {})
                    .disabled(true)
            }
        case .unsupported:
            Text("Unsupported")
                .font(Typography.caption)
                .foregroundStyle(Colors.textTertiary)
        @unknown default:
            EmptyView()
        }
    }

    private func tapAction() {
        if model.status == .installed {
            onToggle()
        }
    }

    private var statusText: String {
        switch model.status {
        case .installed: return isSelected ? "Selected — ready to use" : "Installed — tap to enable"
        case .supported: return "Not installed"
        case .downloading: return "Downloading…"
        case .unsupported: return "Not available on this Mac"
        @unknown default: return ""
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .installed: return isSelected ? Colors.success : Colors.textSecondary
        case .supported, .downloading: return Colors.textTertiary
        case .unsupported: return Colors.textTertiary
        @unknown default: return Colors.textTertiary
        }
    }
}

// MARK: - Preview

#Preview {
    @Previewable @State var config = StoreConfiguration()
    DictationSettingsView()
        .environment(config)
        .frame(width: 700, height: 700)
}
