import XCTest
@testable import NanoTeams

/// Pure-logic tests for the `MeetingCoordinatorPickerLogic` namespace that backs the
/// Collaboration section's coordinator Picker. There is no "Auto" option: the `get`
/// side reads `Team.meetingCoordinatorID`, so a stored `nil` or orphan id shows the
/// role that will actually coordinate, and the `set` side never writes `nil`.
@MainActor
final class TeamSettingsCollaborationSectionLogicTests: XCTestCase {

    private func team(coordID: String?, roles: [String] = ["pm", "swe"]) -> Team {
        let supervisor = TeamRoleDefinition(
            id: "sup", name: "Supervisor", prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(), systemRoleID: "supervisor")
        let defs = roles.map {
            TeamRoleDefinition(id: $0, name: $0.uppercased(), prompt: "p", toolIDs: [],
                               usePlanningPhase: false, dependencies: RoleDependencies())
        }
        return Team(
            name: "T", roles: [supervisor] + defs, artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: coordID),
            graphLayout: TeamGraphLayout())
    }

    // MARK: - selection (get)

    func testSelection_storedMatchesARole_returnsStored() {
        XCTAssertEqual(MeetingCoordinatorPickerLogic.selection(for: team(coordID: "swe")), "swe")
    }

    /// Stored `nil` (a file from before coordinators became mandatory) shows the default
    /// rule's pick, never a blank or an "Auto".
    func testSelection_storedNil_returnsTheDefaultRulePick() {
        XCTAssertEqual(MeetingCoordinatorPickerLogic.selection(for: team(coordID: nil)), "pm")
    }

    /// An orphan (the picked role was removed) shows who coordinates now — the same
    /// answer the meeting runtime gives (`CoordinatorResolutionConsistencyTests`).
    func testSelection_storedOrphan_returnsTheDefaultRulePick() {
        XCTAssertEqual(
            MeetingCoordinatorPickerLogic.selection(for: team(coordID: "ghost-of-deleted-role")), "pm",
            "an orphan stored id must show the role that will actually coordinate")
    }

    func testSelection_storedEmptyString_returnsTheDefaultRulePick() {
        XCTAssertEqual(MeetingCoordinatorPickerLogic.selection(for: team(coordID: "")), "pm")
    }

    /// Nobody to coordinate ⇒ `nil`; the picker has no options either.
    func testSelection_rolelessTeam_returnsNil() {
        XCTAssertNil(MeetingCoordinatorPickerLogic.selection(for: team(coordID: nil, roles: [])))
    }

    // MARK: - sanitizedSelection (set)

    func testSanitizedSelection_validIDPassesThrough() {
        XCTAssertEqual(MeetingCoordinatorPickerLogic.sanitizedSelection("pm", current: "swe"), "pm")
    }

    /// An empty inbound value is a control glitch, not a pick: the stored id stays.
    /// `nil` used to mean Auto; writing it now would only be healed back on the next
    /// open, so it is never written.
    func testSanitizedSelection_emptyStringKeepsTheCurrentID() {
        XCTAssertEqual(MeetingCoordinatorPickerLogic.sanitizedSelection("", current: "swe"), "swe")
        XCTAssertEqual(MeetingCoordinatorPickerLogic.sanitizedSelection(nil, current: "swe"), "swe")
    }

    func testSanitizedSelection_emptyInboundWithNoCurrent_staysNil() {
        XCTAssertNil(MeetingCoordinatorPickerLogic.sanitizedSelection(nil, current: nil))
    }

    // MARK: - MeetingsSwitchPresentation

    /// `.noPartner` is the one footer that names `ask_teammate`: with no second role the
    /// consultation channel is as empty as the meeting one (`Team.hasTeammatePartner` —
    /// one partner rule for both). Until 2026-09-07 the footer stopped at meetings and
    /// `request_changes`, because the Supervisor seat still counted as somebody to consult.
    func testSwitchPresentation_showsOffAndLocksTheSwitch_whenThereIsNobodyToInvite() {
        XCTAssertFalse(MeetingsSwitchPresentation.isOn(for: .noPartner))
        XCTAssertFalse(MeetingsSwitchPresentation.isSwitchEnabled(for: .noPartner))
        let footer = MeetingsSwitchPresentation.footer(for: .noPartner)
        XCTAssertTrue(footer.contains("second role"))
        XCTAssertTrue(footer.contains("ask_teammate has nobody to reach"))
    }

    /// The switch governs meetings alone, so its footer must not claim consultations.
    func testSwitchPresentation_switchedOff_isOffButFlippable() {
        XCTAssertFalse(MeetingsSwitchPresentation.isOn(for: .switchedOff))
        XCTAssertTrue(MeetingsSwitchPresentation.isSwitchEnabled(for: .switchedOff))
        let footer = MeetingsSwitchPresentation.footer(for: .switchedOff)
        XCTAssertTrue(footer.hasPrefix("Meetings are off"))
        XCTAssertFalse(footer.contains("ask_teammate"),
                       "meetings off leaves ask_teammate alone — the footer must not say otherwise")
    }

    func testSwitchPresentation_available_isOnAndFlippable() {
        XCTAssertTrue(MeetingsSwitchPresentation.isOn(for: .available))
        XCTAssertTrue(MeetingsSwitchPresentation.isSwitchEnabled(for: .available))
        let footer = MeetingsSwitchPresentation.footer(for: .available)
        XCTAssertFalse(footer.contains("unavailable"))
        XCTAssertFalse(footer.contains("ask_teammate"), "with a partner there is nothing to warn about")
    }

    /// The presentation reads the same enum the runtime reads: a single-role team shows
    /// Off with the switch locked, a pair shows On. The helper seats a Supervisor on every
    /// roster, so "solo" is Supervisor + one role — and the Supervisor never counts as the
    /// partner. Until 2026-09-07 a `supervisorCanBeInvited` seat let it.
    func testSwitchPresentation_followsTheTeamsAvailability() {
        let solo = team(coordID: "pm", roles: ["pm"])
        XCTAssertFalse(solo.hasTeammatePartner, "the Supervisor is not a partner")
        XCTAssertEqual(solo.meetingAvailability, .noPartner)
        XCTAssertFalse(MeetingsSwitchPresentation.isOn(for: solo.meetingAvailability))
        let pair = team(coordID: "pm")
        XCTAssertTrue(pair.hasTeammatePartner)
        XCTAssertTrue(MeetingsSwitchPresentation.isOn(for: pair.meetingAvailability))
    }

    /// Supervisor alone: no partner, no meeting — the same `.noPartner` the solo team gets.
    func testSwitchPresentation_supervisorOnlyTeam_isNoPartner() {
        let none = team(coordID: nil, roles: [])
        XCTAssertFalse(none.hasTeammatePartner)
        XCTAssertEqual(none.meetingAvailability, .noPartner)
        XCTAssertFalse(MeetingsSwitchPresentation.isSwitchEnabled(for: none.meetingAvailability))
    }

    /// Switching meetings off on a pair reports the switch (the user's explicit choice)
    /// and leaves the partner in place — the roster is not what changed.
    func testSwitchPresentation_switchedOffPair_reportsTheSwitch_andKeepsThePartner() {
        var pair = team(coordID: "pm")
        pair.settings.meetingsEnabled = false
        XCTAssertTrue(pair.hasTeammatePartner)
        XCTAssertEqual(pair.meetingAvailability, .switchedOff)
        XCTAssertTrue(MeetingsSwitchPresentation.isSwitchEnabled(for: pair.meetingAvailability),
                      "off by choice stays flippable")
    }
}
