import Foundation

/// The decision half of `DictationEngine.start(locales:)`: which of the
/// requested locales can actually run, and which error to throw when none can.
///
/// Lifted out of the engine for the same reason `DictationModelInstaller` was
/// lifted out of `DictationModelCatalog.install`: the engine's body is
/// OS-gated — microphone hardware, an installed multi-gigabyte on-device
/// model, and macOS 26 Speech types — so every decision left inside it was
/// reachable only by hand. This planner carries no Speech types and drives the
/// EXISTING `DictationAssetInventory` seam, so the availability sweep and both
/// error selections run on the machine that measures coverage. What stays in
/// the engine after this is genuinely hardware assembly.
nonisolated enum DictationStartPlanner {

    /// Why a start could not produce a running engine.
    ///
    /// Was `DictationEngine.EngineError`; moved here (an alias remains behind)
    /// so the error selection — including the user-facing strings — is
    /// reachable without the macOS 26 gate. Same move as
    /// `DictationModelCatalog.InstallError`.
    enum StartError: Error, LocalizedError, Equatable {
        case noSupportedLocales
        case noInstalledModel

        var errorDescription: String? {
            switch self {
            case .noSupportedLocales:
                return "No speech-recognition locales are configured."
            case .noInstalledModel:
                return "No dictation model is installed. Open Settings → Dictation to download one."
            }
        }
    }

    /// Filters `requested` down to the locales whose on-device model is
    /// installed, preserving request order — slot order IS locale order for
    /// everything downstream (`DictationEngine`'s slots, and through
    /// `activeLocales` the service's `slotTranscripts`).
    ///
    /// Duplicates are preserved, not deduped: the engine has always built one
    /// recognizer per requested entry, and collapsing them here would change
    /// its slot count behind its back. The two errors stay distinguishable on
    /// purpose — `DictationEngineStartContractTests` pins why: one drives the
    /// user to configure a language, the other to download a model.
    ///
    /// - Throws `StartError.noSupportedLocales` when `requested` is empty,
    ///   BEFORE any inventory query — nothing was configured, so there is
    ///   nothing worth sweeping.
    /// - Throws `StartError.noInstalledModel` when locales were supplied but
    ///   none has a model on disk. Every locale is queried first: the sweep
    ///   must not bail on the first miss, or "checked every locale" becomes
    ///   "checked the first" (the multi-locale contract test exists for this).
    static func viableLocales(
        requested: [Locale],
        inventory: any DictationAssetInventory
    ) async throws -> [Locale] {
        guard !requested.isEmpty else {
            throw StartError.noSupportedLocales
        }

        var viable: [Locale] = []
        for locale in requested {
            if await inventory.isInstalled(locale: locale) {
                viable.append(locale)
            }
        }

        guard !viable.isEmpty else {
            throw StartError.noInstalledModel
        }
        return viable
    }
}
