import XCTest
@testable import NanoTeams

/// Pins the pure section-visibility + ask_supervisor-injection policy behind
/// `RoleEditorSheet`. The managed singleton (Autovisor) exposes Prompt + Tools +
/// Skills, the Supervisor only General + Dependencies, and the manager must never
/// be shown `ask_supervisor` as auto-injected (runtime excludes it).
final class RoleEditorSectionPolicyTests: XCTestCase {

    // MARK: - availableSections

    func testAvailableSections_supervisor() {
        XCTAssertEqual(
            RoleEditorSectionPolicy.availableSections(isSupervisor: true, isManagedSingleton: false),
            [.general, .dependencies]
        )
    }

    /// The manager gains Skills: it runs a step template like any other role, and
    /// `syncAutovisorTeamToTemplate` touches only `icon`/`toolIDs`, so attachments
    /// survive every work-folder open. Identity / dependencies / delegation stay
    /// hidden — those are structural and template-owned.
    func testAvailableSections_managedSingletonManager() {
        XCTAssertEqual(
            RoleEditorSectionPolicy.availableSections(isSupervisor: false, isManagedSingleton: true),
            [.prompt, .tools, .skills]
        )
    }

    /// The Supervisor is the user, not an LLM — it has no system prompt, so there
    /// is nowhere for a skill to land.
    func testAvailableSections_supervisor_excludesSkills() {
        XCTAssertFalse(
            RoleEditorSectionPolicy
                .availableSections(isSupervisor: true, isManagedSingleton: false)
                .contains(.skills)
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

    // `injectsAskSupervisor` was retired: the Tools tab now asks the real resolver
    // (`RoleEditorSheet.autoInjectedToolNames`) instead of restating step 4/8 here.
    // The Autovisor strip is pinned on the resolver side by
    // `AutovisorAskSupervisorGateTests`.
}
