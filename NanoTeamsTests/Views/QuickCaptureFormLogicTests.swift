import XCTest
@testable import NanoTeams

/// Pure-logic helpers extracted from `QuickCaptureFormView` so the routing
/// rules (placeholder selection, team-mode label, selectable team filter) can
/// be exercised without a SwiftUI environment.
@MainActor
final class QuickCaptureFormLogicTests: XCTestCase {

    // MARK: - Test Doubles

    /// `Team(name:)` convenience init builds a team with no roles → no Supervisor
    /// → `supervisorRequiredArtifacts` empty → `isChatMode == true`. To get a
    /// task-mode team for tests we attach a Supervisor role with one required
    /// artifact (chat-mode is the absence of Supervisor deliverables).
    private func makeTeam(
        name: String = "Test",
        templateID: String? = nil,
        isChatMode: Bool = true
    ) -> Team {
        var team = Team(name: name)
        team.templateID = templateID
        if !isChatMode {
            team.roles = [
                TeamRoleDefinition(
                    id: "supervisor",
                    name: "Supervisor",
                    prompt: "",
                    toolIDs: [],
                    usePlanningPhase: false,
                    dependencies: RoleDependencies(requiredArtifacts: ["Final Output"]),
                    isSystemRole: true,
                    systemRoleID: "supervisor"
                ),
            ]
        }
        return team
    }

    // MARK: - taskFieldPlaceholder

    func testTaskFieldPlaceholder_chatModeTeam_returnsSendMessage() {
        let team = makeTeam(isChatMode: true)
        XCTAssertEqual(QuickCaptureFormLogic.taskFieldPlaceholder(for: team), "Send a message...")
    }

    func testTaskFieldPlaceholder_taskModeTeam_returnsDescribeTask() {
        let team = makeTeam(isChatMode: false)
        XCTAssertEqual(QuickCaptureFormLogic.taskFieldPlaceholder(for: team), "Describe your task...")
    }

    func testTaskFieldPlaceholder_nilTeam_defaultsToDescribeTask() {
        XCTAssertEqual(QuickCaptureFormLogic.taskFieldPlaceholder(for: nil), "Describe your task...")
    }

    // MARK: - teamModeLabel

    func testTeamModeLabel_chatModeTeam_returnsChat() {
        let team = makeTeam(isChatMode: true)
        XCTAssertEqual(QuickCaptureFormLogic.teamModeLabel(for: team), "chat")
    }

    func testTeamModeLabel_taskModeTeam_returnsTask() {
        let team = makeTeam(isChatMode: false)
        XCTAssertEqual(QuickCaptureFormLogic.teamModeLabel(for: team), "task")
    }

    func testTeamModeLabel_generatedTemplate_alwaysReturnsTask() {
        // Generated Team is a placeholder — the actual generated team determines
        // the real mode. The picker always shows "task" for the placeholder
        // because all generated teams produce artifacts (never chat-mode).
        let placeholder = makeTeam(templateID: "generated", isChatMode: true)
        XCTAssertEqual(QuickCaptureFormLogic.teamModeLabel(for: placeholder), "task")
    }

    func testTeamModeLabel_nilTeam_defaultsToTask() {
        XCTAssertEqual(QuickCaptureFormLogic.teamModeLabel(for: nil), "task")
    }

    // MARK: - QuickCaptureMode.expectsFocusableField

    func testExpectsFocusableField_overlay_returnsTrue() {
        XCTAssertTrue(QuickCaptureMode.overlay.expectsFocusableField)
    }

    func testExpectsFocusableField_supervisorAnswer_returnsTrue() {
        let payload = SupervisorAnswerPayload(
            stepID: "s", taskID: 0, role: .softwareEngineer, roleDefinition: nil,
            question: "?", messageContent: nil, thinking: nil, isChatMode: false
        )
        XCTAssertTrue(QuickCaptureMode.supervisorAnswer(payload: payload).expectsFocusableField)
    }

    func testExpectsFocusableField_taskWorking_chat_returnsTrue() {
        XCTAssertTrue(QuickCaptureMode.taskWorking(roleName: "X", isChatMode: true).expectsFocusableField)
    }

    func testExpectsFocusableField_taskWorking_nonChat_returnsFalse() {
        XCTAssertFalse(QuickCaptureMode.taskWorking(roleName: "X", isChatMode: false).expectsFocusableField)
    }

    // MARK: - taskFieldMaxHeight

    /// Before the first `onGeometryChange` callback lands, `measuredFormHeight`
    /// is 0 (the no-measurement sentinel). The calc must fall back to
    /// `QuickCapturePanel.panelMinSize` so the cap is finite on the first frame.
    func testTaskFieldMaxHeight_zeroMeasuredHeight_usesPanelMinSizeSeed() {
        let seeded = QuickCaptureFormLogic.taskFieldMaxHeight(measuredFormHeight: 0)
        let panelSeeded = QuickCaptureFormLogic.taskFieldMaxHeight(
            measuredFormHeight: QuickCapturePanel.panelMinSize.height
        )
        XCTAssertEqual(seeded, panelSeeded, "Zero (unmeasured) must produce the same cap as an explicit `panelMinSize.height` input")
    }

    func testTaskFieldMaxHeight_neverFallsBelowFloor() {
        // Even at the smallest possible panel height (`panelMinSize.height = 250`),
        // half-panel - chrome (125 - 56 = 69pt) would underflow the floor (88pt).
        // The `max` clamp ensures the field never collapses below one usable line.
        let cap = QuickCaptureFormLogic.taskFieldMaxHeight(measuredFormHeight: 200)
        XCTAssertGreaterThanOrEqual(
            cap,
            MessageComposerLayout.minPaneAnchoredFieldHeight,
            "Cap must clamp to at least \(MessageComposerLayout.minPaneAnchoredFieldHeight)pt floor"
        )
    }

    func testTaskFieldMaxHeight_largePanel_returnsHalfPanelMinusChrome() {
        // For a comfortably-sized panel (well above floor + chrome), the cap
        // tracks half-pane minus chrome. Picking 800 so the half (400) minus
        // chrome (56) = 344, which is well above the 88pt floor.
        let panelHeight: CGFloat = 800
        let cap = QuickCaptureFormLogic.taskFieldMaxHeight(measuredFormHeight: panelHeight)
        XCTAssertEqual(cap, panelHeight * 0.5 - MessageComposerLayout.paneAnchoredFieldChrome)
    }

    func testTaskFieldMaxHeight_alwaysFinite_acrossSampleHeights() {
        // Sweep a range of plausible panel heights AND pathological inputs that
        // `onGeometryChange` can theoretically emit during speculative layout
        // (negative, zero, `.infinity`, `.nan`). The cap must stay finite — a
        // `.infinity` or `.nan` output would propagate into `.frame(height:)`
        // and either collapse the field or trigger a SwiftUI layout assertion.
        let samples: [CGFloat] = [-100, 0, 1, 250, 500, 1000, 10_000, .infinity, .nan]
        for height in samples {
            let cap = QuickCaptureFormLogic.taskFieldMaxHeight(measuredFormHeight: height)
            XCTAssertTrue(cap.isFinite, "Cap must be finite for measuredFormHeight=\(height) (got \(cap))")
            XCTAssertGreaterThan(cap, 0, "Cap must be positive for measuredFormHeight=\(height) (got \(cap))")
        }
    }

    func testTaskFieldMaxHeight_infinityInput_clampsToSeed() {
        let seed = QuickCaptureFormLogic.taskFieldMaxHeight(measuredFormHeight: 0)
        let withInfinity = QuickCaptureFormLogic.taskFieldMaxHeight(measuredFormHeight: .infinity)
        XCTAssertEqual(withInfinity, seed, ".infinity must route to the same fallback as the zero-sentinel")
    }

    func testTaskFieldMaxHeight_nanInput_clampsToSeed() {
        let seed = QuickCaptureFormLogic.taskFieldMaxHeight(measuredFormHeight: 0)
        let withNaN = QuickCaptureFormLogic.taskFieldMaxHeight(measuredFormHeight: .nan)
        XCTAssertEqual(withNaN, seed, ".nan must route to the same fallback as the zero-sentinel")
    }

    // MARK: - acceptedMeasuredHeight

    /// Pins the `onGeometryChange` accept/reject decision for `measuredFormHeight`.
    /// Reject contracts: non-finite (`.nan` / `.infinity`), negative, sub-2pt
    /// jitter on already-measured. Accept contracts: any finite ≥ 0 value when
    /// current is the 0 sentinel, ≥ 2pt delta thereafter.

    func testAcceptedMeasuredHeight_zeroSentinel_acceptsAnyFiniteNonNegative() {
        XCTAssertEqual(QuickCaptureFormLogic.acceptedMeasuredHeight(current: 0, incoming: 1), 1)
        XCTAssertEqual(QuickCaptureFormLogic.acceptedMeasuredHeight(current: 0, incoming: 320), 320)
        XCTAssertEqual(QuickCaptureFormLogic.acceptedMeasuredHeight(current: 0, incoming: 0), 0)
    }

    func testAcceptedMeasuredHeight_nan_rejected() {
        XCTAssertNil(QuickCaptureFormLogic.acceptedMeasuredHeight(current: 0, incoming: .nan))
        XCTAssertNil(QuickCaptureFormLogic.acceptedMeasuredHeight(current: 250, incoming: .nan))
    }

    func testAcceptedMeasuredHeight_infinity_rejected() {
        XCTAssertNil(QuickCaptureFormLogic.acceptedMeasuredHeight(current: 0, incoming: .infinity))
        XCTAssertNil(QuickCaptureFormLogic.acceptedMeasuredHeight(current: 250, incoming: .infinity))
    }

    func testAcceptedMeasuredHeight_negative_rejected() {
        XCTAssertNil(QuickCaptureFormLogic.acceptedMeasuredHeight(current: 0, incoming: -1))
        XCTAssertNil(QuickCaptureFormLogic.acceptedMeasuredHeight(current: 250, incoming: -100))
    }

    func testAcceptedMeasuredHeight_subTwoPtJitter_rejected() {
        // After measurement, sub-2pt deltas are auto-layout jitter — drop them.
        XCTAssertNil(QuickCaptureFormLogic.acceptedMeasuredHeight(current: 250, incoming: 250))
        XCTAssertNil(QuickCaptureFormLogic.acceptedMeasuredHeight(current: 250, incoming: 250.5))
        XCTAssertNil(QuickCaptureFormLogic.acceptedMeasuredHeight(current: 250, incoming: 251.9))
        XCTAssertNil(QuickCaptureFormLogic.acceptedMeasuredHeight(current: 250, incoming: 248.1))
    }

    func testAcceptedMeasuredHeight_twoPtOrMoreDelta_accepted() {
        XCTAssertEqual(QuickCaptureFormLogic.acceptedMeasuredHeight(current: 250, incoming: 252), 252)
        XCTAssertEqual(QuickCaptureFormLogic.acceptedMeasuredHeight(current: 250, incoming: 248), 248)
        XCTAssertEqual(QuickCaptureFormLogic.acceptedMeasuredHeight(current: 250, incoming: 320), 320)
    }

    // MARK: - selectableTeams

    func testSelectableTeams_excludesGeneratedPlaceholder() {
        let teams = [
            makeTeam(name: "Coding Agent"),
            makeTeam(name: "Generated", templateID: "generated"),
            makeTeam(name: "FAANG"),
        ]
        let result = QuickCaptureFormLogic.selectableTeams(from: teams)
        XCTAssertEqual(result.map(\.name), ["Coding Agent", "FAANG"])
    }

    func testSelectableTeams_emptyList_returnsEmpty() {
        XCTAssertTrue(QuickCaptureFormLogic.selectableTeams(from: []).isEmpty)
    }

    func testSelectableTeams_noGeneratedPresent_passesThrough() {
        let teams = [makeTeam(name: "A"), makeTeam(name: "B")]
        let result = QuickCaptureFormLogic.selectableTeams(from: teams)
        XCTAssertEqual(result.map(\.name), ["A", "B"])
    }

    func testSelectableTeams_onlyGeneratedPresent_returnsEmpty() {
        let teams = [makeTeam(name: "Generated", templateID: "generated")]
        XCTAssertTrue(QuickCaptureFormLogic.selectableTeams(from: teams).isEmpty)
    }
}
