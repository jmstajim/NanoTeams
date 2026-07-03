import XCTest
@testable import NanoTeams

final class FeatureTipIDTests: XCTestCase {

    // MARK: - Raw value contract

    func testRawValues_pinned() {
        // These raw values are persisted in UserDefaults via
        // `StoreConfiguration.dismissedFeatureTipIDs`. Changing them silently
        // un-dismisses every tip on every existing install — pin them.
        XCTAssertEqual(FeatureTipID.llm.rawValue, "llm")
        XCTAssertEqual(FeatureTipID.exploratorySearch.rawValue, "exploratorySearch")
        XCTAssertEqual(FeatureTipID.vision.rawValue, "vision")
        XCTAssertEqual(FeatureTipID.dictation.rawValue, "dictation")
        XCTAssertEqual(FeatureTipID.autovisor.rawValue, "autovisor")
        XCTAssertEqual(FeatureTipID.bash.rawValue, "bash")
    }

    func testAllCases_orderMatchesShelfOrder() {
        // Display order in the Watchtower Setup shelf must put LLM first
        // because LLM reachability is the foundational setting — see
        // WatchtowerSetupSection.visibleTips.
        XCTAssertEqual(FeatureTipID.allCases, [.llm, .exploratorySearch, .vision, .dictation, .autovisor, .bash, .computerUse])
    }

    func testRawValueRoundTrip() {
        for tip in FeatureTipID.allCases {
            XCTAssertEqual(FeatureTipID(rawValue: tip.rawValue), tip)
        }
    }

    func testRawValue_unknownString_returnsNil() {
        // Unknown raw strings (e.g. a tip ID added in a newer build, then the
        // user downgrades) must round-trip as nil so the persisted Set<String>
        // can hold them harmlessly without breaking the typed API.
        XCTAssertNil(FeatureTipID(rawValue: "future_tip_id"))
        XCTAssertNil(FeatureTipID(rawValue: ""))
    }
}
