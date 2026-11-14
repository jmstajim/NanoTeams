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
            [nil, "Workspace", "Capabilities", "Agent Tools", "Application", "Support"]
        )
    }

    // MARK: - Membership & in-section order

    func testSectionMembership_andInSectionOrder() {
        let sections = SettingsView.sidebarSections
        XCTAssertEqual(sections.count, 6)
        guard sections.count == 6 else { return }

        XCTAssertEqual(sections[0].tabs, [.updates, .llm]) // pinned, header-less, at the very top
        XCTAssertEqual(sections[1].tabs, [.workFolder, .teams, .autovisor])
        // External Agents is a capability the app switches on — an external agent may drive it —
        // app-wide like the other three (its port and agents live in StoreConfiguration), not
        // the work folder's; Agent Tools is at its five-tab cap, and it is no app-shell
        // preference (it sat under Application until 2026-11-08).
        XCTAssertEqual(sections[2].tabs, [.vision, .exploratorySearch, .generateTeam, .externalAgents])
        XCTAssertEqual(sections[3].tabs, [.bash, .computerUse, .toolBehavior, .tools, .mcpServers])
        XCTAssertEqual(sections[4].tabs, [.general, .theme, .dictation])
        XCTAssertEqual(sections[5].tabs, [.benchmark, .debug, .help])
    }

    /// Updates + LLM are pinned, header-less, at the top.
    func testPinnedSection_isFirst_headerLess_updatesThenLLM() {
        let first = SettingsView.sidebarSections.first
        XCTAssertNil(first?.title, "The pinned top section must have no header")
        XCTAssertEqual(first?.tabs, [.updates, .llm])
    }

    // MARK: - Corner cases

    /// `SettingsSection.id` is an explicit stable slug; duplicates would collide in `ForEach` (rule #22).
    func testSectionIDs_areUnique() {
        let ids = SettingsView.sidebarSections.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Section IDs double as ForEach IDs and must be unique")
    }

    /// Anti-grab-bag guard: titled sections stay 2–5 tabs (the old "Advanced" was 7).
    /// The header-less pinned section is exempt by design — its own cap lives in
    /// `testPinnedSection_staysAtMostTwoTabs`.
    func testTitledSectionSizes_betweenTwoAndFive() {
        for section in SettingsView.sidebarSections where section.title != nil {
            XCTAssertTrue(
                (2...5).contains(section.tabs.count),
                "Titled section \(section.title ?? "") has \(section.tabs.count) tabs — must stay between 2 and 5"
            )
        }
    }

    /// The pinned group is EXEMPT from `testTitledSectionSizes_betweenTwoAndFive` (that guard
    /// filters on `title != nil`), so without this it is the one section that could grow without
    /// limit — which is exactly how it would stop reading as "pinned quick access".
    func testPinnedSection_staysAtMostTwoTabs() {
        let first = SettingsView.sidebarSections.first
        XCTAssertLessThanOrEqual(
            first?.tabs.count ?? 0, 2,
            "The pinned header-less group must stay at most 2 tabs — anything more is a section and needs a header"
        )
    }

    /// A header-less section renders with no `MonoLabel` separator, so a second one would visually
    /// merge into its predecessor's list. Exactly one may exist, and it must be the pinned first.
    func testExactlyOneSection_isHeaderLess() {
        let headerLess = SettingsView.sidebarSections.filter { $0.title == nil }
        XCTAssertEqual(headerLess.count, 1, "Only the pinned top group may be header-less — a second one merges into the section above it")
        XCTAssertEqual(headerLess.first?.id, SettingsView.sidebarSections.first?.id, "The header-less section must be the first one")
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

    // MARK: - Tab names and subtitles

    /// The tab external agents connect through is named for them, and its second line says who
    /// uses whom: "Agent Access" alone read as what this app's own roles may reach (cold read
    /// 2026-11-08, 3 of 3), and "External Agents" alone still split on the direction (1 of 3).
    func testExternalAgents_isNamedForThem_andItsSubtitleSaysWhoUsesWhom() {
        let tab = SettingsView.SettingsTab.externalAgents
        XCTAssertEqual(tab.rawValue, "External Agents")
        XCTAssertEqual(tab.subtitle, "Let Claude Code, Codex… use NanoTeams")
    }

    /// A subtitle is for a name that reads the wrong way round, not decoration: one tab has
    /// one. The LLM row's second line is its own live state, not this table's.
    func testOnlyExternalAgents_carriesAStaticSubtitle() {
        XCTAssertEqual(SettingsView.SettingsTab.allCases.filter { $0.subtitle != nil }, [.externalAgents])
    }

    /// A subtitle is trimmed text with no line break of its own — the row wraps it — so an edge
    /// space or a newline cannot render as a gap.
    func testSubtitles_areTrimmed_withNoLineBreakOfTheirOwn() {
        for tab in SettingsView.SettingsTab.allCases {
            guard let subtitle = tab.subtitle else { continue }
            XCTAssertFalse(subtitle.isEmpty, "\(tab)")
            XCTAssertEqual(subtitle, subtitle.trimmingCharacters(in: .whitespacesAndNewlines), "\(tab)")
            XCTAssertFalse(subtitle.contains("\n"), "\(tab)")
        }
    }

    // MARK: - LLM hero row subtitle

    /// The hero row's second line shows the configured model when one is set.
    func testHeroSubtitle_showsModelName_whenConfigured() {
        XCTAssertEqual(SettingsLLMHeroRow.subtitle(modelName: "qwen3-30b", provider: .ollama), "qwen3-30b")
    }

    /// Before any model is picked the line falls back to the provider — never a blank line.
    func testHeroSubtitle_fallsBackToProviderDisplayName_whenModelNameEmpty() {
        XCTAssertEqual(SettingsLLMHeroRow.subtitle(modelName: "", provider: .lmStudio), "LM Studio")
        XCTAssertEqual(SettingsLLMHeroRow.subtitle(modelName: "", provider: .ollama), "Ollama")
    }

    /// Whitespace-only is "absent", not a model name — it would render as a blank line.
    func testHeroSubtitle_treatsWhitespaceOnlyModelNameAsAbsent() {
        XCTAssertEqual(SettingsLLMHeroRow.subtitle(modelName: "  \n\t", provider: .lmStudio), "LM Studio")
    }

    /// Edge whitespace on a real name is trimmed rather than rendered.
    func testHeroSubtitle_trimsModelNameEdges() {
        XCTAssertEqual(SettingsLLMHeroRow.subtitle(modelName: "  qwen3  ", provider: .ollama), "qwen3")
    }
}
