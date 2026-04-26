import XCTest
@testable import NanoTeams

/// Pure logic tests for `WatchtowerSetupSection.visibleTips` — the predicate
/// that decides which Setup cards to render and in what order.
final class WatchtowerSetupSectionLogicTests: XCTestCase {

    // MARK: - All configured → empty

    func testVisible_allConfigured_returnsEmpty() {
        let visible = WatchtowerSetupSection.visibleTips(
            llmReachable: true,
            exploratorySearchEnabled: true,
            visionConfigured: true,
            dictationLocalesEmpty: false,
            dismissed: []
        )
        XCTAssertTrue(visible.isEmpty)
    }

    // MARK: - Nothing configured → all four in shelf order

    func testVisible_noneConfigured_returnsAllInShelfOrder() {
        let visible = WatchtowerSetupSection.visibleTips(
            llmReachable: false,
            exploratorySearchEnabled: false,
            visionConfigured: false,
            dictationLocalesEmpty: true,
            dismissed: []
        )
        XCTAssertEqual(visible, [.llm, .exploratorySearch, .vision, .dictation])
    }

    // MARK: - Per-tip predicates

    func testVisible_llmReachable_hidesLLMCardOnly() {
        let visible = WatchtowerSetupSection.visibleTips(
            llmReachable: true,
            exploratorySearchEnabled: false,
            visionConfigured: false,
            dictationLocalesEmpty: true,
            dismissed: []
        )
        XCTAssertEqual(visible, [.exploratorySearch, .vision, .dictation])
    }

    func testVisible_exploratorySearchEnabled_hidesSearchCardOnly() {
        let visible = WatchtowerSetupSection.visibleTips(
            llmReachable: false,
            exploratorySearchEnabled: true,
            visionConfigured: false,
            dictationLocalesEmpty: true,
            dismissed: []
        )
        XCTAssertEqual(visible, [.llm, .vision, .dictation])
    }

    func testVisible_visionConfigured_hidesVisionCardOnly() {
        let visible = WatchtowerSetupSection.visibleTips(
            llmReachable: false,
            exploratorySearchEnabled: false,
            visionConfigured: true,
            dictationLocalesEmpty: true,
            dismissed: []
        )
        XCTAssertEqual(visible, [.llm, .exploratorySearch, .dictation])
    }

    func testVisible_dictationLocaleConfigured_hidesDictationCardOnly() {
        // dictationLocalesEmpty: false means the user has selected at least one locale
        let visible = WatchtowerSetupSection.visibleTips(
            llmReachable: false,
            exploratorySearchEnabled: false,
            visionConfigured: false,
            dictationLocalesEmpty: false,
            dismissed: []
        )
        XCTAssertEqual(visible, [.llm, .exploratorySearch, .vision])
    }

    // MARK: - Dismiss interactions

    func testVisible_dismissedTip_isHidden() {
        let visible = WatchtowerSetupSection.visibleTips(
            llmReachable: false,
            exploratorySearchEnabled: false,
            visionConfigured: false,
            dictationLocalesEmpty: true,
            dismissed: ["llm"]
        )
        XCTAssertEqual(visible, [.exploratorySearch, .vision, .dictation])
    }

    func testVisible_dismissedAndConfigured_compose() {
        // Two cards hidden via configure, two via dismiss → empty
        let visible = WatchtowerSetupSection.visibleTips(
            llmReachable: true,
            exploratorySearchEnabled: false,
            visionConfigured: false,
            dictationLocalesEmpty: false,
            dismissed: ["exploratorySearch", "vision"]
        )
        XCTAssertTrue(visible.isEmpty)
    }

    func testVisible_unknownDismissedID_doesNotAffectKnownTips() {
        // A future tip ID dismissed by a newer build must not accidentally
        // hide a current tip just because the set is non-empty.
        let visible = WatchtowerSetupSection.visibleTips(
            llmReachable: false,
            exploratorySearchEnabled: true,
            visionConfigured: true,
            dictationLocalesEmpty: false,
            dismissed: ["unknown_future_tip"]
        )
        XCTAssertEqual(visible, [.llm])
    }

    // MARK: - Copy

    func testCopy_eachTipHasNonEmptyContent() {
        for tip in FeatureTipID.allCases {
            let copy = WatchtowerSetupSection.copy(for: tip)
            XCTAssertFalse(copy.icon.isEmpty, "\(tip) icon empty")
            XCTAssertFalse(copy.title.isEmpty, "\(tip) title empty")
            XCTAssertFalse(copy.description.isEmpty, "\(tip) description empty")
        }
    }

    func testCopy_eachTipMapsToCorrectSettingsTab() {
        XCTAssertEqual(WatchtowerSetupSection.copy(for: .llm).tab, .llm)
        XCTAssertEqual(WatchtowerSetupSection.copy(for: .exploratorySearch).tab, .exploratorySearch)
        XCTAssertEqual(WatchtowerSetupSection.copy(for: .vision).tab, .vision)
        XCTAssertEqual(WatchtowerSetupSection.copy(for: .dictation).tab, .dictation)
    }
}
