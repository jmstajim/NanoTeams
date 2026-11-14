import XCTest
@testable import NanoTeams

/// Coverage for `TeamEditorValidation.issues(team:allTeams:)` — the pure builder
/// behind the Team Editor's validation banner. Pins the severity mapping
/// (structural → error, delegation → forwarded severity) and the scope: structural
/// checks plus exactly the live `TeamValidationService` validators (`liveValidators`),
/// pinned at the source because after 2026-09-04 there is no other validator left to exclude.
final class TeamEditorValidationTests: XCTestCase {

    private static let editorPath = "NanoTeams/Views/Settings/TeamEditor/TeamEditorView.swift"
    private static let servicePath = "NanoTeams/Services/Team/TeamValidationService.swift"
    private static let liveValidators = [
        "validateDelegationPolicy", "validateAttachedSkills",
        "validateMeetingCoordinator", "validateSupervisorMode",
        "validateSupervisorAskTools", "validateMCPTools",
    ]

    /// Comment-stripped source (CLAUDE.md #89): `issues`' own doc comment names both members.
    private func strippedSource(_ path: String) throws -> String {
        RatchetSourceScan.strippingLineComments(
            try String(contentsOf: RatchetSourceScan.repoRoot.appendingPathComponent(path),
                       encoding: .utf8))
    }

    /// Every `TeamValidationService.<member>` reference in `code`, in source order.
    private static func serviceMembers(in code: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"TeamValidationService\.([A-Za-z_][A-Za-z0-9_]*)"#)
        let range = NSRange(code.startIndex..., in: code)
        return pattern.matches(in: code, range: range).map {
            String(code[Range($0.range(at: 1), in: code)!])
        }
    }

    // MARK: - Fixtures

    private func supervisor() -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "sup", name: "Supervisor", prompt: "",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(),
            isSystemRole: true, systemRoleID: "supervisor"
        )
    }

    private func makeTeam(
        id: NTMSID = "team-A",
        name: String = "Team",
        roles: [TeamRoleDefinition],
        reportsTo: [String: String] = [:]
    ) -> Team {
        var settings = TeamSettings()
        settings.hierarchy.reportsTo = reportsTo
        return Team(
            id: id, name: name,
            roles: roles, artifacts: [],
            settings: settings, graphLayout: TeamGraphLayout()
        )
    }

    // MARK: - Structural issues render as errors

    func testStructuralIssues_renderAsErrors() {
        // No roles + blank name → both structural checks fire, both as errors.
        let team = makeTeam(name: "   ", roles: [])
        let issues = TeamEditorValidation.issues(team: team, allTeams: [team])

        XCTAssertEqual(issues.count, 2, "Expected noRoles + emptyName.")
        XCTAssertTrue(issues.allSatisfy(\.isError), "Structural issues must render as errors.")
        XCTAssertTrue(issues.allSatisfy { !$0.message.isEmpty })
    }

    // MARK: - Delegation severity is forwarded

    func testDelegationError_rendersAsErrorIssue_namingRole() {
        // Non-peer delegator (reports to Supervisor) → nonTopLevelDelegator (error).
        let agent = TeamRoleDefinition(
            id: "agent", name: "Coding Agent", prompt: "a",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowDelegationToGeneratedTeams: true  // configured → enters validation
        )
        let team = makeTeam(roles: [supervisor(), agent], reportsTo: ["agent": "sup"])
        let issues = TeamEditorValidation.issues(team: team, allTeams: [team])

        let errors = issues.filter(\.isError)
        XCTAssertTrue(errors.contains { $0.message.contains("Coding Agent") },
                      "A non-peer delegator must surface an error-severity issue naming the role.")
    }

    func testDelegationWarning_rendersAsWarningIssue() {
        // Peer-level delegator whose only whitelist entry is unknown, generated off
        // → unknownDelegationTeam + noDelegationTargets, both warnings, no errors.
        let agent = TeamRoleDefinition(
            id: "agent", name: "Coding Agent", prompt: "a",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowedDelegationTeamIDs: ["ghost-team"],
            allowDelegationToGeneratedTeams: false
        )
        let team = makeTeam(roles: [supervisor(), agent], reportsTo: [:])
        let issues = TeamEditorValidation.issues(team: team, allTeams: [team])

        XCTAssertFalse(issues.isEmpty, "An unknown delegation target must surface something.")
        XCTAssertTrue(issues.allSatisfy { !$0.isError },
                      "unknownDelegationTeam / noDelegationTargets are warnings — severity must be forwarded, not forced to error.")
    }

    // MARK: - Scope: the banner calls exactly the live validators (source pin)

    /// A structural fact pinned at the source: `TeamEditorValidation.issues` reaches
    /// `TeamValidationService` through the `liveValidators` list and nothing else. Until
    /// 2026-09-04 a behavioural test proved the scope by building a dependency error the banner
    /// did NOT surface; the validator that produced that error was deleted as dead code, so the
    /// fact is structural now and is pinned as such — one more member wired in here is a
    /// decision about the banner, not a drive-by.
    ///
    /// RED: add `issues += TeamValidationService.validateDelegationPolicy(team: team, allTeams: allTeams).map { … }`
    /// a second time (or any unlisted member) inside `issues(team:allTeams:knownSkillIDs:)` → the
    /// member list gains an entry and the equality fails naming it. Both sides are sorted: the
    /// law is "exactly these members, each once" — the order of the `issues +=` lines is not
    /// part of it, so swapping them stays green.
    func testBannerCallsExactlyTheLiveValidators() throws {
        let code = try strippedSource(Self.editorPath)
        guard let body = RatchetSourceScan.functionBody(after: "static func issues(", in: code)
        else { return XCTFail("`TeamEditorValidation.issues` not found — re-aim this pin") }

        XCTAssertEqual(Self.serviceMembers(in: body).sorted(), Self.liveValidators.sorted(),
                       "the banner's `TeamValidationService` surface is exactly the live validators")
    }

    /// Anti-vacuum for the pin above (CLAUDE.md #104): every needle is still DECLARED on the
    /// service under the name searched for, and they are the only validators it declares — a
    /// rename or one more `validate…` entry reddens THIS file and says which needle to re-aim.
    ///
    /// RED: rename `validateAttachedSkills` in `TeamValidationService.swift` → the second
    /// `contains` fails; add one more `static func validate…` there → the count assertion fails.
    func testTheLiveValidatorsAreTheOnlyOnesDeclared() throws {
        let service = try strippedSource(Self.servicePath)
        for name in Self.liveValidators {
            XCTAssertTrue(service.contains("static func \(name)("),
                          "`\(name)` was renamed or removed — re-aim `liveValidators`")
        }
        let declared = service.components(separatedBy: "static func validate").count - 1
        XCTAssertEqual(declared, Self.liveValidators.count,
                       "a validator the banner does not call is either dead code or a banner decision")
    }

    // MARK: - The banner's rows

    /// The rows that report a write that did not land are rebuilt on every body pass. Their
    /// identity must be what they report, so `ForEach` keeps them across renders.
    ///
    /// RED: give the failure rows `UUID()` ids again → two builds of the same rows differ.
    func testFailureRows_keepTheirIdentityAcrossBuilds() {
        let build = {
            TeamEditorValidation.bannerIssues(
                writeFailure: (teamID: "startup", reason: "teams.json: disk full"),
                actionFailure: "Failed to persist work folder changes (teams.json): disk full",
                validation: [])
        }
        XCTAssertEqual(build().map(\.id), build().map(\.id))
    }

    /// A different failure is a different row — the identity is the team and the reason.
    func testFailureRows_differByTeamAndReason() {
        let one = TeamEditorValidation.Issue.writeFailure(teamID: "startup", reason: "disk full")
        XCTAssertNotEqual(one.id, TeamEditorValidation.Issue.writeFailure(teamID: "faang", reason: "disk full").id)
        XCTAssertNotEqual(one.id, TeamEditorValidation.Issue.writeFailure(teamID: "startup", reason: "read-only").id)
        XCTAssertNotEqual(one.id, TeamEditorValidation.Issue.actionFailure(reason: "disk full").id)
    }

    /// The write of the team shown first, then a refused action, then validation as it was
    /// passed — its rows keep the ids the editor's `@State` holds.
    func testBannerRows_areTheWriteFailure_thenTheActionFailure_thenValidation() {
        let validation = [
            TeamEditorValidation.Issue(isError: false, message: "Whitelist contains an unknown team."),
            TeamEditorValidation.Issue(isError: false, message: "Whitelist contains an unknown team."),
        ]

        let rows = TeamEditorValidation.bannerIssues(
            writeFailure: (teamID: "startup", reason: "write refused"),
            actionFailure: "delete refused",
            validation: validation)

        XCTAssertEqual(rows.map(\.message), [
            "write refused", "delete refused",
            "Whitelist contains an unknown team.", "Whitelist contains an unknown team.",
        ])
        XCTAssertEqual(rows.prefix(2).map(\.isError), [true, true])
        XCTAssertEqual(Array(rows.suffix(2).map(\.id)), validation.map(\.id))
        XCTAssertNotEqual(validation[0].id, validation[1].id, "same text, still two rows")
    }

    /// Nothing failed: the banner is validation alone, and empty when that is.
    func testBannerRows_withNoFailures_areValidationAlone() {
        XCTAssertTrue(TeamEditorValidation.bannerIssues(writeFailure: nil, actionFailure: nil, validation: []).isEmpty)
    }
}
