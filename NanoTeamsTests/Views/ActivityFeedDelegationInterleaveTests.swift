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

    // MARK: - Run-scoped descendant collection (runScopedDescendantIDs)

    /// A delegating step carrying a given delegation history. `active: nil` with a
    /// non-empty `history` simulates a COMPLETED delegation (DelegationState's init
    /// enforces `activeChildID ∈ history`, so an in-flight id is auto-appended).
    private func delegatingStep(stepID: String, history: [Int], active: Int? = nil) -> StepExecution {
        StepExecution(
            id: stepID, role: .codingAgent, title: "Coding Agent Step", status: .running,
            activeDelegationChildID: active, delegationChildIDs: history
        )
    }

    /// A child task whose latest run's step optionally delegates onward (nested).
    private func childTask(id: Int, parent: Int, nested: [Int] = []) -> NTMSTask {
        let step = nested.isEmpty
            ? makeStep(role: .softwareEngineer, stepID: "swe_\(id)", messages: [])
            : delegatingStep(stepID: "swe_\(id)", history: nested)
        return NTMSTask(
            id: id, title: "Child \(id)", supervisorTask: "do",
            runs: [Run(id: 0, steps: [step])],
            parentTaskID: parent, parentRoleID: "parent_role", delegationDepth: 1
        )
    }

    /// A child task that is loaded but has never run (`runs == []`). Distinct from
    /// an *unloaded* child (absent from `tasksByID`): the dictionary lookup
    /// succeeds but `runs.last` is nil.
    private func childTaskNoRuns(id: Int, parent: Int) -> NTMSTask {
        NTMSTask(
            id: id, title: "Child \(id)", supervisorTask: "do", runs: [],
            parentTaskID: parent, parentRoleID: "parent_role", delegationDepth: 1
        )
    }

    /// THE BUG: a fresh run (empty step histories) must yield no descendants, even
    /// though the previous run delegated. The run-agnostic `tasksIndex.descendantIDs`
    /// leaked the old child into the new run's feed.
    func testRunScoped_freshRun_excludesPreviousRunDelegation() {
        let run0 = Run(id: 0, steps: [delegatingStep(stepID: "ca", history: [42])])
        let run1 = Run(id: 1, steps: [delegatingStep(stepID: "ca", history: [])])
        let tasksByID: [Int: NTMSTask] = [42: childTask(id: 42, parent: 1)]

        XCTAssertEqual(
            ActivityFeedBuilder.runScopedDescendantIDs(parentRun: run1, tasksByID: tasksByID), [],
            "A fresh run with empty delegation histories must surface no descendants"
        )
        XCTAssertEqual(
            ActivityFeedBuilder.runScopedDescendantIDs(parentRun: run0, tasksByID: tasksByID), [42],
            "The run that actually delegated must surface its child"
        )
    }

    /// A delegation that already returned (activeChildID cleared, history kept) must
    /// still surface — the feed shows the team's returned work, not just live ones.
    func testRunScoped_completedDelegation_stillIncluded() {
        let run = Run(id: 0, steps: [delegatingStep(stepID: "ca", history: [42], active: nil)])
        XCTAssertEqual(
            ActivityFeedBuilder.runScopedDescendantIDs(parentRun: run, tasksByID: [42: childTask(id: 42, parent: 1)]),
            [42]
        )
    }

    /// Nested delegation (depth ≥ 2): a grandchild id lives in the CHILD's run step
    /// history, so the walk must be transitive (a flat one-level filter would drop it).
    func testRunScoped_nestedDelegation_collectedTransitively() {
        let run0 = Run(id: 0, steps: [delegatingStep(stepID: "ca", history: [42])])
        let tasksByID: [Int: NTMSTask] = [
            42: childTask(id: 42, parent: 1, nested: [99]),
            99: childTask(id: 99, parent: 42),
        ]
        XCTAssertEqual(
            ActivityFeedBuilder.runScopedDescendantIDs(parentRun: run0, tasksByID: tasksByID),
            [42, 99]
        )
    }

    /// A corrupted history that points back at an already-visited id must terminate
    /// (dedup guard) rather than loop forever.
    func testRunScoped_selfCycle_terminatesDeduped() {
        let run0 = Run(id: 0, steps: [delegatingStep(stepID: "ca", history: [42])])
        // Child 42 "delegates" back to itself — a corrupted-index self-cycle.
        let tasksByID: [Int: NTMSTask] = [42: childTask(id: 42, parent: 1, nested: [42])]
        XCTAssertEqual(
            ActivityFeedBuilder.runScopedDescendantIDs(parentRun: run0, tasksByID: tasksByID),
            [42],
            "Walk must terminate and dedup on a self-cycle"
        )
    }

    /// The depth cap must stop the walk before reading a level-N child's nested
    /// history. The self-cycle test terminates via dedup, NOT this guard — so
    /// without this test `guard depth < maxDepth` is exercised by nothing, and a
    /// future `<`→`<=` or depth-seed off-by-one would pass the whole suite.
    func testRunScoped_depthCap_stopsBeyondMaxDepth() {
        let run0 = Run(id: 0, steps: [delegatingStep(stepID: "ca", history: [10])])
        let tasksByID: [Int: NTMSTask] = [
            10: childTask(id: 10, parent: 1, nested: [20]),
            20: childTask(id: 20, parent: 10, nested: [30]),
            30: childTask(id: 30, parent: 20),
        ]
        // maxDepth 2: root processed at depth 0 (collects 10), child-10's run at
        // depth 1 (collects 20), child-20's run enqueued at depth 2 and dropped by
        // `guard 2 < 2` before its nested [30] is read.
        XCTAssertEqual(
            ActivityFeedBuilder.runScopedDescendantIDs(parentRun: run0, tasksByID: tasksByID, maxDepth: 2),
            [10, 20],
            "Depth cap must stop before reading the level-2 child's nested history"
        )
        // Default cap (3) reaches all three.
        XCTAssertEqual(
            ActivityFeedBuilder.runScopedDescendantIDs(parentRun: run0, tasksByID: tasksByID),
            [10, 20, 30]
        )
    }

    /// A child id in history whose task isn't loaded (evicted from memory) is still
    /// surfaced, but its descendants can't be reached — graceful degradation, and
    /// the same drop the consumer's `guard let childTask` already performs.
    func testRunScoped_unloadedChild_surfacedButNotRecursed() {
        let run0 = Run(id: 0, steps: [delegatingStep(stepID: "ca", history: [42])])
        XCTAssertEqual(
            ActivityFeedBuilder.runScopedDescendantIDs(parentRun: run0, tasksByID: [:]),
            [42],
            "An unloaded child id is surfaced; its (unreachable) descendants are pruned"
        )
    }

    /// A run with multiple delegating steps (parallel-ready roles, CLAUDE.md #45)
    /// must collect every step's children — exercises the outer `for step in
    /// run.steps` loop that every other test leaves at a single step.
    func testRunScoped_multipleDelegatingSteps_allCollected() {
        let run0 = Run(id: 0, steps: [
            delegatingStep(stepID: "ca1", history: [42]),
            delegatingStep(stepID: "ca2", history: [43]),
        ])
        let tasksByID: [Int: NTMSTask] = [
            42: childTask(id: 42, parent: 1),
            43: childTask(id: 43, parent: 1),
        ]
        XCTAssertEqual(
            ActivityFeedBuilder.runScopedDescendantIDs(parentRun: run0, tasksByID: tasksByID),
            [42, 43]
        )
    }

    // MARK: - Consumer seam (resolveRunScopedDescendants)

    /// `resolveTeam` stub: maps task id → Team. Parent (id 1) carries a role
    /// `parent_role` named "Coding Agent" so `delegatedFromRoleName` resolves;
    /// child (id 42) is the "Engineering" team.
    private func makeResolveTeam() -> (NTMSTask) -> Team {
        func team(_ name: String, roles: [TeamRoleDefinition]) -> Team {
            Team(name: name, roles: roles, artifacts: [], settings: .default, graphLayout: .default)
        }
        let teamsByTaskID: [Int: Team] = [
            1: team("Coding Agent Team",
                    roles: [makeRoleDef(id: "parent_role", name: "Coding Agent", role: .codingAgent)]),
            42: team("Engineering",
                     roles: [makeRoleDef(id: "swe_42", name: "Software Engineer", role: .softwareEngineer)]),
        ]
        return { teamsByTaskID[$0.id] ?? Team(name: "fallback") }
    }

    /// THE REGRESSION-ORIGIN SEAM: `resolveRunScopedDescendants` must key off the
    /// run it is handed (the view hands it the *displayed* run). A future edit
    /// passing the wrong run — e.g. `task.runs.last` instead of the displayed run
    /// — would resurface the bug; the helper-only tests can't catch that.
    func testResolveDescendants_keysOffSuppliedRun_notLatest() {
        let parent = NTMSTask(id: 1, title: "Parent", supervisorTask: "do")
        let run0 = Run(id: 0, steps: [delegatingStep(stepID: "ca", history: [42])])
        let run1 = Run(id: 1, steps: [delegatingStep(stepID: "ca", history: [])])
        let tasksByID: [Int: NTMSTask] = [1: parent, 42: childTask(id: 42, parent: 1)]
        let resolveTeam = makeResolveTeam()

        XCTAssertTrue(
            ActivityFeedBuilder.resolveRunScopedDescendants(
                displayedRun: run1, tasksByID: tasksByID, resolveTeam: resolveTeam
            ).isEmpty,
            "A fresh displayed run must surface no descendants"
        )
        XCTAssertEqual(
            ActivityFeedBuilder.resolveRunScopedDescendants(
                displayedRun: run0, tasksByID: tasksByID, resolveTeam: resolveTeam
            ).map(\.task.id),
            [42],
            "The delegating run must surface its child"
        )
    }

    /// Pins the `DescendantTask` hydration the prior helper tests never exercised:
    /// team name, delegating-role name (via `childTask.parentRoleID` + parent
    /// team), depth, and the child's run/roster.
    func testResolveDescendants_buildsDescendantTaskFields() {
        let parent = NTMSTask(id: 1, title: "Parent", supervisorTask: "do")
        let run0 = Run(id: 0, steps: [delegatingStep(stepID: "ca", history: [42])])
        let tasksByID: [Int: NTMSTask] = [1: parent, 42: childTask(id: 42, parent: 1)]

        let result = ActivityFeedBuilder.resolveRunScopedDescendants(
            displayedRun: run0, tasksByID: tasksByID, resolveTeam: makeResolveTeam()
        )
        XCTAssertEqual(result.count, 1)
        let d = result[0]
        XCTAssertEqual(d.task.id, 42)
        XCTAssertEqual(d.teamName, "Engineering")
        XCTAssertEqual(d.delegatedFromRoleName, "Coding Agent",
                       "Resolved from parent team's role named for childTask.parentRoleID")
        XCTAssertEqual(d.delegationDepth, 1)
        XCTAssertEqual(d.teamRoles.map(\.id), ["swe_42"])
        XCTAssertEqual(d.run.id, 0)
    }

    /// When the parent task isn't loaded, `delegatedFromRoleName` degrades to nil
    /// (the band just drops the "by …" subtitle) rather than crashing.
    func testResolveDescendants_parentTaskMissing_delegatedFromRoleNameNil() {
        let run0 = Run(id: 0, steps: [delegatingStep(stepID: "ca", history: [42])])
        // Parent (id 1) intentionally absent from tasksByID.
        let tasksByID: [Int: NTMSTask] = [42: childTask(id: 42, parent: 1)]

        let result = ActivityFeedBuilder.resolveRunScopedDescendants(
            displayedRun: run0, tasksByID: tasksByID, resolveTeam: makeResolveTeam()
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[0].delegatedFromRoleName)
    }

    // MARK: - runScopedDescendantIDs — remaining corners

    /// A run with no steps at all yields no descendants (outer loop never runs).
    func testRunScoped_emptyRunSteps_returnsEmpty() {
        XCTAssertEqual(
            ActivityFeedBuilder.runScopedDescendantIDs(parentRun: Run(id: 0, steps: []), tasksByID: [:]),
            []
        )
    }

    /// A child that is loaded but has never run (`runs == []`) is surfaced (the id
    /// is real) but cannot be recursed into — distinct dictionary-hit/`runs.last`-nil
    /// branch from the unloaded (`tasksByID` miss) case.
    func testRunScoped_childLoadedButNoRuns_surfacedNotRecursed() {
        let run0 = Run(id: 0, steps: [delegatingStep(stepID: "ca", history: [42])])
        XCTAssertEqual(
            ActivityFeedBuilder.runScopedDescendantIDs(
                parentRun: run0, tasksByID: [42: childTaskNoRuns(id: 42, parent: 1)]
            ),
            [42]
        )
    }

    /// The same child id appearing in two sibling steps of one run is collected
    /// once (dedup across the outer step loop, not just across depth levels).
    func testRunScoped_sameChildInTwoSteps_dedupedOnce() {
        let run0 = Run(id: 0, steps: [
            delegatingStep(stepID: "ca1", history: [42]),
            delegatingStep(stepID: "ca2", history: [42]),
        ])
        XCTAssertEqual(
            ActivityFeedBuilder.runScopedDescendantIDs(
                parentRun: run0, tasksByID: [42: childTask(id: 42, parent: 1)]
            ),
            [42]
        )
    }

    /// One step delegating to several children in a single history is fully
    /// collected (inner `for childID` loop iterates more than once).
    func testRunScoped_multipleIDsInOneStep_allCollected() {
        let run0 = Run(id: 0, steps: [delegatingStep(stepID: "ca", history: [42, 43])])
        let tasksByID: [Int: NTMSTask] = [
            42: childTask(id: 42, parent: 1),
            43: childTask(id: 43, parent: 1),
        ]
        XCTAssertEqual(
            ActivityFeedBuilder.runScopedDescendantIDs(parentRun: run0, tasksByID: tasksByID),
            [42, 43]
        )
    }

    /// Diamond: a grandchild reachable through two different children is collected
    /// exactly once (dedup across distinct parent runs, not just a self-cycle).
    func testRunScoped_diamond_sharedGrandchildCollectedOnce() {
        let run0 = Run(id: 0, steps: [delegatingStep(stepID: "ca", history: [42, 43])])
        let tasksByID: [Int: NTMSTask] = [
            42: childTask(id: 42, parent: 1, nested: [99]),
            43: childTask(id: 43, parent: 1, nested: [99]),
            99: childTask(id: 99, parent: 42),
        ]
        XCTAssertEqual(
            ActivityFeedBuilder.runScopedDescendantIDs(parentRun: run0, tasksByID: tasksByID),
            [42, 43, 99],
            "A grandchild reachable via two parents must appear exactly once"
        )
    }

    /// `maxDepth: 1` collects direct children only — each child's run is enqueued
    /// at depth 1 and dropped by `guard 1 < 1` before its nested history is read.
    func testRunScoped_maxDepthOne_directChildrenOnly() {
        let run0 = Run(id: 0, steps: [delegatingStep(stepID: "ca", history: [42])])
        let tasksByID: [Int: NTMSTask] = [
            42: childTask(id: 42, parent: 1, nested: [99]),
            99: childTask(id: 99, parent: 42),
        ]
        XCTAssertEqual(
            ActivityFeedBuilder.runScopedDescendantIDs(parentRun: run0, tasksByID: tasksByID, maxDepth: 1),
            [42],
            "maxDepth 1 stops before recursing into the child's run"
        )
    }

    /// `maxDepth: 0` collects nothing — the depth guard applies to the root run
    /// itself (pins that the guard is checked before processing, not after).
    func testRunScoped_maxDepthZero_returnsEmpty() {
        let run0 = Run(id: 0, steps: [delegatingStep(stepID: "ca", history: [42])])
        XCTAssertEqual(
            ActivityFeedBuilder.runScopedDescendantIDs(
                parentRun: run0, tasksByID: [42: childTask(id: 42, parent: 1)], maxDepth: 0
            ),
            [],
            "The root run is itself subject to the depth guard"
        )
    }

    // MARK: - resolveRunScopedDescendants — remaining corners

    /// Set/hydration divergence: an id the set helper surfaces but that cannot be
    /// hydrated (child unloaded, OR loaded but no runs) is dropped from the
    /// `DescendantTask` result — it has no run to render.
    func testResolveDescendants_unhydratableScopedIDs_droppedFromResult() {
        let run0 = Run(id: 0, steps: [delegatingStep(stepID: "ca", history: [42, 43])])
        // 42 absent (unloaded); 43 loaded but no runs. Both unhydratable.
        let tasksByID: [Int: NTMSTask] = [43: childTaskNoRuns(id: 43, parent: 1)]

        XCTAssertEqual(
            ActivityFeedBuilder.runScopedDescendantIDs(parentRun: run0, tasksByID: tasksByID),
            [42, 43],
            "The ID set surfaces both ids"
        )
        XCTAssertTrue(
            ActivityFeedBuilder.resolveRunScopedDescendants(
                displayedRun: run0, tasksByID: tasksByID, resolveTeam: makeResolveTeam()
            ).isEmpty,
            "But hydration drops both — neither has a run to render"
        )
    }

    /// Multiple direct descendants of one run are all hydrated (loop runs per id,
    /// returned order is Set-iteration so assert as a set).
    func testResolveDescendants_multipleDescendants_allHydrated() {
        let parent = NTMSTask(id: 1, title: "Parent", supervisorTask: "do")
        let run0 = Run(id: 0, steps: [delegatingStep(stepID: "ca", history: [42, 43])])
        let tasksByID: [Int: NTMSTask] = [
            1: parent,
            42: childTask(id: 42, parent: 1),
            43: childTask(id: 43, parent: 1),
        ]
        let result = ActivityFeedBuilder.resolveRunScopedDescendants(
            displayedRun: run0, tasksByID: tasksByID, resolveTeam: makeResolveTeam()
        )
        XCTAssertEqual(Set(result.map(\.task.id)), [42, 43])
        // Both delegated from parent task 1's role → resolved via that team.
        XCTAssertTrue(result.allSatisfy { $0.delegatedFromRoleName == "Coding Agent" })
    }

    /// Depth-2 hydration: a grandchild's `delegatedFromRoleName` must resolve via
    /// its IMMEDIATE parent's team (the child team), NOT the root team, and its
    /// `delegationDepth` must reflect its own lineage. This was the PR-review's
    /// depth-2 concern (`childTask.parentRoleID` namespaced to the child team).
    func testResolveDescendants_nestedGrandchild_hydratedViaImmediateParentTeam() {
        func team(_ name: String, roleID: String, roleName: String) -> Team {
            Team(
                name: name,
                roles: [makeRoleDef(id: roleID, name: roleName, role: .softwareEngineer)],
                artifacts: [], settings: .default, graphLayout: .default
            )
        }
        let t1 = NTMSTask(id: 1, title: "Parent", supervisorTask: "do")
        let t42 = NTMSTask(
            id: 42, title: "Child", supervisorTask: "do",
            runs: [Run(id: 0, steps: [delegatingStep(stepID: "tl", history: [99])])],
            parentTaskID: 1, parentRoleID: "ca", delegationDepth: 1
        )
        let t99 = NTMSTask(
            id: 99, title: "Grandchild", supervisorTask: "do",
            runs: [Run(id: 0, steps: [makeStep(role: .softwareEngineer, stepID: "qa", messages: [])])],
            parentTaskID: 42, parentRoleID: "tl", delegationDepth: 2
        )
        let teams: [Int: Team] = [
            1: team("Coding", roleID: "ca", roleName: "Coding Agent"),
            42: team("Engineering", roleID: "tl", roleName: "Tech Lead"),
            99: team("QA Team", roleID: "qa", roleName: "QA"),
        ]
        let resolveTeam: (NTMSTask) -> Team = { teams[$0.id] ?? Team(name: "fallback") }
        let root = Run(id: 0, steps: [delegatingStep(stepID: "ca", history: [42])])

        let result = ActivityFeedBuilder.resolveRunScopedDescendants(
            displayedRun: root, tasksByID: [1: t1, 42: t42, 99: t99], resolveTeam: resolveTeam
        )
        let byID = Dictionary(uniqueKeysWithValues: result.map { ($0.task.id, $0) })
        XCTAssertEqual(Set(result.map(\.task.id)), [42, 99])

        XCTAssertEqual(byID[42]?.delegatedFromRoleName, "Coding Agent",
                       "Child resolved via root team's role 'ca'")
        XCTAssertEqual(byID[42]?.delegationDepth, 1)
        XCTAssertEqual(byID[42]?.teamName, "Engineering")

        XCTAssertEqual(byID[99]?.delegatedFromRoleName, "Tech Lead",
                       "Grandchild resolved via the CHILD team's role 'tl', not the root team")
        XCTAssertEqual(byID[99]?.delegationDepth, 2)
        XCTAssertEqual(byID[99]?.teamName, "QA Team")
    }
}
