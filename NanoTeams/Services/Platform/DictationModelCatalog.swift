import Foundation
import Speech

/// Read-and-install API for on-device dictation models. Backs the Dictation
/// settings UI.
///
/// Runtime dictation NEVER calls into this — downloads happen only when the
/// user taps a button in settings. Keeping the runtime path side-effect-free
/// is why this exists as a separate service.
@available(macOS 26, iOS 26, visionOS 26, *)
enum DictationModelCatalog {

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
    /// along with their install status. Sorted by localized display name.
    static func allLocales() async -> [ModelInfo] {
        let locales = await DictationTranscriber.supportedLocales
        var infos: [ModelInfo] = []
        for locale in locales {
            let status = await status(for: locale)
            infos.append(ModelInfo(locale: locale, status: status))
        }
        return infos.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Fetches the current install status for a single locale.
    static func status(for locale: Locale) async -> AssetInventory.Status {
        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        return await AssetInventory.status(forModules: [transcriber])
    }

    /// Reasons `install(locale:)` may throw beyond Apple's own errors.
    enum InstallError: Error, LocalizedError {
        /// Apple returned nil from `assetInstallationRequest(supporting:)` but
        /// the locale is still `.supported` post-call — nothing was actually
        /// installed. Distinguishes "already-installed" (documented nil) from
        /// "nothing-installable" (undocumented but observed).
        case nothingInstallable

        var errorDescription: String? {
            switch self {
            case .nothingInstallable:
                return "No dictation model is available for download for this language."
            }
        }
    }

    /// Kicks off the user-visible model download. Throws if the request can't
    /// be constructed (e.g. locale is `.unsupported`), the install fails,
    /// the owning `Task` was cancelled, or a nil installation request doesn't
    /// actually correspond to a completed install (`InstallError.nothingInstallable`).
    ///
    /// Cancellation semantics:
    /// - On `Task.cancel()`, the underlying `Progress` is cancelled to signal
    ///   the installer to abort.
    /// - Because Apple's `downloadAndInstall()` may not honor progress
    ///   cancellation reliably, we also call
    ///   `AssetInventory.release(reservedLocale:)` after the fact — that
    ///   uninstalls the model if the download managed to finish despite our
    ///   cancel signal, restoring the `.supported` state the user expects.
    /// - The function then throws `CancellationError` so the caller's
    ///   `try await` unblocks promptly.
    static func install(locale: Locale) async throws {
        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) else {
            // Apple's docs say nil = already installed. Verify — if the locale
            // is still `.supported` post-call, the request was silently refused
            // (observed for locales with no available model on the device's
            // region) and the user needs to know.
            if await status(for: locale) != .installed {
                throw InstallError.nothingInstallable
            }
            return
        }

        do {
            try await withTaskCancellationHandler {
                try await request.downloadAndInstall()
            } onCancel: {
                request.progress.cancel()
            }
        } catch {
            // If our Task was cancelled, roll back: drop the locale reservation
            // so any partial/completed install is undone, then surface a
            // standard CancellationError to callers.
            if Task.isCancelled {
                _ = await AssetInventory.release(reservedLocale: locale)
                throw CancellationError()
            }
            throw error
        }

        // Success path — but the cancel signal may have raced in after the
        // download finished. Honor the cancel by releasing and throwing.
        if Task.isCancelled {
            _ = await AssetInventory.release(reservedLocale: locale)
            throw CancellationError()
        }
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
