import XCTest

@testable import NanoTeams

/// The 4 modes × 2 presence answers of each approval-gated family, plus the pair type the
/// resolver, badge, preview and renderer thread. B3 (2026-09-07): `bash` shipped to runs
/// where every call was refused because nothing read the mode against presence.
final class ApprovalGatedAvailabilityTests: XCTestCase {

    // MARK: - bash

    func testBash_off_isWithheldSwitchedOff_whoeverIsPresent() {
        XCTAssertEqual(ApprovalGatedAvailability.forBash(mode: .off, humanPresent: true), .withheld(.switchedOff))
        XCTAssertEqual(ApprovalGatedAvailability.forBash(mode: .off, humanPresent: false), .withheld(.switchedOff))
    }

    /// Manual asks ABOVE the read-only bypass (`BashPermissionService` step 1b): with no
    /// human, even `ls` waits forever — so the whole tool is withheld.
    func testBash_manual_isAvailableWithAHuman_withheldWithout() {
        XCTAssertEqual(ApprovalGatedAvailability.forBash(mode: .manual, humanPresent: true), .available)
        XCTAssertEqual(ApprovalGatedAvailability.forBash(mode: .manual, humanPresent: false), .withheld(.noApprover))
    }

    /// Semi-automatic runs read-only commands without asking: the tool stays, the rest is
    /// refused per command.
    func testBash_semiAutomatic_isAvailableWithAHuman_readOnlyWithout() {
        XCTAssertEqual(ApprovalGatedAvailability.forBash(mode: .semiAutomatic, humanPresent: true), .available)
        XCTAssertEqual(ApprovalGatedAvailability.forBash(mode: .semiAutomatic, humanPresent: false), .readOnlyUnattended)
    }

    func testBash_auto_isAvailable_whoeverIsPresent() {
        XCTAssertEqual(ApprovalGatedAvailability.forBash(mode: .auto, humanPresent: true), .available)
        XCTAssertEqual(ApprovalGatedAvailability.forBash(mode: .auto, humanPresent: false), .available)
    }

    // MARK: - computer-use

    func testComputerUse_off_isWithheldSwitchedOff_whoeverIsPresent() {
        XCTAssertEqual(ApprovalGatedAvailability.forComputerUse(mode: .off, humanPresent: true), .withheld(.switchedOff))
        XCTAssertEqual(ApprovalGatedAvailability.forComputerUse(mode: .off, humanPresent: false), .withheld(.switchedOff))
    }

    /// Manual confirms the FIRST capture with the human, and a refused capture never counts
    /// as having occurred: with no human there is never a screenshot, so all five are dead.
    func testComputerUse_manual_isAvailableWithAHuman_withheldWithout() {
        XCTAssertEqual(ApprovalGatedAvailability.forComputerUse(mode: .manual, humanPresent: true), .available)
        XCTAssertEqual(ApprovalGatedAvailability.forComputerUse(mode: .manual, humanPresent: false), .withheld(.noApprover))
    }

    func testComputerUse_semiAutomatic_isAvailableWithAHuman_readOnlyWithout() {
        XCTAssertEqual(ApprovalGatedAvailability.forComputerUse(mode: .semiAutomatic, humanPresent: true), .available)
        XCTAssertEqual(ApprovalGatedAvailability.forComputerUse(mode: .semiAutomatic, humanPresent: false), .readOnlyUnattended)
    }

    func testComputerUse_auto_isAvailable_whoeverIsPresent() {
        XCTAssertEqual(ApprovalGatedAvailability.forComputerUse(mode: .auto, humanPresent: true), .available)
        XCTAssertEqual(ApprovalGatedAvailability.forComputerUse(mode: .auto, humanPresent: false), .available)
    }

    /// Exhaustive: 4 + 4 modes, every one classified above. A mode added later must get a row.
    func testEveryModeIsClassified() {
        XCTAssertEqual(BashExecutionMode.allCases.count, 4)
        XCTAssertEqual(ComputerUseMode.allCases.count, 4)
    }

    func testIsWithheld_isTrueForBothReasonsOnly() {
        XCTAssertTrue(ApprovalGatedAvailability.withheld(.switchedOff).isWithheld)
        XCTAssertTrue(ApprovalGatedAvailability.withheld(.noApprover).isWithheld)
        XCTAssertFalse(ApprovalGatedAvailability.readOnlyUnattended.isWithheld)
        XCTAssertFalse(ApprovalGatedAvailability.available.isWithheld)
    }

    // MARK: - The pair

    func testPair_readsBothFamiliesAgainstOnePresenceAnswer() {
        let unattended = ToolApprovalAvailability(bashMode: .manual, computerUseMode: .semiAutomatic, humanPresent: false)
        XCTAssertEqual(unattended.bash, .withheld(.noApprover))
        XCTAssertEqual(unattended.computerUse, .readOnlyUnattended)

        let attended = ToolApprovalAvailability(bashMode: .manual, computerUseMode: .semiAutomatic, humanPresent: true)
        XCTAssertEqual(attended, .available)
    }

    func testAvailable_isAHumanWithBothFamiliesOn() {
        XCTAssertEqual(ToolApprovalAvailability.available,
                       ToolApprovalAvailability(bash: .available, computerUse: .available))
    }

    // MARK: - forTeam: the folder-level reading

    private func team(supervisorMode: SupervisorMode) -> Team {
        var team = TeamTemplateFactory.startup()
        team.settings.supervisorMode = supervisorMode
        return team
    }

    private func settings(autovisorEnabled: Bool, onTaskNeedsSupervisor: Bool) -> ProjectSettings {
        var activation = AutovisorActivation.default
        activation.onTaskNeedsSupervisor = onTaskNeedsSupervisor
        return ProjectSettings(autovisorEnabled: autovisorEnabled, autovisorActivation: activation)
    }

    func testForTeam_manualTeam_noAutovisor_isAvailable() {
        let a = ToolApprovalAvailability.forTeam(
            bashMode: .manual, computerUseMode: .manual,
            team: team(supervisorMode: .manual), workFolderSettings: settings(autovisorEnabled: false, onTaskNeedsSupervisor: true))
        XCTAssertEqual(a, .available)
    }

    func testForTeam_autonomousTeam_withholdsBothManualFamilies() {
        let a = ToolApprovalAvailability.forTeam(
            bashMode: .manual, computerUseMode: .manual,
            team: team(supervisorMode: .autonomous), workFolderSettings: settings(autovisorEnabled: false, onTaskNeedsSupervisor: true))
        XCTAssertEqual(a.bash, .withheld(.noApprover))
        XCTAssertEqual(a.computerUse, .withheld(.noApprover))
    }

    /// The manager supervises the folder's top-level tasks only when enabled AND armed for
    /// "needs supervisor" — the same two facts `AutovisorPolicy.supervisesTask` reads.
    func testForTeam_autovisorSupervisingTheFolder_isNobody_evenForAManualTeam() {
        let supervised = ToolApprovalAvailability.forTeam(
            bashMode: .manual, computerUseMode: .semiAutomatic,
            team: team(supervisorMode: .manual), workFolderSettings: settings(autovisorEnabled: true, onTaskNeedsSupervisor: true))
        XCTAssertEqual(supervised.bash, .withheld(.noApprover))
        XCTAssertEqual(supervised.computerUse, .readOnlyUnattended)

        let enabledButNotArmed = ToolApprovalAvailability.forTeam(
            bashMode: .manual, computerUseMode: .semiAutomatic,
            team: team(supervisorMode: .manual), workFolderSettings: settings(autovisorEnabled: true, onTaskNeedsSupervisor: false))
        XCTAssertEqual(enabledButNotArmed, .available, "enabled without the trigger supervises nothing")
    }

    /// No team reads as the fresh-team default (`.manual` Supervisor); no settings as no Autovisor.
    func testForTeam_nilTeamAndNilSettings_readAsAHumanPresent() {
        XCTAssertEqual(
            ToolApprovalAvailability.forTeam(bashMode: .manual, computerUseMode: .manual, team: nil, workFolderSettings: nil),
            .available)
    }

    func testSupervisesTopLevelTasks_matchesSupervisesTaskForAnOrdinaryTopLevelTask() {
        for enabled in [true, false] {
            for armed in [true, false] {
                var activation = AutovisorActivation.default
                activation.onTaskNeedsSupervisor = armed
                XCTAssertEqual(
                    AutovisorPolicy.supervisesTopLevelTasks(autovisorEnabled: enabled, activation: activation),
                    AutovisorPolicy.supervisesTask(
                        taskID: 7, parentTaskID: nil, autovisorEnabled: enabled, activation: activation, autovisorTaskID: 1),
                    "enabled=\(enabled) armed=\(armed)")
            }
        }
    }
}
