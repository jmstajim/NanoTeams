import Speech
import XCTest
@testable import NanoTeams

/// Covers the **read-only** half of `DictationModelCatalog` that
/// `DictationModelCatalogTests` leaves untouched: `allLocales()`,
/// `status(for:)`, `InstallError`'s user-facing copy, and the `displayName`
/// fallback that `sortByInstalledFirst` orders by.
///
/// Safety: `DictationTranscriber.supportedLocales` and
/// `AssetInventory.status(forModules:)` are pure queries — they neither reserve
/// a locale nor start a download. `install(locale:)` and `uninstall(locale:)`
/// are NOT exercised here: the first pulls a multi-hundred-megabyte Apple
/// asset, the second releases a reservation. Both are environment-mutating and
/// stay manual.
final class DictationModelCatalogQueryTests: XCTestCase {

    private func skipIfUnavailable() throws {
        guard #unavailable(macOS 26, iOS 26, visionOS 26) else { return }
        throw XCTSkip("DictationModelCatalog requires macOS 26+.")
    }

    @available(macOS 26, iOS 26, visionOS 26, *)
    private func info(_ identifier: String, _ status: AssetInventory.Status) -> DictationModelCatalog.ModelInfo {
        DictationModelCatalog.ModelInfo(locale: Locale(identifier: identifier), status: status)
    }

    // MARK: - allLocales()

    /// The catalog is the Settings list. Dropping a locale on the way through
    /// the per-locale status loop would silently make a downloadable language
    /// un-downloadable, with no error anywhere.
    func testAllLocales_coversEverySupportedLocaleExactlyOnce() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let expected = Set(await DictationTranscriber.supportedLocales.map(\.identifier))
        let infos = await DictationModelCatalog.allLocales()

        XCTAssertFalse(expected.isEmpty, "device reports no dictation locales at all — nothing to verify")
        XCTAssertEqual(Set(infos.map(\.locale.identifier)), expected)
        XCTAssertEqual(infos.count, expected.count, "no duplicated rows")
        XCTAssertEqual(infos.map(\.id), infos.map(\.locale.identifier), "id must stay the locale identifier")
    }

    /// Asserts the ordering invariant rather than a fixed list — which locales
    /// are installed is a property of the machine, not of the code.
    func testAllLocales_isSortedInstalledFirstThenAlphabetically() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let infos = await DictationModelCatalog.allLocales()
        try XCTSkipIf(infos.isEmpty, "device reports no dictation locales")

        let boundary = infos.firstIndex { $0.status != .installed } ?? infos.count
        XCTAssertFalse(
            infos[boundary...].contains { $0.status == .installed },
            "an installed locale must never sort below a non-installed one"
        )

        for block in [Array(infos[..<boundary]), Array(infos[boundary...])] {
            let names = block.map(\.displayName)
            XCTAssertEqual(
                names,
                names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
                "each group must be alphabetical by localized display name"
            )
        }
    }

    // MARK: - status(for:)

    func testStatus_nonexistentLocale_reportsUnsupported() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let status = await DictationModelCatalog.status(for: Locale(identifier: "xx_ZZ"))
        XCTAssertEqual(status, .unsupported)
    }

    /// `status(for:)` is the single-locale probe the Settings row refreshes
    /// with; it must agree with the bulk listing or a row can show "Installed"
    /// while the list says otherwise.
    func testStatus_agreesWithAllLocalesForTheSameLocale() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let infos = await DictationModelCatalog.allLocales()
        let first = try XCTUnwrap(infos.first, "device reports no dictation locales")
        let direct = await DictationModelCatalog.status(for: first.locale)
        XCTAssertEqual(direct, first.status)
    }

    // MARK: - InstallError copy

    /// User-visible copy pin. `nothingInstallable` is the undocumented case
    /// where Apple hands back a nil installation request for a locale that is
    /// still `.supported` afterwards — the message must not read like the
    /// "already installed" no-op that a nil request nominally means.
    func testInstallError_nothingInstallable_saysNoModelIsAvailableToDownload() throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let message = try XCTUnwrap(DictationModelCatalog.InstallError.nothingInstallable.errorDescription)
        XCTAssertEqual(message, "No dictation model is available for download for this language.")
        XCTAssertFalse(message.isEmpty)
    }

    /// `localizedDescription` is what actually reaches the banner — a
    /// `LocalizedError` whose `errorDescription` isn't picked up degrades to
    /// "The operation couldn't be completed."
    func testInstallError_localizedDescription_usesErrorDescription() throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let error: any Error = DictationModelCatalog.InstallError.nothingInstallable
        XCTAssertEqual(
            error.localizedDescription,
            DictationModelCatalog.InstallError.nothingInstallable.errorDescription
        )
    }

    // MARK: - displayName fallback

    /// `Locale.localizedString(forIdentifier:)` returns nil for an identifier
    /// with no known language, and the sort keys off `displayName` — a nil that
    /// collapsed to "" would bunch every unnameable locale at the top of the
    /// Settings list.
    func testDisplayName_unnameableIdentifier_fallsBackToTheRawIdentifier() throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        XCTAssertNil(
            Locale.current.localizedString(forIdentifier: "xx_ZZ"),
            "premise of this test: the identifier has no localized name"
        )
        XCTAssertEqual(info("xx_ZZ", .installed).displayName, "xx_ZZ")
    }

    // MARK: - sortByInstalledFirst corners

    func testSortByInstalledFirst_unnameableLocales_orderByRawIdentifier() throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let sorted = DictationModelCatalog.sortByInstalledFirst([
            info("xx_ZZ", .supported),
            info("qq_ZZ", .supported),
        ])
        XCTAssertEqual(sorted.map(\.id), ["qq_ZZ", "xx_ZZ"])
    }

    /// `.downloading` is neither installed nor absent. The rank predicate is
    /// `status == .installed`, so an in-flight download must stay in the lower
    /// group — writing it as `status != .unsupported` would promote a model the
    /// user cannot dictate with yet.
    func testSortByInstalledFirst_downloadingRanksWithTheNotInstalledGroup() throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let sorted = DictationModelCatalog.sortByInstalledFirst([
            info("qq_ZZ", .downloading),
            info("xx_ZZ", .installed),
        ])
        XCTAssertEqual(sorted.map(\.id), ["xx_ZZ", "qq_ZZ"])
    }

    func testSortByInstalledFirst_unsupportedRanksWithTheNotInstalledGroup() throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let sorted = DictationModelCatalog.sortByInstalledFirst([
            info("qq_ZZ", .unsupported),
            info("xx_ZZ", .installed),
        ])
        XCTAssertEqual(sorted.map(\.id), ["xx_ZZ", "qq_ZZ"])
    }

    /// Installed rank beats the alphabet — the whole point of the two-tier sort
    /// is keeping the user's actual models above dozens of "Not installed" rows.
    func testSortByInstalledFirst_installedRankBeatsAlphabeticalOrder() throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let sorted = DictationModelCatalog.sortByInstalledFirst([
            info("qq_ZZ", .supported),   // alphabetically first
            info("xx_ZZ", .installed),   // alphabetically last
        ])
        XCTAssertEqual(sorted.map(\.id), ["xx_ZZ", "qq_ZZ"])
    }

    func testSortByInstalledFirst_singleElement_isReturnedUnchanged() throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let only = info("xx_ZZ", .supported)
        XCTAssertEqual(DictationModelCatalog.sortByInstalledFirst([only]), [only])
    }

    /// The comparator answers `false` in both directions for a tie, which makes
    /// their relative order unspecified — but nothing may be dropped or
    /// duplicated. Deliberately asserts membership, not order: `Array.sorted`
    /// is not documented as stable, so pinning an order here would be pinning
    /// an implementation detail of the standard library.
    func testSortByInstalledFirst_fullyTiedElements_keepsEveryOne() throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let tied = info("xx_ZZ", .supported)
        let sorted = DictationModelCatalog.sortByInstalledFirst([tied, tied, tied])
        XCTAssertEqual(sorted.count, 3)
        XCTAssertTrue(sorted.allSatisfy { $0 == tied })
    }

    func testSortByInstalledFirst_allInstalled_isPurelyAlphabetical() throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let sorted = DictationModelCatalog.sortByInstalledFirst([
            info("xx_ZZ", .installed),
            info("qq_ZZ", .installed),
        ])
        XCTAssertEqual(sorted.map(\.id), ["qq_ZZ", "xx_ZZ"])
    }
}
