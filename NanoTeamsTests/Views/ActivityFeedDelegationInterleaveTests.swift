import XCTest
@testable import NanoTeams

/// Pins the delegation-V1 interleave behavior in `ActivityFeedBuilder`:
///
/// 1. Items from descendant runs are merged into the parent timeline,
///    sorted globally by `createdAt`.
/// 2. Each item carries its `originTaskID` for downstream rendering / lookup.
/// 3. `TaggedItem.boundary` fires at parent → child and child → parent
///    transitions, and only at transitions (no spurious bands inside a single
///    team's run).
/// 4. `showSectionHeader` breaks on the `(roleID, originTaskID)` tuple so
///    cross-team items with the same `Role` enum case stay visually
///    separated — without this, two teams sharing a `softwareEngineer`
///    role would merge into one block.
final class ActivityFeedDelegationInterleaveTests: XCTestCase {

    // MARK: - Helpers

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func makeMessage(role: Role, content: String, at t: Date) -> LLMMessage {
        LLMMessage(createdAt: t, role: .assistant, content: content, sourceRole: role)
    }

    private func makeStep(role: Role, stepID: String, messages: [LLMMessage]) -> StepExecution {
        StepExecution(
            id: stepID, role: role,
            title: "\(role.displayName) Step",
            status: .running,
            llmConversation: messages
        )
    }

    private func makeRoleDef(id: String, name: String, role: Role = .softwareEngineer) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id, name: name, icon: "person", prompt: "", toolIDs: [],
            usePlanningPhase: false, dependencies: RoleDependencies(),
            systemRoleID: role.baseID
        )
    }

    private func makeDescendantTask(
        id: Int, parent: Int, run: Run, teamName: String, parentRoleName: String,
        roles: [TeamRoleDefinition]
    ) -> ActivityFeedBuilder.DescendantTask {
        let task = NTMSTask(
            id: id, title: "Child", supervisorTask: "Do thing",
            parentTaskID: parent, parentRoleID: "parent_role", delegationDepth: 1
        )
        return ActivityFeedBuilder.DescendantTask(
            task: task, run: run, teamRoles: roles,
            teamName: teamName, delegationDepth: 1,
            delegatedFromRoleName: parentRoleName
        )
    }

    // MARK: - Interleave behavior

    func testInterleave_descendantItemsMerged_sortedByTimestamp() {
        let parentStep = makeStep(role: .codingAgent, stepID: "ca", messages: [
            makeMessage(role: .codingAgent, content: "calling delegate", at: date(100)),
            makeMessage(role: .codingAgent, content: "delegate result", at: date(200)),
        ])
        let childStep = makeStep(role: .softwareEngineer, stepID: "swe", messages: [
            makeMessage(role: .softwareEngineer, content: "child working", at: date(120)),
            makeMessage(role: .softwareEngineer, content: "child done", at: date(180)),
        ])
        let childRun = Run(id: 0, steps: [childStep])
        let descendant = makeDescendantTask(
            id: 42, parent: 1, run: childRun,
            teamName: "Engineering", parentRoleName: "Coding Agent",
            roles: [makeRoleDef(id: "swe", name: "Software Engineer", role: .softwareEngineer)]
        )

        let result = ActivityFeedBuilder.buildTimelineItems(
            steps: [parentStep],
            run: Run(id: 0, steps: [parentStep]),
            activeTaskID: 1,
            descendantTasks: [descendant],
            stepArtifactContentCache: [:],
            debugModeEnabled: true,  // bypass message filtering
            isStreaming: { _ in false }
        )

        // Order: parent@100, child@120, child@180, parent@200
        let contents = result.compactMap { tagged -> String? in
            if case .llmMessage(let msg, _, _, _) = tagged.item { return msg.content }
            return nil
        }
        XCTAssertEqual(contents, ["calling delegate", "child working", "child done", "delegate result"],
                       "Items must interleave chronologically across parent + descendant runs")
    }

    func testInterleave_originTaskIDStampedCorrectly() {
        let parentStep = makeStep(role: .codingAgent, stepID: "ca", messages: [
            makeMessage(role: .codingAgent, content: "p", at: date(100)),
        ])
        let childStep = makeStep(role: .softwareEngineer, stepID: "swe", messages: [
            makeMessage(role: .softwareEngineer, content: "c", at: date(150)),
        ])
        let descendant = makeDescendantTask(
            id: 42, parent: 1, run: Run(id: 0, steps: [childStep]),
            teamName: "Engineering", parentRoleName: "Coding Agent",
            roles: []
        )

        let result = ActivityFeedBuilder.buildTimelineItems(
            steps: [parentStep],
            run: Run(id: 0, steps: [parentStep]),
            activeTaskID: 1,
            descendantTasks: [descendant],
            stepArtifactContentCache: [:],
            debugModeEnabled: true,
            isStreaming: { _ in false }
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].item.originTaskID, 1, "Parent item must carry activeTaskID")
        XCTAssertEqual(result[1].item.originTaskID, 42, "Descendant item must carry child task ID")
    }

    // MARK: - Boundary band

    func testBoundary_intoChild_fires() {
        let parentStep = makeStep(role: .codingAgent, stepID: "ca", messages: [
            makeMessage(role: .codingAgent, content: "p1", at: date(100)),
        ])
        let childStep = makeStep(role: .softwareEngineer, stepID: "swe", messages: [
            makeMessage(role: .softwareEngineer, content: "c1", at: date(150)),
        ])
        let descendant = makeDescendantTask(
            id: 42, parent: 1, run: Run(id: 0, steps: [childStep]),
            teamName: "Engineering Team", parentRoleName: "Coding Agent",
            roles: []
        )

        let result = ActivityFeedBuilder.buildTimelineItems(
            steps: [parentStep],
            run: Run(id: 0, steps: [parentStep]),
            activeTaskID: 1,
            descendantTasks: [descendant],
            stepArtifactContentCache: [:],
            debugModeEnabled: true,
            isStreaming: { _ in false }
        )

        XCTAssertNil(result[0].boundary, "First item never gets a boundary")
        XCTAssertNotNil(result[1].boundary, "Transition into child must emit boundary")
        XCTAssertEqual(result[1].boundary?.direction, .intoChild)
        XCTAssertEqual(result[1].boundary?.teamName, "Engineering Team")
        XCTAssertEqual(result[1].boundary?.delegatedFromRoleName, "Coding Agent")
    }

    func testBoundary_backToParent_fires() {
        let parentStep = makeStep(role: .codingAgent, stepID: "ca", messages: [
            makeMessage(role: .codingAgent, content: "p1", at: date(100)),
            makeMessage(role: .codingAgent, content: "p2", at: date(300)),
        ])
        let childStep = makeStep(role: .softwareEngineer, stepID: "swe", messages: [
            makeMessage(role: .softwareEngineer, content: "c1", at: date(200)),
        ])
        let descendant = makeDescendantTask(
            id: 42, parent: 1, run: Run(id: 0, steps: [childStep]),
            teamName: "Engineering", parentRoleName: "Coding Agent",
            roles: []
        )

        let result = ActivityFeedBuilder.buildTimelineItems(
            steps: [parentStep],
            run: Run(id: 0, steps: [parentStep]),
            activeTaskID: 1,
            descendantTasks: [descendant],
            stepArtifactContentCache: [:],
            debugModeEnabled: true,
            isStreaming: { _ in false }
        )

        XCTAssertEqual(result.count, 3)
        XCTAssertNil(result[0].boundary)
        XCTAssertEqual(result[1].boundary?.direction, .intoChild)
        XCTAssertEqual(result[2].boundary?.direction, .backToParent)
    }

    // MARK: - No descendants

    func testNoDescendants_buildsParentOnly_noBoundaries() {
        let parentStep = makeStep(role: .codingAgent, stepID: "ca", messages: [
            makeMessage(role: .codingAgent, content: "p1", at: date(100)),
            makeMessage(role: .codingAgent, content: "p2", at: date(200)),
        ])

        let result = ActivityFeedBuilder.buildTimelineItems(
            steps: [parentStep],
            run: Run(id: 0, steps: [parentStep]),
            activeTaskID: 1,
            descendantTasks: [],
            stepArtifactContentCache: [:],
            debugModeEnabled: true,
            isStreaming: { _ in false }
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.boundary == nil },
                      "No descendants → no boundary bands ever")
    }

    // MARK: - Section header (roleID, originTaskID) tuple

    func testSectionHeader_breaksOnOriginTaskIDChange_evenWhenRoleIDMatches() {
        // Same Role.softwareEngineer in both parent and child runs — without
        // the originTaskID component in the section-break check, items would
        // visually merge into one Engineer block across teams.
        let parentStep = makeStep(role: .softwareEngineer, stepID: "p_swe", messages: [
            makeMessage(role: .softwareEngineer, content: "parent SWE", at: date(100)),
        ])
        let childStep = makeStep(role: .softwareEngineer, stepID: "c_swe", messages: [
            makeMessage(role: .softwareEngineer, content: "child SWE", at: date(200)),
        ])
        let descendant = makeDescendantTask(
            id: 42, parent: 1, run: Run(id: 0, steps: [childStep]),
            teamName: "OtherTeam", parentRoleName: "Tech Lead",
            roles: []
        )

        let result = ActivityFeedBuilder.buildTimelineItems(
            steps: [parentStep],
            run: Run(id: 0, steps: [parentStep]),
            activeTaskID: 1,
            descendantTasks: [descendant],
            stepArtifactContentCache: [:],
            debugModeEnabled: true,
            isStreaming: { _ in false }
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result[0].showSectionHeader, "First item always gets section header")
        XCTAssertTrue(result[1].showSectionHeader,
                      "Second item must get section header because originTaskID changed, even though roleID matches")
    }

    // MARK: - Streaming + descendant interaction

    /// A descendant team's live stream must stay in chronological position relative to
    /// parent items, even though active-task streaming previews are pinned to the end.
    /// Pinning a descendant stream past a parent item with a later `createdAt` would
    /// synthesize a spurious `.intoChild` band right before a content-less "Waiting"
    /// bubble (looks like the system is teleporting into a delegated team mid-feed).
    func testDescendantStreaming_staysInChronologicalPosition_preservesBoundarySemantics() {
        let streamingID = UUID()
        let parentStep = makeStep(role: .codingAgent, stepID: "ca", messages: [
            makeMessage(role: .codingAgent, content: "parent early", at: date(100)),
            makeMessage(role: .codingAgent, content: "parent late", at: date(300)),
        ])
        let childStep = makeStep(role: .softwareEngineer, stepID: "swe", messages: [
            LLMMessage(id: streamingID, createdAt: date(200), role: .assistant,
                       content: "", sourceRole: .softwareEngineer),
        ])
        let descendant = makeDescendantTask(
            id: 42, parent: 1, run: Run(id: 0, steps: [childStep]),
            teamName: "Engineering", parentRoleName: "Coding Agent",
            roles: [makeRoleDef(id: "swe", name: "Software Engineer", role: .softwareEngineer)]
        )

        let result = ActivityFeedBuilder.buildTimelineItems(
            steps: [parentStep],
            run: Run(id: 0, steps: [parentStep]),
            activeTaskID: 1,
            descendantTasks: [descendant],
            stepArtifactContentCache: [:],
            debugModeEnabled: true,
            isStreaming: { id in id == streamingID }
        )

        XCTAssertEqual(result.count, 3)
        // Descendant stream must remain in its chronological slot (between parent items),
        // NOT pinned to the end.
        if case .llmMessage(let msg, _, _, _) = result[1].item {
            XCTAssertEqual(msg.id, streamingID,
                           "Descendant streaming item must keep chronological position, not pin to end")
        } else { XCTFail("Expected descendant streaming at position 1") }
        // Boundary semantics: intoChild at the descendant stream, backToParent at the
        // later parent item. Without the originTaskID gate on pinning, the stream
        // would land at position 2 and emit a stray .intoChild band right before it.
        XCTAssertNil(result[0].boundary, "First item never gets a boundary")
        XCTAssertEqual(result[1].boundary?.direction, .intoChild,
                       "Entering descendant team via the streaming item")
        XCTAssertEqual(result[2].boundary?.direction, .backToParent,
                       "Returning to parent after descendant stream")
    }
}
