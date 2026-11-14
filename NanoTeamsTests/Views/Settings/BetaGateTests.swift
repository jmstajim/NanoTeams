import XCTest

@testable import NanoTeams

/// The screen that stands in front of `External Agents` and `MCP Servers`: what it says, that each
/// feature is acknowledged on its own, and that nothing reaches either tab around it.
@MainActor
final class BetaGateTests: XCTestCase {

    private var storage: BetaGateInMemoryStorage!
    private var config: StoreConfiguration!

    override func setUp() async throws {
        try await super.setUp()
        storage = BetaGateInMemoryStorage()
        config = StoreConfiguration(storage: storage)
    }

    override func tearDown() async throws {
        config = nil
        storage = nil
        try await super.tearDown()
    }

    // MARK: - What it says

    /// Every feature has its own copy, and none of it is placeholder. A gate whose text was
    /// forgotten is worse than no gate: it is a click-through that teaches people to click.
    func testEveryBetaFeatureHasItsOwnFilledInCopy() {
        for feature in BetaFeature.allCases {
            let copy = BetaGateCopy.copy(for: feature)
            XCTAssertFalse(copy.title.isEmpty, "\(feature)")
            XCTAssertFalse(copy.icon.isEmpty, "\(feature)")
            XCTAssertFalse(copy.whatItDoes.isEmpty, "\(feature)")
            XCTAssertFalse(copy.buttonTitle.isEmpty, "\(feature)")
            XCTAssertGreaterThanOrEqual(copy.risks.count, 2, "\(feature) names too little to decide on")
            XCTAssertTrue(copy.risks.allSatisfy { !$0.isEmpty }, "\(feature)")
        }
    }

    /// The two gates must not be the same gate with a different heading. They guard opposite
    /// directions — one hosts a server others connect to, the other connects this app to servers
    /// someone else runs — and a person accepting one has not been told about the other.
    func testTheTwoFeaturesWarnAboutDifferentThings() {
        let agent = BetaGateCopy.copy(for: .externalAgents)
        let servers = BetaGateCopy.copy(for: .mcpServers)
        XCTAssertNotEqual(agent.title, servers.title)
        XCTAssertNotEqual(agent.whatItDoes, servers.whatItDoes)
        XCTAssertTrue(
            Set(agent.risks).isDisjoint(with: Set(servers.risks)),
            "a risk copied between the two is boilerplate, not a warning")
    }

    /// The three things that make the paragraph a disclaimer rather than a description: the
    /// software is given as it stands, nothing is promised about it, and nobody is on the hook
    /// for what it does. Said in words a person without a lawyer can read.
    func testTheDisclaimerDisclaimsTheThreeThingsItHasTo() {
        let text = BetaGateCopy.disclaimer
        for phrase in ["as is", "without warranty", "no liability", "beta"] {
            XCTAssertTrue(
                text.localizedCaseInsensitiveContains(phrase),
                "the disclaimer never says \"\(phrase)\": \(text)")
        }
        XCTAssertTrue(text.localizedCaseInsensitiveContains("responsible"), text)
    }

    // MARK: - The acknowledgement

    func testNothingIsAcknowledgedOnAFreshInstall() {
        for feature in BetaFeature.allCases {
            XCTAssertFalse(config.hasAcknowledgedBeta(feature), "\(feature)")
        }
    }

    /// Per feature, not per app. Accepting the inbound server says nothing about the third-party
    /// servers the person may connect later.
    func testAcknowledgingOneFeatureLeavesTheOtherGated() {
        config.acknowledgeBeta(.externalAgents)
        XCTAssertTrue(config.hasAcknowledgedBeta(.externalAgents))
        XCTAssertFalse(config.hasAcknowledgedBeta(.mcpServers))
    }

    func testAnAcknowledgementSurvivesARelaunch() {
        config.acknowledgeBeta(.mcpServers)
        let reread = StoreConfiguration(storage: storage)
        XCTAssertTrue(reread.hasAcknowledgedBeta(.mcpServers))
        XCTAssertFalse(reread.hasAcknowledgedBeta(.externalAgents))
    }

    func testAcknowledgingTwiceWritesNothingNew() {
        config.acknowledgeBeta(.externalAgents)
        config.acknowledgeBeta(.externalAgents)
        XCTAssertEqual(config.acknowledgedBetaFeatures, [BetaFeature.externalAgents.rawValue])
    }

    /// The whole recipe for a stored setting: reset removes the key AND puts the live value back.
    /// A reset that only did the first leaves the gate down until relaunch.
    func testResetToDefaultsClearsBothTheStoredKeyAndTheLiveValue() {
        config.acknowledgeBeta(.externalAgents)
        config.acknowledgeBeta(.mcpServers)

        config.resetToDefaults()

        XCTAssertTrue(config.acknowledgedBetaFeatures.isEmpty, "the live value stayed")
        XCTAssertNil(storage.object(forKey: UserDefaultsKeys.acknowledgedBetaFeatures), "the key stayed")
        let reread = StoreConfiguration(storage: storage)
        for feature in BetaFeature.allCases {
            XCTAssertFalse(reread.hasAcknowledgedBeta(feature), "\(feature)")
        }
    }

    /// An unknown id in storage — a feature that has left beta, or a downgrade — is carried
    /// rather than rejected, and gates nothing.
    func testAnUnknownStoredIdIsHarmless() {
        storage.set(["somethingRetired"], forKey: UserDefaultsKeys.acknowledgedBetaFeatures)
        let reread = StoreConfiguration(storage: storage)
        for feature in BetaFeature.allCases {
            XCTAssertFalse(reread.hasAcknowledgedBeta(feature), "\(feature)")
        }
    }

    // MARK: - There is no way around it

    /// The gate wraps the tab at the Settings window's DISPATCH, so a second entry point into
    /// either tab cannot be written that skips it. Checked against the source because that is the
    /// property — "this screen is unreachable without the gate" — and no runtime assertion states it.
    func testBothTabsAreGatedAtTheDispatch() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Settings
            .deletingLastPathComponent()  // Views
            .deletingLastPathComponent()  // NanoTeamsTests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("NanoTeams/Views/Settings/SettingsView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        // The gate is spelled by its CASE name, which is not its raw value: `.externalAgents` is
        // stored as "agentAccess", the tab's name before 2026-11-08.
        for (tabCase, view, gateCall) in [
            ("case .externalAgents:", "ExternalAgentsSettingsView", "BetaGate(feature: .externalAgents)"),
            ("case .mcpServers:", "MCPServersSettingsView", "BetaGate(feature: .mcpServers)"),
        ] {
            let arm = try XCTUnwrap(source.range(of: tabCase)).upperBound
            let tail = String(source[arm...].prefix(400))
            let gate = try XCTUnwrap(tail.range(of: gateCall), "\(tabCase) is not behind its gate")
            let content = try XCTUnwrap(tail.range(of: view), "\(view) left the dispatch")
            XCTAssertTrue(
                gate.lowerBound < content.lowerBound,
                "\(view) is rendered before its gate, so the gate guards nothing")
        }
    }
}

private final class BetaGateInMemoryStorage: ConfigurationStorage {
    private var store: [String: Any] = [:]

    func string(forKey key: String) -> String? { store[key] as? String }
    func bool(forKey key: String) -> Bool { store[key] as? Bool ?? false }
    func data(forKey key: String) -> Data? { store[key] as? Data }
    func object(forKey key: String) -> Any? { store[key] }
    func set(_ value: Any?, forKey key: String) { store[key] = value }
    func removeObject(forKey key: String) { store.removeValue(forKey: key) }
}
