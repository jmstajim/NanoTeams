import Foundation
import XCTest

@testable import NanoTeams

/// Scripted inventory for the planner's sweep. Records every query so order
/// and completeness assertions can distinguish "swept every locale" from
/// "bailed on the first miss". Only `isInstalled` matters to the planner; the
/// other two requirements are inert.
private final class ScriptedStartInventory: DictationAssetInventory, @unchecked Sendable {
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
}
