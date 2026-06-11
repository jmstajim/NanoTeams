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
            autovisorEnabled: true,
            hasWorkFolder: true,
            dismissed: []
        )
        XCTAssertTrue(visible.isEmpty)
    }

    // MARK: - Nothing configured → all five in shelf order

    func testVisible_noneConfigured_returnsAllInShelfOrder() {
        let visible = WatchtowerSetupSection.visibleTips(
            llmReachable: false,
            exploratorySearchEnabled: false,
            visionConfigured: false,
            dictationLocalesEmpty: true,
            autovisorEnabled: false,
            hasWorkFolder: true,
            dismissed: []
        )
        XCTAssertEqual(visible, [.llm, .exploratorySearch, .vision, .dictation, .autovisor])
    }

    // MARK: - Per-tip predicates
    // (Autovisor held hidden — autovisorEnabled: true, hasWorkFolder: false —
    //  so each case isolates the tip under test.)

    func testVisible_llmReachable_hidesLLMCardOnly() {
        let visible = WatchtowerSetupSection.visibleTips(
            llmReachable: true,
            exploratorySearchEnabled: false,
            visionConfigured: false,
            dictationLocalesEmpty: true,
            autovisorEnabled: true,
            hasWorkFolder: false,
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
            autovisorEnabled: true,
            hasWorkFolder: false,
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
            autovisorEnabled: true,
            hasWorkFolder: false,
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
            autovisorEnabled: true,
            hasWorkFolder: false,
            dismissed: []
        )
        XCTAssertEqual(visible, [.llm, .exploratorySearch, .vision])
    }

    // MARK: - Autovisor predicate

    func testVisible_autovisorNeedsSetup_appendsCardLast() {
        // Everything else configured; FM off with a real work folder → only FM shows.
        let visible = WatchtowerSetupSection.visibleTips(
            llmReachable: true,
            exploratorySearchEnabled: true,
            visionConfigured: true,
            dictationLocalesEmpty: false,
            autovisorEnabled: false,
            hasWorkFolder: true,
            dismissed: []
        )
        XCTAssertEqual(visible, [.autovisor])
    }

    func testVisible_autovisor_hiddenWhenNoWorkFolder() {
        // Default storage / no real folder → FM card never shows even when off.
        let visible = WatchtowerSetupSection.visibleTips(
            llmReachable: true,
            exploratorySearchEnabled: true,
            visionConfigured: true,
            dictationLocalesEmpty: false,
            autovisorEnabled: false,
            hasWorkFolder: false,
            dismissed: []
        )
        XCTAssertTrue(visible.isEmpty)
    }

    func testVisible_autovisor_hiddenWhenEnabled() {
        // Once FM is on it's "set up" → card disappears.
        let visible = WatchtowerSetupSection.visibleTips(
            llmReachable: true,
            exploratorySearchEnabled: true,
            visionConfigured: true,
            dictationLocalesEmpty: false,
            autovisorEnabled: true,
            hasWorkFolder: true,
            dismissed: []
        )
        XCTAssertTrue(visible.isEmpty)
    }

    func testVisible_autovisorDismissed_isHidden() {
        let visible = WatchtowerSetupSection.visibleTips(
            llmReachable: true,
            exploratorySearchEnabled: true,
            visionConfigured: true,
            dictationLocalesEmpty: false,
            autovisorEnabled: false,
            hasWorkFolder: true,
            dismissed: ["autovisor"]
        )
        XCTAssertTrue(visible.isEmpty)
    }

    // MARK: - Dismiss interactions

    func testVisible_dismissedTip_isHidden() {
        let visible = WatchtowerSetupSection.visibleTips(
            llmReachable: false,
            exploratorySearchEnabled: false,
            visionConfigured: false,
            dictationLocalesEmpty: true,
            autovisorEnabled: true,
            hasWorkFolder: false,
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
            autovisorEnabled: true,
            hasWorkFolder: false,
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
            autovisorEnabled: true,
            hasWorkFolder: false,
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
        XCTAssertEqual(WatchtowerSetupSection.copy(for: .autovisor).tab, .autovisor)
    }
}
