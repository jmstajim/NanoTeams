import AVFoundation
import Foundation

/// The decision half of `DictationEngine.start(locales:)`: which of the
/// requested locales can actually run, how each locale's analyzer is fed the
/// microphone's audio, and which error a start throws when it cannot run.
///
/// Lifted out of the engine for the same reason `DictationModelInstaller` was
/// lifted out of `DictationModelCatalog.install`: the engine's body is
/// OS-gated — microphone hardware, an installed multi-gigabyte on-device
/// model, and macOS 26 Speech types — so every decision left inside it was
/// reachable only by hand. This planner carries no Speech types and drives the
/// EXISTING `DictationAssetInventory` seam, so the availability sweep, each
/// slot's analyzer feed and the start errors run on the machine that measures
/// coverage. What stays in the engine after this is genuinely hardware assembly.
nonisolated enum DictationStartPlanner {

    /// Why a start — or one locale's slot in it — could not run.
    ///
    /// Was `DictationEngine.EngineError`; moved here (an alias remains behind)
    /// so the error selection — including the user-facing strings — is
    /// reachable without the macOS 26 gate. Same move as
    /// `DictationModelCatalog.InstallError`.
    enum StartError: Error, LocalizedError, Equatable {
        case noSupportedLocales
        case noInstalledModel
        /// One slot, not the whole start: the locale's analyzer named no audio
        /// format, or no converter to the one it named can be built. The engine
        /// reports it through `onError` and goes on to the next locale.
        case audioFormatUnavailable(localeIdentifier: String)

        var errorDescription: String? {
            switch self {
            case .noSupportedLocales:
                return "No speech-recognition locales are configured."
            case .noInstalledModel:
                return "No dictation model is installed. Open Settings → Dictation to download one."
            case .audioFormatUnavailable(let localeIdentifier):
                // The name the Dictation settings list the language under
                // (`DictationModelCatalog.ModelInfo.displayName`), not its identifier.
                let language = Locale.current.localizedString(forIdentifier: localeIdentifier) ?? localeIdentifier
                return "Dictation in \(language) can't read this microphone's audio format."
            }
        }
    }

    /// How one slot's analyzer receives the microphone's buffers.
    struct AnalyzerFeed {
        /// The format the analyzer is prepared with and receives.
        let format: AVAudioFormat
        /// Converts the tap's buffers to `format`; `nil` when the analyzer takes
        /// the capture format as it is.
        let converter: AVAudioConverter?
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

    /// A slot's feed, from `SpeechAnalyzer.bestAvailableAudioFormat`'s answer
    /// for the capture format.
    ///
    /// `nil` when the analyzer named no format, or when no converter from the
    /// capture format to the named one can be built: either way the slot cannot
    /// be fed, and the engine skips it with `StartError.audioFormatUnavailable`.
    /// Until 2026-09-15 both misses fed the capture format as it was — the first
    /// through `?? nativeFormat`, the second because a bridge without a converter
    /// yields its input unconverted. The input node captures Float32, and on
    /// macOS 27 `AnalyzerInput(buffer:)` traps on a Float32 buffer
    /// (`EXC_BREAKPOINT` in `AnalyzerInput.data(from:)`), so the first tap
    /// callback would have taken the app down. Measured the same day: for
    /// `DictationTranscriber(en-US)` and a Float32 48 kHz capture format the
    /// analyzer names Int16 16 kHz.
    ///
    /// `AVAudioFormat` compares by value, so a named format identical to the
    /// capture format builds no converter even as a separate instance.
    /// `makeConverter` is the seam that lets a test make the conversion fail.
    static func analyzerFeed(
        bestAvailable: AVAudioFormat?,
        capture: AVAudioFormat,
        makeConverter: (_ from: AVAudioFormat, _ to: AVAudioFormat) -> AVAudioConverter? = {
            AVAudioConverter(from: $0, to: $1)
        }
    ) -> AnalyzerFeed? {
        guard let bestAvailable else { return nil }
        guard bestAvailable != capture else {
            return AnalyzerFeed(format: bestAvailable, converter: nil)
        }
        guard let converter = makeConverter(capture, bestAvailable) else { return nil }
        return AnalyzerFeed(format: bestAvailable, converter: converter)
    }

    /// What a start throws when every slot it tried failed.
    ///
    /// `viableLocales` has already found a model for every locale the engine
    /// tries, so this is never a missing model: the last slot's own error is the
    /// reason. Until 2026-09-15 the engine threw `noInstalledModel` here, and in
    /// the single-shot error banner its advice — download a model — overwrote the
    /// slot's own message a moment after `onError` had shown it. The fallback
    /// exists for the type alone: the engine gets here only after trying a locale.
    static func startError(afterEverySlotFailed lastSlotError: (any Error)?) -> any Error {
        lastSlotError ?? StartError.noInstalledModel
    }
}
