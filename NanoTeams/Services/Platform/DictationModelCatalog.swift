import Foundation
import Speech

/// Read-and-install API for on-device dictation models. Backs the Dictation
/// settings UI.
///
/// Runtime dictation NEVER calls into this — downloads happen only when the
/// user taps a button in settings. Keeping the runtime path side-effect-free
/// is why this exists as a separate service.
@available(macOS 26, iOS 26, visionOS 26, *)
nonisolated enum DictationModelCatalog {

    /// Snapshot of a single locale's availability for on-device dictation.
    struct ModelInfo: Identifiable, Hashable {
        var id: String { locale.identifier }
        let locale: Locale
        let status: AssetInventory.Status

        var displayName: String {
            Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        }
    }

    /// Returns all locales supported by `DictationTranscriber` on this device
    /// along with their install status, sorted via `sortByInstalledFirst`.
    static func allLocales() async -> [ModelInfo] {
        let locales = await DictationTranscriber.supportedLocales
        var infos: [ModelInfo] = []
        for locale in locales {
            let status = await status(for: locale)
            infos.append(ModelInfo(locale: locale, status: status))
        }
        return sortByInstalledFirst(infos)
    }

    /// Pure sort: installed locales first (keeps the user's actual choices
    /// above dozens of "Not installed" rows), then everything else;
    /// alphabetical by localized display name within each group.
    static func sortByInstalledFirst(_ infos: [ModelInfo]) -> [ModelInfo] {
        infos.sorted { lhs, rhs in
            let lhsRank = (lhs.status == .installed) ? 0 : 1
            let rhsRank = (rhs.status == .installed) ? 0 : 1
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// Fetches the current install status for a single locale.
    static func status(for locale: Locale) async -> AssetInventory.Status {
        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        return await AssetInventory.status(forModules: [transcriber])
    }

    /// Reasons `install(locale:)` may throw beyond Apple's own errors.
    ///
    /// The cases live on `DictationModelInstaller`, which carries no Speech types and is
    /// therefore reachable without the `@available(macOS 26, *)` gate this enum sits
    /// under. Aliased here so the settings UI and the existing pins keep spelling it
    /// `DictationModelCatalog.InstallError`.
    typealias InstallError = DictationModelInstaller.InstallError

    /// Kicks off the user-visible model download.
    ///
    /// The state machine — undocumented-nil verification and both cancellation rollbacks —
    /// lives in `DictationModelInstaller`, which is Speech-free and therefore testable.
    /// Everything left here is the Speech-framework adapter.
    static func install(locale: Locale) async throws {
        try await DictationModelInstaller.install(
            locale: locale, inventory: SystemDictationAssetInventory())
    }

    /// Removes the on-device model for the given locale. Returns `true` if
    /// the locale was actually released; `false` if it wasn't reserved to
    /// begin with (safe no-op, caller can still refresh the UI).
    ///
    /// Thin wrapper over `AssetInventory.release(reservedLocale:)`. After
    /// release, the model's status will transition back to `.supported`,
    /// meaning it can be re-downloaded later without impacting other locales.
    @discardableResult
    static func uninstall(locale: Locale) async -> Bool {
        await AssetInventory.release(reservedLocale: locale)
    }
}

/// Speech-framework conformance of the install seam — the only part of the install path
/// that touches `AssetInventory`, and the only part that cannot be driven from a test.
@available(macOS 26, iOS 26, visionOS 26, *)
nonisolated struct SystemDictationAssetInventory: DictationAssetInventory {

    func installationRequest(for locale: Locale) async throws -> (any DictationInstallRequest)? {
        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) else { return nil }
        return SystemDictationInstallRequest(request: request)
    }

    func isInstalled(locale: Locale) async -> Bool {
        await DictationModelCatalog.status(for: locale) == .installed
    }

    @discardableResult
    func release(reservedLocale: Locale) async -> Bool {
        await AssetInventory.release(reservedLocale: reservedLocale)
    }
}

@available(macOS 26, iOS 26, visionOS 26, *)
nonisolated struct SystemDictationInstallRequest: DictationInstallRequest {
    let request: AssetInstallationRequest

    func downloadAndInstall() async throws {
        try await request.downloadAndInstall()
    }

    func cancelProgress() {
        request.progress.cancel()
    }
}
