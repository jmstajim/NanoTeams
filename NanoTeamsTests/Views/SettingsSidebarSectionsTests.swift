import XCTest
@testable import NanoTeams

/// Pins the Settings sidebar grouping (`SettingsView.sidebarSections`) — the single
/// source of truth for section membership, titles, and ordering.
///
/// The coverage invariant is the load-bearing guard: the detail `switch` in
/// `settingsContent` is exhaustive (a new `SettingsTab` case forces a compile error),
/// but nothing else forces a new tab to APPEAR in the sidebar — without this test a
/// new tab could ship with content that is unreachable from the UI.
final class SettingsSidebarSectionsTests: XCTestCase {

    private typealias Tab = SettingsView.SettingsTab

    // MARK: - Coverage invariant

    func testCoverage_everyTabAppearsExactlyOnce() {
        let placed = SettingsView.sidebarSections.flatMap(\.tabs)
        XCTAssertEqual(placed.count, Tab.allCases.count, "A tab is missing from or duplicated in the sidebar sections")
        XCTAssertEqual(Set(placed), Set(Tab.allCases), "Sidebar sections must place every SettingsTab exactly once")
    }

    // MARK: - Section titles & order

    func testSectionTitles_andOrder() {
        XCTAssertEqual(
            SettingsView.sidebarSections.map(\.title),
            [nil, "Workspace", "Models", "Agent Tools", "Application", "Support"]
        )
    }

    // MARK: - Membership & in-section order

    func testSectionMembership_andInSectionOrder() {
        let sections = SettingsView.sidebarSections
        XCTAssertEqual(sections.count, 6)
        guard sections.count == 6 else { return }

        XCTAssertEqual(sections[0].tabs, [.updates]) // pinned, header-less, at the very top
        XCTAssertEqual(sections[1].tabs, [.workFolder, .autovisor, .teams, .generateTeam])
        XCTAssertEqual(sections[2].tabs, [.llm, .vision, .exploratorySearch])
        XCTAssertEqual(sections[3].tabs, [.bash, .computerUse, .toolBehavior, .tools])
        XCTAssertEqual(sections[4].tabs, [.general, .theme, .dictation])
        XCTAssertEqual(sections[5].tabs, [.debug, .help])
    }

    /// Updates is a pinned, header-less section at the top.
    func testPinnedSection_isFirst_headerLess_updatesOnly() {
        let first = SettingsView.sidebarSections.first
        XCTAssertNil(first?.title, "The pinned top section must have no header")
        XCTAssertEqual(first?.tabs, [.updates])
    }

    // MARK: - Corner cases

    /// `SettingsSection.id` is an explicit stable slug; duplicates would collide in `ForEach` (rule #22).
    func testSectionIDs_areUnique() {
        let ids = SettingsView.sidebarSections.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Section IDs double as ForEach IDs and must be unique")
    }

    /// Anti-grab-bag guard: titled sections stay 2–5 tabs (the old "Advanced" was 7).
    /// The header-less pinned section is exempt (it's a single quick-access row by design).
    func testTitledSectionSizes_betweenTwoAndFive() {
        for section in SettingsView.sidebarSections where section.title != nil {
            XCTAssertTrue(
                (2...5).contains(section.tabs.count),
                "Titled section \(section.title ?? "") has \(section.tabs.count) tabs — must stay between 2 and 5"
            )
        }
    }

    /// No section may be empty.
    func testNoSectionIsEmpty() {
        for section in SettingsView.sidebarSections {
            XCTAssertFalse(section.tabs.isEmpty, "Section \(section.id) is empty")
        }
    }

    /// Present titles feed `MonoLabel` directly — leading/trailing whitespace or empty strings would render visibly.
    func testSectionTitles_nonEmptyAndTrimmed() {
        for case let title? in SettingsView.sidebarSections.map(\.title) {
            XCTAssertFalse(title.isEmpty)
            XCTAssertEqual(title, title.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
