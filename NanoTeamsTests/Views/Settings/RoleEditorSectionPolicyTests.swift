import XCTest
@testable import NanoTeams

/// Pins the pure section-visibility + ask_supervisor-injection policy behind
/// `RoleEditorSheet`. The managed singleton (Autovisor) exposes only Prompt + Tools,
/// the Supervisor only General + Dependencies, and the manager must never be shown
/// `ask_supervisor` as auto-injected (runtime excludes it).
final class RoleEditorSectionPolicyTests: XCTestCase {

    // MARK: - availableSections

    func testAvailableSections_supervisor() {
        XCTAssertEqual(
            RoleEditorSectionPolicy.availableSections(isSupervisor: true, isManagedSingleton: false),
            [.general, .dependencies]
        )
    }

    func testAvailableSections_managedSingletonManager() {
        XCTAssertEqual(
            RoleEditorSectionPolicy.availableSections(isSupervisor: false, isManagedSingleton: true),
            [.prompt, .tools]
        )
    }

    func testAvailableSections_supervisorWins_overManagedSingleton() {
        // A managed-singleton Supervisor is still General + Dependencies (isSupervisor first).
        XCTAssertEqual(
            RoleEditorSectionPolicy.availableSections(isSupervisor: true, isManagedSingleton: true),
            [.general, .dependencies]
        )
    }

    func testAvailableSections_normalRole_full() {
        XCTAssertEqual(
            RoleEditorSectionPolicy.availableSections(isSupervisor: false, isManagedSingleton: false),
            RoleSection.allCases
        )
    }

    // MARK: - initialSection

    func testInitialSection_defaultNotAvailable_fallsBackToFirst() {
        // Manager: default .general isn't offered → open on the first available (.prompt).
        XCTAssertEqual(
            RoleEditorSectionPolicy.initialSection(defaultSection: .general, available: [.prompt, .tools]),
            .prompt
        )
    }

    func testInitialSection_defaultAvailable_kept() {
        XCTAssertEqual(
            RoleEditorSectionPolicy.initialSection(defaultSection: .general, available: RoleSection.allCases),
            .general
        )
        XCTAssertEqual(
            RoleEditorSectionPolicy.initialSection(defaultSection: .general, available: [.general, .dependencies]),
            .general
        )
    }

    // MARK: - injectsAskSupervisor

    func testInjectsAskSupervisor() {
        XCTAssertFalse(RoleEditorSectionPolicy.injectsAskSupervisor(isManagedSingleton: true),
                       "manager IS the top Supervisor — never auto-injected ask_supervisor")
        XCTAssertTrue(RoleEditorSectionPolicy.injectsAskSupervisor(isManagedSingleton: false))
    }
}
