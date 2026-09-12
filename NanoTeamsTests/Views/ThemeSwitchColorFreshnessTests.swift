import AppKit
import SwiftUI
import XCTest

@testable import NanoTeams

/// Every colour a view can reach must follow a theme switch. This is not a property of the
/// palettes — it is a property of the LOOKUP, and one shape of lookup silently loses it.
///
/// `private static let map: [Status: Color] = [.paused: Colors.warning, …]` is evaluated ONCE, on
/// first access, and stores the RESOLVED colour of whatever theme happened to be active at that
/// moment. `Colors.warning` is a computed `var` and stays correct; the map does not. Switching
/// themes rebuilds the view tree (`.id(activeThemeRaw)`) but cannot re-run a `static let`, so the
/// stale colour survives until relaunch.
///
/// Measured 2026-09-09, before the fix, with the app opened under `rose` and switched to `cobalt`:
///
///     terminal: paused=A29DCE  warning=A29DCE   ← agree
///     cobalt:   paused=A29DCE  warning=F2E85C   ← the map is a theme behind
///
/// It reached the screen as a pink "Paused" and a pink "Working" on a blue window, and survived
/// two rounds of screenshots because every OTHER theme in the file is near-neutral enough that a
/// theme-behind status colour looks approximately right. `cobalt` is the first palette saturated
/// enough for the staleness to be visible rather than merely wrong.
///
/// The same defect was diagnosed and fixed once before, for the NSColor accessors in
/// `Colors.swift` — the note above `nsTextPrimary` describes it exactly. These eight maps were
/// missed. That is the argument for a test rather than a second comment.
///
/// RED: change any converted map back to `[K: Color]` holding `Colors.x` → the corresponding
/// assertion fails, because the first theme touched in this class wins for the whole process.
@MainActor
final class ThemeSwitchColorFreshnessTests: XCTestCase {

    private var storage: InMemoryConfigurationStorage!

    override func setUp() async throws {
        try await super.setUp()
        storage = InMemoryConfigurationStorage()
        Theme._testUseIsolatedStorage(storage)
    }

    override func tearDown() async throws {
        Theme._testResetStorage()
        storage = nil
        try await super.tearDown()
    }

    private func use(_ theme: Theme) {
        storage.set(theme.rawValue, forKey: UserDefaultsKeys.activeTheme)
    }

    private func hex(_ color: Color) -> String {
        let v = ColorResolution.rgba(color, dark: true)
        return String(format: "%02X%02X%02X",
                      Int((v[0] * 255).rounded()), Int((v[1] * 255).rounded()), Int((v[2] * 255).rounded()))
    }

    /// Two themes whose status hues are far apart, so "did it follow" has an unambiguous answer.
    /// `terminal` is the base lavender-on-grey; `cobalt` is the saturated blue with a yellow
    /// signal. Touching `terminal` FIRST is the whole point: it is what freezes a `static let`.
    private func assertFollowsSwitch(
        _ label: String, _ resolve: () -> Color, matches token: () -> Color,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        use(.terminal)
        XCTAssertEqual(hex(resolve()), hex(token()),
                       "\(label): disagrees with its token already under the first theme",
                       file: file, line: line)
        use(.cobalt)
        XCTAssertEqual(hex(resolve()), hex(token()),
                       "\(label): still \(hex(resolve())) after switching to cobalt, but the token "
                           + "is \(hex(token())) — the lookup froze the first theme",
                       file: file, line: line)
    }

    // MARK: - The instrument

    /// The premise the rest of the class rests on: these two themes really do disagree, so an
    /// assertion that they agree is not vacuous.
    func testTheTwoProbeThemesDisagreeOnEveryTokenUsedHere() {
        use(.terminal)
        let before = [hex(Colors.warning), hex(Colors.info), hex(Colors.error),
                      hex(Colors.success), hex(Colors.purple), hex(Colors.neutral)]
        use(.cobalt)
        let after = [hex(Colors.warning), hex(Colors.info), hex(Colors.error),
                     hex(Colors.success), hex(Colors.purple), hex(Colors.neutral)]
        for (a, b) in zip(before, after) {
            XCTAssertNotEqual(a, b, "terminal and cobalt agree on \(a) — pick a louder probe pair")
        }
    }

    /// And that the token accessors themselves follow — if THIS failed, the whole design system
    /// would be frozen and every assertion below would be measuring the wrong thing.
    func testTheTokenAccessorsFollowASwitch() {
        use(.terminal)
        let terminalWarning = hex(Colors.warning)
        use(.cobalt)
        XCTAssertNotEqual(hex(Colors.warning), terminalWarning)
        XCTAssertEqual(hex(Colors.warning), "F2E85C")
    }

    // MARK: - The maps that hold status colour

    func testTaskStatusColoursFollowASwitch() {
        assertFollowsSwitch("TaskStatus.paused", { TaskStatus.paused.tintColor }, matches: { Colors.warning })
        assertFollowsSwitch("TaskStatus.running", { TaskStatus.running.tintColor }, matches: { Colors.info })
        assertFollowsSwitch("TaskStatus.failed", { TaskStatus.failed.tintColor }, matches: { Colors.error })
        assertFollowsSwitch("TaskStatus.done", { TaskStatus.done.tintColor }, matches: { Colors.success })
    }

    func testStepStatusColoursFollowASwitch() {
        assertFollowsSwitch("StepStatus.paused", { StepStatus.paused.tintColor }, matches: { Colors.warning })
        assertFollowsSwitch("StepStatus.running", { StepStatus.running.tintColor }, matches: { Colors.info })
        assertFollowsSwitch("StepStatus.failed", { StepStatus.failed.tintColor }, matches: { Colors.error })
    }

    func testRoleExecutionStatusColourFollowsASwitch() {
        assertFollowsSwitch("RoleExecutionStatus.working", { RoleExecutionStatus.working.color }, matches: { Colors.info })
        assertFollowsSwitch("RoleExecutionStatus.failed", { RoleExecutionStatus.failed.color }, matches: { Colors.error })
        assertFollowsSwitch("RoleExecutionStatus.done", { RoleExecutionStatus.done.color }, matches: { Colors.success })
    }

    /// The graph node carries TWO colours and both come out of the same frozen map.
    func testRoleNodeStyleFollowsASwitch() {
        assertFollowsSwitch("nodeStyle(.working).border", { RoleExecutionStatus.working.nodeStyle.borderColor }, matches: { Colors.info })
        assertFollowsSwitch("nodeStyle(.working).background", { RoleExecutionStatus.working.nodeStyle.backgroundColor }, matches: { Colors.infoTint })
        assertFollowsSwitch("nodeStyle(.failed).border", { RoleExecutionStatus.failed.nodeStyle.borderColor }, matches: { Colors.error })
    }

    func testRoleTintFollowsASwitch() {
        assertFollowsSwitch("Role.softwareEngineer", { Role.softwareEngineer.tintColor }, matches: { Colors.success })
        assertFollowsSwitch("Role.uxResearcher", { Role.uxResearcher.tintColor }, matches: { Colors.purple })
    }

    func testChangeRequestStatusColoursFollowASwitch() {
        assertFollowsSwitch("ChangeRequestStatus.rejected", { ChangeRequestStatus.rejected.statusColor }, matches: { Colors.error })
        assertFollowsSwitch("ChangeRequestStatus.rejected tint", { ChangeRequestStatus.rejected.statusTintColor }, matches: { Colors.errorTint })
        assertFollowsSwitch("ChangeRequestStatus.escalated", { ChangeRequestStatus.escalated.statusColor }, matches: { Colors.warning })
    }

    func testRoleCompletionTypeColourFollowsASwitch() {
        assertFollowsSwitch("RoleCompletionType.producing", { RoleCompletionType.producing.displayColor }, matches: { Colors.success })
        assertFollowsSwitch("RoleCompletionType.advisory", { RoleCompletionType.advisory.displayColor }, matches: { Colors.teal })
    }
}
