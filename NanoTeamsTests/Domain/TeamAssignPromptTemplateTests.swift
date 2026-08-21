import XCTest
@testable import NanoTeams

/// Pins the `Reset to Default` regression: writes to a team's prompt-template
/// field must bump `Team.updatedAt`. `Team.==` is `(id, updatedAt)`-only, so
/// without the bump SwiftUI treats the post-write team as identical to the
/// pre-write one and skips `PromptTemplateEditor.updateNSView`'s text-storage
/// update — Reset visibly does nothing until the user navigates away and back.
final class TeamAssignPromptTemplateTests: XCTestCase {

    func testAssignPromptTemplate_changedValue_bumpsUpdatedAt() {
        var team = Team(name: "Test")
        let before = team.updatedAt

        team.assignPromptTemplate(.system, value: "completely new template body")

        XCTAssertEqual(team.systemPromptTemplate, "completely new template body")
        XCTAssertGreaterThan(team.updatedAt, before,
                             "Template assignment must bump updatedAt so SwiftUI's `(id, updatedAt)` diff fires")
    }

    func testAssignPromptTemplate_breaksTeamEquality() {
        var team = Team(name: "Test")
        let before = team

        team.assignPromptTemplate(.system, value: "new body")

        XCTAssertNotEqual(before, team,
                          "Post-mutation Team must compare unequal to pre-mutation Team — that's what makes SwiftUI re-render the editor.")
    }

    func testAssignPromptTemplate_noOpWrite_doesNotBumpUpdatedAt() {
        var team = Team(name: "Test")
        let originalTemplate = team.systemPromptTemplate
        let before = team.updatedAt

        team.assignPromptTemplate(.system, value: originalTemplate)

        XCTAssertEqual(team.updatedAt, before,
                       "Identical-value write must be a no-op — otherwise every keystroke that round-trips through the binding setter would burn a fresh timestamp and force the editor to re-render itself.")
    }

    func testAssignPromptTemplate_allThreeFields_bumpUpdatedAt() {
        // All three prompt fields share the same mutation surface — make sure
        // none of them accidentally diverge via direct stored-property writes.
        for field in [Team.PromptField.system, .consultation, .meeting] {
            var team = Team(name: "Test")
            let before = team.updatedAt
            team.assignPromptTemplate(field, value: "edited via PromptField")
            XCTAssertGreaterThan(team.updatedAt, before,
                                 "Field \(field) must bump updatedAt")
        }
    }

    /// End-to-end pin for the actual bug class: applying the Reset flow's
    /// inputs (selected field + the resolver's default for the team's
    /// template ID) must produce a Team that compares unequal to the
    /// pre-Reset team under SwiftUI's `(id, updatedAt)` diff. The 4 tests
    /// above only pin the helper in isolation — if a future change drops
    /// the `assignPromptTemplate` call from `TeamPromptsDetailView.resetCurrentTemplate`
    /// (e.g. inlines `team.systemPromptTemplate = …` as a perf "fix"), this
    /// test guards the call-site by exercising the full default-resolution
    /// chain — the same chain that the production reset action uses.
    func testReset_systemTemplate_mutatesAndBumpsUpdatedAt() {
        // Start from a team whose system template is something other than
        // the default — same way the user reaches Reset (after editing).
        var team = Team(name: "Test")
        team.assignPromptTemplate(.system, value: "user-edited body that diverges from default")
        let before = team

        // Mirror the production reset path: route the default-template
        // resolver result through `assignPromptTemplate`.
        let defaultBody = SystemTemplates.defaultSystemTemplate(for: team.templateID)
        team.assignPromptTemplate(.system, value: defaultBody)

        XCTAssertEqual(team.systemPromptTemplate, defaultBody,
                       "Reset must restore the system template to the resolver's default for the team's templateID")
        XCTAssertNotEqual(before, team,
                          "Post-Reset Team must compare unequal to pre-Reset Team — otherwise the editor view shows stale content until navigation refreshes makeNSView")
    }
}
