import AVFoundation
import Foundation
import XCTest

@testable import NanoTeams

/// Scripted inventory for the planner's sweep. Records every query so order
/// and completeness assertions can distinguish "swept every locale" from
/// "bailed on the first miss". Only `isInstalled` matters to the planner; the
/// other two requirements are inert.
nonisolated private final class ScriptedStartInventory: DictationAssetInventory, @unchecked Sendable {
    private let lock = NSLock()
    private let installed: Set<String>
    private var _queried: [Locale] = []

    init(installed: Set<String>) {
        self.installed = installed
    }

    var queried: [Locale] { lock.withLock { _queried } }

    nonisolated func installationRequest(
        for locale: Locale
    ) async throws -> (any DictationInstallRequest)? { nil }

    nonisolated func isInstalled(locale: Locale) async -> Bool {
        lock.withLock { _queried.append(locale) }
        return installed.contains(locale.identifier)
    }

    @discardableResult
    nonisolated func release(reservedLocale: Locale) async -> Bool { false }
}

/// Covers `DictationStartPlanner` — the decision half of
/// `DictationEngine.start(locales:)`, extracted (D-1) so the availability
/// sweep and both error selections run without Speech types, microphone
/// permission, or an installed model. The engine→planner→live-inventory
/// integration stays pinned by `DictationEngineStartContractTests`; this suite
/// is the fake-driven half those tests could never reach (a locale that IS
/// installed, without a model on disk).
final class DictationStartPlannerTests: XCTestCase {

    private let en = Locale(identifier: "en_US")
    private let ru = Locale(identifier: "ru_RU")
    private let de = Locale(identifier: "de_DE")

    // MARK: - Empty request

    /// The empty case throws BEFORE any inventory query. Mirrors
    /// `DictationService.startEngine`'s own ordering philosophy (surface the
    /// empty-locale state before prompting for the mic): nothing was
    /// configured, so there is nothing worth sweeping.
    func testViableLocales_emptyRequest_throwsNoSupportedLocales_withoutQueryingInventory() async {
        let inventory = ScriptedStartInventory(installed: ["en_US"])

        do {
            _ = try await DictationStartPlanner.viableLocales(
                requested: [], inventory: inventory)
            XCTFail("Expected noSupportedLocales")
        } catch let error as DictationStartPlanner.StartError {
            XCTAssertEqual(error, .noSupportedLocales)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
        XCTAssertTrue(inventory.queried.isEmpty,
                      "an empty request must not touch the inventory at all")
    }

    // MARK: - Nothing installed

    /// Every locale is queried before the error is thrown — a single-locale
    /// fixture can't tell "swept every locale" from "bailed on the first
    /// miss", so this drives three.
    func testViableLocales_noneInstalled_throwsNoInstalledModel_afterSweepingEveryLocale() async {
        let inventory = ScriptedStartInventory(installed: [])

        do {
            _ = try await DictationStartPlanner.viableLocales(
                requested: [en, ru, de], inventory: inventory)
            XCTFail("Expected noInstalledModel")
        } catch let error as DictationStartPlanner.StartError {
            XCTAssertEqual(error, .noInstalledModel)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
        XCTAssertEqual(inventory.queried.map(\.identifier), ["en_US", "ru_RU", "de_DE"])
    }

    // MARK: - The filter

    /// Only installed locales survive, in request order — slot order IS locale
    /// order for everything downstream (the engine's slots, and through
    /// `activeLocales` the service's `slotTranscripts`).
    func testViableLocales_mixedInstall_returnsOnlyInstalled_inRequestOrder() async throws {
        let inventory = ScriptedStartInventory(installed: ["ru_RU", "de_DE"])

        let viable = try await DictationStartPlanner.viableLocales(
            requested: [en, ru, de], inventory: inventory)

        XCTAssertEqual(viable.map(\.identifier), ["ru_RU", "de_DE"])
        XCTAssertEqual(inventory.queried.count, 3, "the miss must not stop the sweep")
    }

    func testViableLocales_allInstalled_returnsAllInRequestOrder() async throws {
        let inventory = ScriptedStartInventory(installed: ["en_US", "ru_RU", "de_DE"])

        let viable = try await DictationStartPlanner.viableLocales(
            requested: [de, en, ru], inventory: inventory)

        XCTAssertEqual(viable.map(\.identifier), ["de_DE", "en_US", "ru_RU"],
                       "request order wins, not inventory or alphabetical order")
    }

    /// Duplicates are preserved, not deduped: the engine has always built one
    /// recognizer per requested entry, and collapsing them in the planner
    /// would change the engine's slot count behind its back. The user-facing
    /// locale list is deduplicated upstream (Settings owns it); the planner is
    /// a filter, not a normalizer.
    func testViableLocales_duplicateRequests_arePreservedNotDeduped() async throws {
        let inventory = ScriptedStartInventory(installed: ["en_US", "ru_RU"])

        let viable = try await DictationStartPlanner.viableLocales(
            requested: [en, ru, en], inventory: inventory)

        XCTAssertEqual(viable.map(\.identifier), ["en_US", "ru_RU", "en_US"])
    }

    // MARK: - Error identity

    /// The two errors must stay distinguishable: `noSupportedLocales` sends
    /// the user to configure a language, `noInstalledModel` to download a
    /// model. `DictationEngineTests` pins the user-facing strings; this pins
    /// that the SELECTION cannot collapse (an installed-elsewhere inventory
    /// still yields the empty-request error, not the no-model one).
    func testViableLocales_emptyRequest_isNotReportedAsNoInstalledModel() async {
        let inventory = ScriptedStartInventory(installed: [])

        do {
            _ = try await DictationStartPlanner.viableLocales(
                requested: [], inventory: inventory)
            XCTFail("Expected a throw")
        } catch let error as DictationStartPlanner.StartError {
            XCTAssertNotEqual(error, .noInstalledModel,
                              "empty request and no-model-on-disk are different user problems")
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - Analyzer feed

    private func pcm(
        _ common: AVAudioCommonFormat, rate: Double, channels: AVAudioChannelCount = 1
    ) throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(commonFormat: common, sampleRate: rate, channels: channels, interleaved: false))
    }

    /// The defect this decision was lifted out for (2026-09-15): the engine fed the capture
    /// format when the analyzer named none, and on macOS 27 `AnalyzerInput(buffer:)` traps on
    /// the Float32 buffers the input node captures. A slot whose analyzer named no format gets
    /// no feed at all.
    func testAnalyzerFeed_whenTheAnalyzerNamesNoFormat_isNil_neverTheCaptureFormat() throws {
        let capture = try pcm(.pcmFormatFloat32, rate: 48_000)

        XCTAssertNil(DictationStartPlanner.analyzerFeed(bestAvailable: nil, capture: capture))
    }

    /// The same crash one step later: a named format with no converter to it left the bridge
    /// without one, and a bridge without a converter yields its input as it is.
    func testAnalyzerFeed_whenNoConverterCanBeBuilt_isNil_neverAnUnconvertedFeed() throws {
        let capture = try pcm(.pcmFormatFloat32, rate: 48_000)
        let named = try pcm(.pcmFormatInt16, rate: 16_000)

        XCTAssertNil(DictationStartPlanner.analyzerFeed(
            bestAvailable: named, capture: capture, makeConverter: { _, _ in nil }))
    }

    /// The pair measured on macOS 27 for `DictationTranscriber(en-US)`, through the real
    /// converter: a Float32 48 kHz capture format, Int16 16 kHz named by the analyzer.
    func testAnalyzerFeed_whenTheFormatsDiffer_convertsFromTheCaptureToTheNamedFormat() throws {
        let capture = try pcm(.pcmFormatFloat32, rate: 48_000)
        let named = try pcm(.pcmFormatInt16, rate: 16_000)

        let feed = try XCTUnwrap(DictationStartPlanner.analyzerFeed(bestAvailable: named, capture: capture))

        XCTAssertEqual(feed.format, named)
        let converter = try XCTUnwrap(feed.converter)
        XCTAssertEqual(converter.inputFormat, capture)
        XCTAssertEqual(converter.outputFormat, named)
    }

    /// Equality is by value — the analyzer hands back its own instance — and an equal pair never
    /// reaches the converter factory: a converter between identical formats is pure work on the
    /// realtime thread.
    func testAnalyzerFeed_identicalFormatsBuiltSeparately_buildNoConverter() throws {
        var factoryCalls = 0

        let feed = try XCTUnwrap(DictationStartPlanner.analyzerFeed(
            bestAvailable: try pcm(.pcmFormatInt16, rate: 16_000),
            capture: try pcm(.pcmFormatInt16, rate: 16_000),
            makeConverter: { from, to in
                factoryCalls += 1
                return AVAudioConverter(from: from, to: to)
            }))

        XCTAssertNil(feed.converter)
        XCTAssertEqual(factoryCalls, 0)
    }

    /// Each field alone is a difference: sample rate, sample format, channel count.
    func testAnalyzerFeed_aDifferenceInOneFieldAlone_stillConverts() throws {
        let capture = try pcm(.pcmFormatInt16, rate: 16_000)
        let named = [
            try pcm(.pcmFormatInt16, rate: 48_000),
            try pcm(.pcmFormatFloat32, rate: 16_000),
            try pcm(.pcmFormatInt16, rate: 16_000, channels: 2),
        ]

        for format in named {
            let feed = try XCTUnwrap(DictationStartPlanner.analyzerFeed(bestAvailable: format, capture: capture))
            XCTAssertEqual(feed.format, format)
            XCTAssertNotNil(feed.converter, "\(format) against \(capture)")
        }
    }

    /// Reported per slot, so it names the language — by the name the Dictation settings list it
    /// under (`DictationModelCatalog.ModelInfo.displayName`), not its identifier — and it is not
    /// the no-model error: the model is installed, and downloading another fixes nothing.
    func testAudioFormatUnavailable_namesTheLanguage_andIsNotTheNoModelError() throws {
        let language = try XCTUnwrap(Locale.current.localizedString(forIdentifier: "ru_RU"))
        let description = DictationStartPlanner.StartError
            .audioFormatUnavailable(localeIdentifier: "ru_RU").errorDescription ?? ""

        XCTAssertTrue(description.contains(language), description)
        XCTAssertFalse(description.contains("ru_RU"), description)
        XCTAssertNotEqual(description, DictationStartPlanner.StartError.noInstalledModel.errorDescription)
    }

    // MARK: - A start whose every slot failed

    /// `viableLocales` has already found a model for every locale the engine tries, so a start
    /// whose every slot failed is not a missing model — and the no-model advice overwrote the
    /// slot's own message in the single-shot error banner (review, 2026-09-15).
    func testStartError_afterEverySlotFailed_isTheLastSlotsOwnError() {
        let slotError = DictationStartPlanner.StartError.audioFormatUnavailable(localeIdentifier: "en_US")

        let error = DictationStartPlanner.startError(afterEverySlotFailed: slotError)

        XCTAssertEqual(error as? DictationStartPlanner.StartError, slotError)
    }

    /// A system error from `prepareToAnalyze` passes through as it is, not re-typed.
    func testStartError_afterEverySlotFailed_passesASystemErrorThrough() {
        let systemError = NSError(domain: "SFSpeechErrorDomain", code: 7)

        let error = DictationStartPlanner.startError(afterEverySlotFailed: systemError) as NSError

        XCTAssertEqual(error.domain, "SFSpeechErrorDomain")
        XCTAssertEqual(error.code, 7)
    }

    /// Unreachable from the engine — the loop runs whenever `viableLocales` returns — and kept
    /// only so the type has an answer.
    func testStartError_withNoSlotErrorRecorded_fallsBackToNoInstalledModel() {
        let error = DictationStartPlanner.startError(afterEverySlotFailed: nil)

        XCTAssertEqual(error as? DictationStartPlanner.StartError, .noInstalledModel)
    }
}
