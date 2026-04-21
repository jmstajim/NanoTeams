import XCTest
@testable import NanoTeams

/// Exercises the language-code → speech-locale mapping. The live
/// `currentSpeechLocales()` reads `Locale.preferredLanguages`, which is
/// environment-dependent — only smoke-checked here.
final class InputSourceLanguagesTests: XCTestCase {

    // MARK: - Mapping

    func testMapping_commonCodes_resolveToExpectedSpeechLocales() {
        XCTAssertEqual(InputSourceLanguages._testSpeechLocale(for: "en")?.identifier, "en-US")
        XCTAssertEqual(InputSourceLanguages._testSpeechLocale(for: "ru")?.identifier, "ru-RU")
        XCTAssertEqual(InputSourceLanguages._testSpeechLocale(for: "de")?.identifier, "de-DE")
        XCTAssertEqual(InputSourceLanguages._testSpeechLocale(for: "fr")?.identifier, "fr-FR")
        XCTAssertEqual(InputSourceLanguages._testSpeechLocale(for: "ja")?.identifier, "ja-JP")
    }

    func testMapping_stripsRegionSuffix_beforeLookup() {
        // `Locale.preferredLanguages` often returns tags with region or script,
        // e.g. "en-US" or "zh-Hans-CN". Collapse to base language for lookup.
        XCTAssertEqual(InputSourceLanguages._testSpeechLocale(for: "en-GB")?.identifier, "en-US")
        XCTAssertEqual(InputSourceLanguages._testSpeechLocale(for: "en_US")?.identifier, "en-US")
        XCTAssertEqual(InputSourceLanguages._testSpeechLocale(for: "EN")?.identifier, "en-US")
        XCTAssertEqual(InputSourceLanguages._testSpeechLocale(for: "zh-Hans-CN")?.identifier, "zh-CN")
    }

    func testMapping_unknownCode_returnsNil() {
        XCTAssertNil(InputSourceLanguages._testSpeechLocale(for: "xx"))
        XCTAssertNil(InputSourceLanguages._testSpeechLocale(for: ""))
    }

    func testMapping_norwegianVariants_collapseToNBNO() {
        XCTAssertEqual(InputSourceLanguages._testSpeechLocale(for: "no")?.identifier, "nb-NO")
        XCTAssertEqual(InputSourceLanguages._testSpeechLocale(for: "nb")?.identifier, "nb-NO")
    }

    // MARK: - Live enumeration (smoke test)

    func testCurrentSpeechLocales_returnsNonEmptyList() {
        // At minimum the fallback `[en-US]` is returned.
        let locales = InputSourceLanguages.currentSpeechLocales()
        XCTAssertFalse(locales.isEmpty)
    }

    func testCurrentSpeechLocales_returnsUniqueLocales() {
        let locales = InputSourceLanguages.currentSpeechLocales()
        let identifiers = locales.map(\.identifier)
        XCTAssertEqual(identifiers.count, Set(identifiers).count, "Expected deduplicated locale list")
    }

    func testCurrentSpeechLocales_firstEntryMatchesSystemPrimary() {
        // The Primary preferred language should be first in the returned list.
        // If the system has no preferred languages (nearly impossible) the
        // fallback `en-US` is returned.
        let locales = InputSourceLanguages.currentSpeechLocales()
        guard let first = locales.first else {
            XCTFail("currentSpeechLocales must never be empty")
            return
        }
        if let systemPrimary = Locale.preferredLanguages.first,
           let expected = InputSourceLanguages._testSpeechLocale(for: systemPrimary) {
            XCTAssertEqual(first.identifier, expected.identifier)
        } else {
            XCTAssertEqual(first.identifier, "en-US")
        }
    }
}
