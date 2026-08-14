import XCTest

@testable import NanoTeams

// Coverage wave 6c — cluster F2 (team services, repository, Domain value types).
//
// Every test below targets a line that no test had ever executed. The point is not the
// line: it is that nobody had ever checked the line was right. Each test therefore
// asserts an OUTCOME a wrong implementation would get wrong, and each carries the
// production mutation that turns it red.

// MARK: - TeamConfigParser: the model-defect repair chain

/// `TeamConfigParser.parseDictionaryStripping` is a six-rung ladder. The rungs that
/// operate on the QUOTE-REPAIRED text (`repaired`) — as opposed to the raw payload —
/// were entirely unexecuted, as was the doubly-escaped `team_config` retry in
/// `unwrapTeamConfig`. Those rungs are what stands between a real model emission and
/// "AI returned invalid team configuration", so a silent break in one of them costs a
/// whole generation with no diagnostic naming the rung.
///
/// The payloads below stack TWO defects each: an interior unescaped quote (which is
/// what forces the `repaired` variant to be the one that succeeds) plus a structural
/// defect. Both are documented real emissions — see the doc comments on
/// `repairUnescapedInteriorQuotes` and `repairStructuralCloserDrop`.
final class FDomainTeamConfigParserRepairChainTests: XCTestCase {

    /// gpt-oss-20b doubly-escapes the inner `team_config` JSON: after the OUTER parse
    /// the value is still `{\"name\":...}` with literal backslashes. The first
    /// `parseDictionaryStripping` on it fails at every rung (the escaped quotes never
    /// close a string, so the balanced-object scanner ends mid-string and bails), so
    /// the only route in is the second `reUnescapeInnerJSON` pass.
    ///
    /// RED: delete the `let reUnescaped = reUnescapeInnerJSON(encoded)` retry in
    /// `unwrapTeamConfig` -> `unwrapTeamConfig` returns the wrapper dict unchanged,
    /// `roles` is absent, and `decodeTeamConfig` throws, which fails the test.
    func testDecode_doublyEscapedInnerTeamConfig_isUnescapedOnceMoreAndBuilt() throws {
        let payload = #"{"team_config":"{\\\"name\\\":\\\"Doubly Escaped Team\\\",\\\"description\\\":\\\"d\\\",\\\"roles\\\":[{\\\"name\\\":\\\"Engineer\\\",\\\"prompt\\\":\\\"Write code\\\",\\\"produces_artifacts\\\":[\\\"Engineering Notes\\\"]}]}"}"#

        let build = try TeamConfigParser.decodeTeamConfig(from: payload)

        XCTAssertEqual(build.team.name, "Doubly Escaped Team",
                       "the inner config must be recovered, not the wrapper")
        XCTAssertTrue(build.team.roles.contains(where: { $0.name == "Engineer" }),
                      "the role list inside the doubly-escaped string must survive")
        let engineer = build.team.roles.first(where: { $0.name == "Engineer" })
        XCTAssertEqual(engineer?.dependencies.producesArtifacts, ["Engineering Notes"],
                       "the role's deliverable must survive the second unescape, not just its name")
    }

    /// Interior unescaped quotes (`"a "smart" one"`) PLUS a trailing junk brace. Both
    /// the raw and the repaired payload fail a strict parse; only trimming the
    /// REPAIRED text with the balanced-object scanner recovers it.
    ///
    /// The description assertion is the load-bearing one: it proves the repair
    /// re-escaped the interior quotes rather than truncating the value at the first
    /// one — a truncating repair would also parse, and would silently ship a team
    /// description of `"a "`.
    ///
    /// RED: delete the `scanBalancedObject(in: repaired)` rung -> no later rung matches
    /// (there is no `"}]` substring and the excess `}` is ignored by the stack walk),
    /// so `decodeTeamConfig` throws "Could not parse tool arguments as JSON".
    func testDecode_interiorQuotesPlusTrailingBrace_recoveredByScanningTheRepairedText() throws {
        let payload = """
            {"name":"Quoted Team","description":"a "smart" one","roles":\
            [{"name":"Engineer","prompt":"p","produces_artifacts":["Engineering Notes"]}]}}
            """

        let build = try TeamConfigParser.decodeTeamConfig(from: payload)

        XCTAssertEqual(build.team.name, "Quoted Team")
        XCTAssertEqual(build.team.description, "a \"smart\" one",
                       "the interior quotes must be ESCAPED and preserved — a repair that "
                       + "truncated the value at the first interior quote would also parse")
        XCTAssertTrue(build.team.roles.contains(where: { $0.name == "Engineer" }))
    }

    /// The Type-B dropped structural closer observed on `qwen3.5-35b-a3b`: the `roles`
    /// array loses its `]` and the payload jumps straight to the next top-level key.
    /// Combined with an interior unescaped quote so the raw-text variant of the repair
    /// cannot be the one that succeeds.
    ///
    /// Deliberately contains no `"}]` substring, so `repairMissingArrayClose` returns
    /// nil for both variants and this is unambiguously the structural-drop rung.
    ///
    /// RED: make `repairStructuralCloserDrop` return nil (or delete the
    /// `repairStructuralCloserDrop(repaired)` rung) -> nothing else in the ladder
    /// matches and `decodeTeamConfig` throws.
    func testDecode_interiorQuotesPlusDroppedRolesArrayClose_recoveredByStructuralRepair() throws {
        let payload = """
            {"name":"Dropped Closer Team","description":"a "smart" one","roles":\
            [{"name":"Engineer","prompt":"p","produces_artifacts":["Engineering Notes"]},\
            "artifacts":[]}
            """

        let build = try TeamConfigParser.decodeTeamConfig(from: payload)

        XCTAssertEqual(build.team.name, "Dropped Closer Team")
        XCTAssertEqual(build.team.description, "a \"smart\" one")
        // Supervisor + Engineer. If the missing `]` were inserted at the wrong offset
        // the role object would be swallowed into `artifacts` and the roles list would
        // come back empty (which `GeneratedTeamConfig` rejects outright).
        XCTAssertEqual(build.team.roles.count, 2,
                       "the recovered payload must still carry exactly one LLM role beside "
                       + "the auto-added Supervisor")
        XCTAssertTrue(build.team.roles.contains(where: { $0.name == "Engineer" }))
    }
}

// MARK: - GeneratedTeamBuilder: the never-drop invariant

/// `stripFileShapedArtifactNames` carries a `droppedNames` set and a matching
/// `"dropped"` warning wording, and BOTH are dead: every stripped artifact name is
/// guaranteed a rewrite target (a synthetic Summary when the role kept nothing, else
/// the role's first kept artifact). That guarantee is the thing worth pinning — if it
/// ever breaks, a downstream role's dependency edge disappears and the role goes
/// `.ready` out of order, which the code comments record as a shipped regression.
final class FDomainGeneratedTeamStripInvariantTests: XCTestCase {

    private func role(
        _ name: String,
        produces: [String] = [],
        requires: [String] = []
    ) -> GeneratedTeamConfig.RoleConfig {
        GeneratedTeamConfig.RoleConfig(
            name: name,
            prompt: "do the thing",
            producesArtifacts: produces,
            requiresArtifacts: requires,
            tools: [ToolNames.readFile]
        )
    }

    private func config(roles: [GeneratedTeamConfig.RoleConfig], supervisorRequires: [String]) -> GeneratedTeamConfig {
        GeneratedTeamConfig(
            name: "Strip Team",
            description: "d",
            roles: roles,
            artifacts: [],
            supervisorRequires: supervisorRequires
        )
    }

    /// Producer keeps NOTHING valid -> a synthetic `"<role> Summary"` is injected and
    /// every downstream reference is redirected to it.
    ///
    /// RED: change the `if let fb = fallback { rewriteMap[s] = fb }` branch to
    /// `droppedNames.insert(s)` -> the Reviewer's requires list comes back empty and
    /// the `requires` assertion fails.
    func testStrip_producerKeepsNothing_downstreamIsRedirectedToTheSyntheticSummary() {
        let cfg = config(
            roles: [
                role("Engineer", produces: ["index.html"]),
                role("Reviewer", produces: ["Review Notes"], requires: ["index.html"]),
            ],
            supervisorRequires: ["Review Notes"]
        )

        let build = GeneratedTeamBuilder.build(from: cfg)

        let engineer = build.team.roles.first { $0.name == "Engineer" }
        let reviewer = build.team.roles.first { $0.name == "Reviewer" }
        XCTAssertEqual(engineer?.dependencies.producesArtifacts, ["Engineer Summary"],
                       "a role whose only output was file-shaped must still have a deliverable")
        XCTAssertEqual(reviewer?.dependencies.requiredArtifacts, ["Engineer Summary"],
                       "the dependency edge must be REDIRECTED, never dropped — dropping it "
                       + "lets the downstream role start out of order")
        XCTAssertTrue(build.team.artifacts.contains(where: { $0.name == "Engineer Summary" }),
                      "the synthetic Summary must be declared as a team artifact")
    }

    /// Producer keeps one valid artifact -> stripped names redirect to it, so the
    /// downstream role still waits on the same producing role.
    ///
    /// RED: change the `else if let firstKept = kept.first` branch to
    /// `droppedNames.insert(s)` -> Reviewer's requires comes back empty.
    func testStrip_producerKeepsOneValidArtifact_downstreamIsRedirectedToIt() {
        let cfg = config(
            roles: [
                role("Engineer", produces: ["Engineering Notes", "app.css"]),
                role("Reviewer", produces: ["Review Notes"], requires: ["app.css"]),
            ],
            supervisorRequires: ["Review Notes"]
        )

        let build = GeneratedTeamBuilder.build(from: cfg)

        let reviewer = build.team.roles.first { $0.name == "Reviewer" }
        XCTAssertEqual(reviewer?.dependencies.requiredArtifacts, ["Engineering Notes"],
                       "the stripped name must point at the SAME producing role's surviving "
                       + "deliverable so the wait is preserved")
        let engineer = build.team.roles.first { $0.name == "Engineer" }
        XCTAssertEqual(
            engineer?.dependencies.producesArtifacts,
            ["Engineering Notes"],
            "no synthetic Summary when the role already kept a valid deliverable")
    }

    /// The invariant itself, stated as the user-visible consequence: the cleanup
    /// warning may say "replaced with" or "redirected to", never "dropped". The
    /// `"dropped"` wording is the third branch of the same impossible condition that
    /// makes `droppedNames` unreachable, so this is the assertion that would catch a
    /// future edit reviving the silent-drop path.
    ///
    /// RED: change either rewrite branch to `droppedNames.insert(s)` -> the warning
    /// text becomes `"] — dropped."` and this fails.
    func testStrip_warningNeverReportsASilentDrop() {
        let cases: [GeneratedTeamConfig] = [
            config(
                roles: [role("Engineer", produces: ["index.html", "script.js"])],
                supervisorRequires: []
            ),
            config(
                roles: [role("Engineer", produces: ["Engineering Notes", "index.html"])],
                supervisorRequires: ["Engineering Notes"]
            ),
        ]

        for cfg in cases {
            let build = GeneratedTeamBuilder.build(from: cfg)
            let stripWarnings = build.warnings.filter { $0.contains("file-shaped artifact name") }
            XCTAssertFalse(stripWarnings.isEmpty,
                           "the file-shaped cleanup must announce itself — a silent strip is "
                           + "how a deliverable disappears with no trace")
            for warning in stripWarnings {
                XCTAssertFalse(warning.contains("] — dropped."),
                               "every stripped name must be redirected, never dropped: \(warning)")
            }
        }
    }

    /// The upstream half of why the drop path is unreachable: `GeneratedTeamConfig`
    /// normalises a `requires_artifacts` entry that NO role produces down to
    /// "Supervisor Task" before the builder ever runs. So by the time
    /// `stripFileShapedArtifactNames` looks at a requires list, every entry has a
    /// producer and therefore a rewrite target.
    ///
    /// RED: delete the `if producers.contains(name) { return name }` /
    /// `return supervisorTask` normalisation in `GeneratedTeamConfig.decode` -> the
    /// unknown name survives, `declared` does not contain it, and decode throws on the
    /// unknown-artifact check, which fails the test.
    func testDecode_requiresArtifactWithNoProducer_isNormalisedToSupervisorTask() throws {
        let payload = """
            {"name":"Orphan Requires","description":"d","roles":\
            [{"name":"Engineer","prompt":"p","requires_artifacts":["nobody_makes_this.txt"],\
            "produces_artifacts":["Engineering Notes"]}]}
            """

        let build = try TeamConfigParser.decodeTeamConfig(from: payload)

        let engineer = build.team.roles.first { $0.name == "Engineer" }
        XCTAssertEqual(engineer?.dependencies.requiredArtifacts,
                       [SystemTemplates.supervisorTaskArtifactName],
                       "an unproduced requirement must collapse to the Supervisor Task, not "
                       + "survive as an artifact nothing will ever deliver")
    }
}

// MARK: - Domain value types

/// Small pure surfaces whose failure mode is quiet: a tombstone that never gets
/// written, a display label that silently reads "Unknown", a version comparison that
/// re-runs a destructive reconcile every launch.
final class FDomainValueTypeTailTests: XCTestCase {

    private func systemRole(id: String, systemRoleID: String) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id,
            name: "System Role",
            prompt: "p",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            isSystemRole: true,
            systemRoleID: systemRoleID
        )
    }

    private func customRole(id: String) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id,
            name: "Custom Role",
            prompt: "p",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
    }

    private func team(roles: [TeamRoleDefinition], artifacts: [TeamArtifact] = []) -> Team {
        Team(
            name: "Tombstone Team",
            roles: roles,
            artifacts: artifacts,
            settings: TeamSettings(),
            graphLayout: TeamGraphLayout()
        )
    }

    // MARK: Team tombstones

    /// Removing a SYSTEM role must leave a tombstone, or the next version-bump
    /// reconcile additively re-adds the role the user just deleted.
    ///
    /// RED: delete `deletedSystemRoleIDs.append(sid)` -> the tombstone assertion fails.
    func testRemoveRole_systemRole_recordsTheTombstoneSoReconcileCannotResurrectIt() {
        var sut = team(roles: [systemRole(id: "r1", systemRoleID: "techLead")])

        sut.removeRole("r1")

        XCTAssertTrue(sut.roles.isEmpty)
        XCTAssertEqual(sut.deletedSystemRoleIDs, ["techLead"],
                       "without the tombstone the bundled-content reconcile re-adds the role "
                       + "on the next app version bump")
    }

    /// Control: a non-system role leaves no tombstone. A blanket append would put a
    /// user's ad-hoc role id into the tombstone list, where it can only ever suppress
    /// something it does not name.
    ///
    /// RED: drop the `removed.isSystemRole` clause from the guard -> a tombstone is
    /// recorded and this fails.
    func testRemoveRole_customRole_recordsNoTombstone() {
        var sut = team(roles: [customRole(id: "r2")])

        sut.removeRole("r2")

        XCTAssertTrue(sut.deletedSystemRoleIDs.isEmpty,
                      "only SYSTEM roles are resurrectable, so only they are tombstoned")
    }

    /// Same contract on the artifact side — a deleted system artifact must not come
    /// back on the next reconcile.
    ///
    /// RED: delete `deletedSystemArtifactIDs.append(removed.id)` -> fails.
    func testRemoveArtifact_systemArtifact_recordsTheTombstone() {
        let artifact = TeamArtifact(
            id: "release_notes",
            name: "Release Notes",
            icon: "doc.text",
            mimeType: "text/markdown",
            description: "d",
            isSystemArtifact: true
        )
        var sut = team(roles: [], artifacts: [artifact])

        sut.removeArtifact("release_notes")

        XCTAssertTrue(sut.artifacts.isEmpty)
        XCTAssertEqual(sut.deletedSystemArtifactIDs, ["release_notes"])
    }

    /// Control for the artifact side.
    ///
    /// RED: drop the `removed.isSystemArtifact` clause -> a tombstone appears.
    func testRemoveArtifact_customArtifact_recordsNoTombstone() {
        let artifact = TeamArtifact(
            id: "notes",
            name: "Notes",
            icon: "doc.text",
            mimeType: "text/markdown",
            description: "d"
        )
        var sut = team(roles: [], artifacts: [artifact])

        sut.removeArtifact("notes")

        XCTAssertTrue(sut.deletedSystemArtifactIDs.isEmpty)
    }

    // MARK: Identifiable ids

    /// `TeamNodePosition` is rendered in a `ForEach`; its identity MUST be the role it
    /// positions, or dragging one node animates another (CLAUDE.md #22).
    ///
    /// RED: change `var id: String { roleID }` to return a fresh UUID string -> the
    /// equality assertion fails.
    func testTeamNodePosition_identityIsTheRoleItPositions() {
        let a = TeamNodePosition(roleID: "engineer", x: 10, y: 20)
        let b = TeamNodePosition(roleID: "engineer", x: 999, y: 999)

        XCTAssertEqual(a.id, "engineer")
        XCTAssertEqual(a.id, b.id,
                       "identity is the role, not the coordinates — otherwise moving a node "
                       + "re-creates the row instead of updating it")
    }

    /// `BundledUpdateReport.DeferredTeam` is listed per team; two entries for the same
    /// team would be a duplicate-id crash.
    ///
    /// RED: change `var id: NTMSID { teamID }` to `taskID`-derived -> the equality
    /// against `teamID` fails.
    func testDeferredTeam_identityIsTheTeam() {
        let deferred = BundledUpdateReport.DeferredTeam(
            teamID: NTMSID.from(name: "FAANG Team"),
            teamName: "FAANG Team",
            roleNames: ["Software Engineer"],
            taskID: 3,
            taskTitle: "Build a calculator"
        )

        XCTAssertEqual(deferred.id, deferred.teamID)
    }

    // MARK: Exhaustive display-label dictionaries

    /// `RoleCompletionType.displayLabel` reads a dictionary with an `?? "Unknown"`
    /// fallback. The fallback is unreachable only while the dictionary covers every
    /// case — that coverage is the invariant, and "Chat" for `.advisory` is the
    /// user-facing rename the enum case name deliberately does not carry.
    ///
    /// RED: remove any entry from `displayLabelMap` -> that case reads "Unknown".
    func testRoleCompletionType_everyCaseHasALabel_andAdvisoryReadsChat() {
        let allCases: [RoleCompletionType] = [.producing, .advisory, .observer]
        for c in allCases {
            XCTAssertNotEqual(c.displayLabel, "Unknown",
                              "\(c.rawValue) fell through to the dictionary fallback")
            XCTAssertFalse(c.displayLabel.isEmpty)
        }
        XCTAssertEqual(RoleCompletionType.advisory.displayLabel, "Chat",
                       "'advisory' is internal jargon; the UI must say Chat")
    }

    /// `completionTypeDisplayLabel` is the role-level shorthand; it must agree with the
    /// enum's own label rather than carrying a second copy of the mapping.
    ///
    /// RED: change `completionTypeDisplayLabel` to return `completionType.rawValue` ->
    /// the advisory role reads "advisory" instead of "Chat".
    func testCompletionTypeDisplayLabel_agreesWithTheEnum() {
        var advisory = customRole(id: "adv")
        advisory.dependencies = RoleDependencies(requiredArtifacts: ["Supervisor Task"])
        var producing = customRole(id: "prod")
        producing.dependencies = RoleDependencies(producesArtifacts: ["Notes"])
        let observer = customRole(id: "obs")

        XCTAssertEqual(advisory.completionTypeDisplayLabel, "Chat")
        XCTAssertEqual(producing.completionTypeDisplayLabel, RoleCompletionType.producing.displayLabel)
        XCTAssertEqual(observer.completionTypeDisplayLabel, RoleCompletionType.observer.displayLabel)
    }

    /// `ChangeRequestStatus.displayName` has the same dictionary shape and the same
    /// `?? rawValue` fallback. A missing entry does not crash — it just shows the
    /// camelCase raw value in the activity feed.
    ///
    /// RED: remove any entry from `displayNameMap` -> that case's displayName equals
    /// its rawValue and the assertion fails.
    func testChangeRequestStatus_everyCaseHasADisplayName() {
        let allCases: [ChangeRequestStatus] = [
            .pending, .approved, .rejected, .escalated,
            .supervisorApproved, .supervisorRejected, .failed,
        ]
        for c in allCases {
            XCTAssertNotEqual(c.displayName, c.rawValue,
                              "\(c.rawValue) fell through to the rawValue fallback — the feed "
                              + "would show a camelCase identifier")
        }
        XCTAssertEqual(ChangeRequestStatus.supervisorApproved.displayName, "Supervisor Approved")
    }

    /// `ComputerUseRestrictionLevel` exposes THREE accessors over one metadata table.
    /// The existing pin checks the other two; `settingDescription` had never been read,
    /// so a missing entry would show an EMPTY explanation under a security control.
    ///
    /// RED: remove any entry from `metadata` -> that level's settingDescription is "".
    func testComputerUseRestrictionLevel_everyCaseExplainsItselfInSettings() {
        for level in ComputerUseRestrictionLevel.allCases {
            XCTAssertFalse(level.settingDescription.isEmpty,
                           "\(level.rawValue) has no Settings description — the safety picker "
                           + "would offer an unexplained option")
            XCTAssertFalse(level.displayName.isEmpty)
            XCTAssertFalse(level.judgeGuidance.isEmpty)
        }
    }

    // MARK: AppVersion build metadata

    /// Semver build metadata (`+build.7`) must be ignored, exactly like the
    /// pre-release suffix. It is not cosmetic: `shouldReconcile` drives the
    /// version-bump pass that OVERWRITES every stored team's prompt templates, so a
    /// build-tagged binary that compares "newer" than itself re-clobbers the user's
    /// edits on every single launch.
    ///
    /// The `+build.7` form (metadata containing a dot) is the one that matters — a
    /// dotless `+sha1` is already absorbed by the digit-prefix truncation, so it
    /// cannot detect a missing strip.
    ///
    /// RED: delete the `firstIndex(of: "+")` strip -> `"1.0.0+build.7"` parses as
    /// `[1,0,0,7]`, compares greater than `[1,0,0]`, and both assertions fail.
    func testAppVersion_buildMetadataIsIgnored_soAReconcileIsNotRerunEveryLaunch() {
        XCTAssertEqual(AppVersion.compare("1.0.0+build.7", "1.0.0"), 0,
                       "build metadata is not a version component")
        XCTAssertFalse(AppVersion.shouldReconcile(from: "1.0.0", to: "1.0.0+build.7"),
                       "a build-tagged binary must not re-run the bundled-content reconcile "
                       + "against the same version it already applied")
    }

    // MARK: WorkFolderContext back-compat alias

    /// `workFolder` is a get/set alias over `projection`. The setter is what the
    /// remaining `context.workFolder.teams = ...` call sites go through; a no-op
    /// setter would silently discard those mutations.
    ///
    /// RED: make the setter a no-op -> the projection still holds the original team.
    func testWorkFolderContext_workFolderSetter_writesThroughToTheProjection() {
        let original = Team(name: "Original", roles: [], artifacts: [],
                            settings: TeamSettings(), graphLayout: TeamGraphLayout())
        var sut = WorkFolderContext(
            projection: WorkFolderProjection(
                state: WorkFolderState(name: "wf"),
                settings: .defaults,
                teams: [original]
            ),
            tasksIndex: TasksIndex(),
            toolDefinitions: [],
            activeTaskID: nil,
            activeTask: nil
        )

        var replacement = sut.workFolder
        replacement.teams = [Team(name: "Replacement", roles: [], artifacts: [],
                                  settings: TeamSettings(), graphLayout: TeamGraphLayout())]
        sut.workFolder = replacement

        XCTAssertEqual(sut.projection.teams.map(\.name), ["Replacement"],
                       "the alias must write through — otherwise every legacy call site's "
                       + "mutation is silently dropped")
        XCTAssertEqual(sut.workFolder.teams.map(\.name), ["Replacement"])
    }

    // MARK: Readiness / run selection

    /// `getRoleReadiness` for an unknown role id returns `isReady: false` with an EMPTY
    /// missing list — the one shape where "not ready" carries no blocking artifact.
    /// `blockingReason` must answer nil there rather than building the degenerate
    /// string `"Waiting for: "`, which would show up in the graph as a role waiting on
    /// nothing.
    ///
    /// RED: delete the `if missingArtifacts.isEmpty { return nil }` guard ->
    /// `blockingReason` becomes "Waiting for: " and `XCTAssertNil` fails.
    func testRoleReadiness_unknownRole_hasNoBlockingReason() {
        let readiness = ArtifactDependencyResolver.getRoleReadiness(
            roleID: "no-such-role",
            roles: [],
            producedArtifacts: []
        )

        XCTAssertFalse(readiness.isReady)
        XCTAssertTrue(readiness.missingArtifacts.isEmpty)
        XCTAssertNil(readiness.blockingReason,
                     "an unknown role is blocked by nothing nameable — 'Waiting for: ' with an "
                     + "empty list is worse than no reason at all")
    }

    /// `isSelectedRunActive` with no task at all. The run-history toolbar reads this to
    /// decide whether the run controls are live; a `true` here would offer Pause/Resume
    /// for a task that does not exist.
    ///
    /// RED: change the guard to `return true` -> fails.
    func testIsSelectedRunActive_noTask_isFalse() {
        XCTAssertFalse(RunService.isSelectedRunActive(task: nil, selectedRunID: nil))
        XCTAssertFalse(RunService.isSelectedRunActive(task: nil, selectedRunID: 3))
    }
}

// MARK: - TaskEngineStoreAdapter error relay

/// The engine's only channel to the user is `setLastErrorMessageForUI`, and the
/// adapter's forwarding hop had never been executed. A dropped forward means the
/// revision-cycle failure ("roles [...] form a dependency cycle") transitions the
/// engine to `.failed` with no explanation anywhere.
@MainActor
final class FDomainTaskEngineStoreAdapterErrorRelayTests: XCTestCase {

    /// Asserted through `errorSurfaceCount` / `lastSurfacedError` rather than
    /// `lastErrorMessage`: the latter is a single-shot slot the banner consumes, so it
    /// cannot answer "did the forward happen" (CLAUDE.md §5).
    ///
    /// RED: make `setLastErrorMessageForUI` a no-op on the adapter -> the count does
    /// not advance and the message assertion fails.
    func testSetLastErrorMessageForUI_reachesTheOrchestrator() async {
        let orchestrator = TestOrchestrator.make()
        let adapter = TaskEngineStoreAdapter(orchestrator: orchestrator, taskID: 7)
        let before = orchestrator.errorSurfaceCount
        let message = "Revision stalled: roles [a, b] form a dependency cycle."

        adapter.setLastErrorMessageForUI(message)

        XCTAssertEqual(orchestrator.errorSurfaceCount, before + 1,
                       "the engine's error must actually surface — a dropped forward leaves "
                       + "the run failed with no explanation")
        XCTAssertEqual(orchestrator.lastSurfacedError, message)
    }
}

// MARK: - StoreConfiguration restore-from-storage branches

/// Two persisted-value restore branches in `StoreConfiguration.init` had never run.
/// Both are read-back paths: a broken one is invisible at write time and only shows up
/// as a setting that quietly reverts on the next launch.
@MainActor
final class FDomainStoreConfigurationRestoreTests: XCTestCase {

    private final class InMemoryStorage: ConfigurationStorage, @unchecked Sendable {
        var values: [String: Any] = [:]
        func string(forKey key: String) -> String? { values[key] as? String }
        func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
        func data(forKey key: String) -> Data? { values[key] as? Data }
        func object(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any?, forKey key: String) {
            if let value { values[key] = value } else { values.removeValue(forKey: key) }
        }
        func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    }

    private var storage: InMemoryStorage!

    override func setUp() {
        super.setUp()
        storage = InMemoryStorage()
    }

    override func tearDown() {
        storage = nil
        super.tearDown()
    }

    /// The cached GitHub release is what suppresses a repeat network check and what the
    /// Watchtower banner renders between checks. If the decode branch never restored
    /// it, every launch would re-fetch and the banner would vanish on relaunch.
    ///
    /// RED: replace `self.cachedAppUpdateRelease = decoded` with `= nil` -> the
    /// restored value is nil and both assertions fail.
    func testCachedAppUpdateRelease_survivesARelaunch() async throws {
        let release = AppUpdateChecker.Release(
            tag: "v9.9.9",
            htmlURL: try XCTUnwrap(URL(string: "https://example.invalid/releases/v9.9.9")),
            body: "notes"
        )
        let writer = StoreConfiguration(storage: storage)
        writer.cachedAppUpdateRelease = release
        XCTAssertNotNil(storage.data(forKey: UserDefaultsKeys.cachedAppUpdateRelease),
                        "precondition: the setter must have persisted something to decode")

        let reloaded = StoreConfiguration(storage: storage)

        XCTAssertEqual(reloaded.cachedAppUpdateRelease?.tag, "v9.9.9")
        XCTAssertEqual(reloaded.cachedAppUpdateRelease, release,
                       "the cached release must round-trip whole, not just by tag")
    }

    /// The computer-use judge override pins which model adjudicates a screen action.
    /// Losing it on relaunch silently moves adjudication back to the global chat model.
    ///
    /// RED: replace `self.computerUseJudgeLLMOverride = decoded` with `= nil` -> fails.
    func testComputerUseJudgeOverride_survivesARelaunch() async {
        let writer = StoreConfiguration(storage: storage)
        writer.computerUseJudgeLLMOverride = LLMOverride(
            baseURLString: "http://127.0.0.1:1234",
            modelName: "judge-model"
        )

        let reloaded = StoreConfiguration(storage: storage)

        XCTAssertEqual(reloaded.computerUseJudgeLLMOverride?.modelName, "judge-model")
        XCTAssertEqual(reloaded.computerUseJudgeLLMOverride?.baseURLString, "http://127.0.0.1:1234")
    }

}

// MARK: - Repository tail: task persistence, artifact writes, delegator normalisation

/// `NTMSRepository` is a struct, so these follow the house shape of
/// `LoadOrRecoverFileCoverageTests`: a non-`@MainActor` case, the repository built in
/// `setUp`, and a real temp work folder per test.
final class FDomainRepositoryTailTests: XCTestCase, @unchecked Sendable {

    private var sut: NTMSRepository!
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        sut = NTMSRepository()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("f2-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            // Restore any directory this suite made read-only so the recursive remove
            // can complete (a leaked 0o500 dir would strand the temp tree).
            if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
                for case let url as URL in walker {
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o755], ofItemAtPath: url.path)
                }
            }
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
        sut = nil
        try super.tearDownWithError()
    }

    // MARK: updateTask / updateTaskOnly

    /// Writing a task whose `task.json` is absent must FAIL LOUDLY. The alternative —
    /// creating the file — would resurrect a task the user deleted, complete with its
    /// index entry.
    ///
    /// RED: replace the throw with `try store.write(task, ...)` -> no error is thrown
    /// and `XCTAssertThrowsError` fails.
    func testUpdateTask_taskFileAbsent_throwsTaskNotFound() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let ghost = NTMSTask(id: 999, title: "ghost", supervisorTask: "s")

        XCTAssertThrowsError(try sut.updateTask(at: root, task: ghost)) { error in
            guard let repoError = error as? NTMSRepositoryError,
                  case .taskNotFound(let id) = repoError else {
                return XCTFail("expected .taskNotFound, got \(error)")
            }
            XCTAssertEqual(id, 999)
        }
    }

    /// A task whose `task.json` exists but whose index row was lost (a torn write, or a
    /// recovered `tasks_index.json`) must be re-added by the next update, not left
    /// invisible. The index is what the sidebar and the scheduler scan — a task missing
    /// from it still runs but cannot be seen or stopped.
    ///
    /// RED: change the `else { index.tasks.append(refreshed) }` branch to `else {}` ->
    /// the returned context's index stays empty.
    func testUpdateTask_indexRowLost_isAppendedBack() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let created = try sut.createTask(at: root, title: "Recoverable", supervisorTask: "s")
        let taskID = created.taskID
        let paths = NTMSPaths(workFolderRoot: root)

        var index = try sut.store.read(TasksIndex.self, from: paths.tasksIndexJSON)
        index.tasks.removeAll { $0.id == taskID }
        try sut.store.write(index, to: paths.tasksIndexJSON)
        let reread = try sut.store.read(TasksIndex.self, from: paths.tasksIndexJSON)
        XCTAssertFalse(reread.tasks.contains(where: { $0.id == taskID }),
                       "precondition: the index row must actually be gone")

        var task = try sut.loadTask(at: root, taskID: taskID)
        task.title = "Recovered"
        let context = try sut.updateTask(at: root, task: task)

        XCTAssertTrue(context.tasksIndex.tasks.contains(where: { $0.id == taskID && $0.title == "Recovered" }),
                      "the task must reappear in the index, not stay orphaned on disk")
        let onDisk = try sut.store.read(TasksIndex.self, from: paths.tasksIndexJSON)
        XCTAssertTrue(onDisk.tasks.contains(where: { $0.id == taskID }),
                      "and the repair must be persisted, not only returned")
    }

    /// Same contract on the background-task path. `updateTaskOnly` is what every
    /// non-active running task goes through, so an index row lost there stays lost for
    /// the whole session.
    ///
    /// RED: change `else { index.tasks.append(refreshed) }` to `else {}` in
    /// `updateTaskOnly` -> the on-disk index never regains the row.
    func testUpdateTaskOnly_indexRowLost_isAppendedBack() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let created = try sut.createTask(at: root, title: "Background", supervisorTask: "s")
        let taskID = created.taskID
        let paths = NTMSPaths(workFolderRoot: root)

        var index = try sut.store.read(TasksIndex.self, from: paths.tasksIndexJSON)
        index.tasks.removeAll { $0.id == taskID }
        try sut.store.write(index, to: paths.tasksIndexJSON)

        var task = try sut.loadTask(at: root, taskID: taskID)
        task.title = "Background Recovered"
        try sut.updateTaskOnly(at: root, task: task)

        let onDisk = try sut.store.read(TasksIndex.self, from: paths.tasksIndexJSON)
        XCTAssertTrue(onDisk.tasks.contains(where: { $0.id == taskID && $0.title == "Background Recovered" }),
                      "a background task whose index row was lost must be re-listed")
    }

    // MARK: Step artifact persistence

    /// The write is the last step of `create_artifact`. When it fails the error must
    /// name the FILE — a bare `CocoaError` reaches the model as "The file couldn't be
    /// saved" with no path, and the role has no way to tell which artifact failed.
    ///
    /// The failure is induced by making the role directory read-only. `createDirectory`
    /// still succeeds (the directory exists), so the test isolates the write itself.
    ///
    /// RED: replace `throw NTMSRepositoryError.unableToWriteReport(fileURL, ...)` with
    /// `throw error` -> the case match fails.
    func testPersistStepArtifactFile_unwritableRoleDirectory_reportsTheFileItCouldNotWrite() throws {
        let paths = NTMSPaths(workFolderRoot: root)
        try sut.ensureLayout(paths: paths)
        let roleDir = paths.roleDir(taskID: 1, runID: 0, roleID: "engineer")
        try FileManager.default.createDirectory(at: roleDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: roleDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: roleDir.path)
        }

        XCTAssertThrowsError(
            try sut.persistStepArtifactFile(
                at: root, taskID: 1, runID: 0, roleID: "engineer",
                artifactName: "Engineering Notes", content: "hello"
            )
        ) { error in
            guard let repoError = error as? NTMSRepositoryError,
                  case .unableToWriteReport(let url, _) = repoError else {
                return XCTFail("expected .unableToWriteReport, got \(error)")
            }
            XCTAssertEqual(url.lastPathComponent, "artifact_engineering_notes.md",
                           "the error must name the artifact file so the role can tell which "
                           + "deliverable failed")
        }
    }

    /// `ancestorChain` is documented to fail OPEN: an unreadable `tasks_index.json`
    /// means "treat this task as top-level" so a role can still write its artifact.
    /// Failing closed here would turn a corrupt index into a role that can never
    /// deliver.
    ///
    /// RED: change the `guard let index = try? store.read(...) else { return [] }` to
    /// propagate (or to return `[taskID]`) -> the artifact lands under a `subtasks`
    /// path (or the call throws) and the flat-path assertion fails.
    func testAncestorChain_unreadableTasksIndex_failsOpenToTheFlatLayout() throws {
        let paths = NTMSPaths(workFolderRoot: root)
        try sut.ensureLayout(paths: paths)
        try Data("{ not json at all".utf8).write(to: paths.tasksIndexJSON)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.tasksIndexJSON.path),
                      "precondition: the file must EXIST and be undecodable, not be missing — "
                      + "the missing case is a different guard")

        let relative = try sut.persistStepArtifactFile(
            at: root, taskID: 7, runID: 1, roleID: "engineer",
            artifactName: "Engineering Notes", content: "body"
        )

        XCTAssertFalse(relative.contains("subtasks"),
                       "an unreadable index must not be read as 'this task is nested'")
        let expected = paths.roleDir(taskID: 7, runID: 1, roleID: "engineer")
            .appendingPathComponent("artifact_engineering_notes.md", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path),
                      "the artifact must still be written, at the flat top-level path")
    }

    // MARK: migrateIfNeeded — delegator peer-status normalisation

    /// The peer-status invariant: a role configured for delegation must have NO
    /// upstream `reportsTo` entry, or `delegate_to_team` rejects every call with
    /// `DELEGATION_DENIED`. `normalizeDelegatorPeerStatus` self-heals legacy
    /// `teams.json` files on every load — but the heal is only worth anything if
    /// `migrateIfNeeded` also PERSISTS it. Otherwise the in-memory teams look right
    /// while the file keeps the stale entry, and any code path that re-reads the file
    /// before the next normalise sees the broken shape again.
    ///
    /// Isolated so line-level attribution is unambiguous: the version watermark is
    /// pre-set to current (no reconcile), every bundled template is tombstoned (no
    /// missing-bootstrap append), the role is non-system (no dependency sync) and
    /// carries no delegation tools in `toolIDs` (no toolset strip). The peer-status
    /// normalisation is the only thing left that can mark the file dirty.
    ///
    /// RED: delete the `teamsNeedsWrite = true` inside the
    /// `if normalizeDelegatorPeerStatus(...)` block -> `teams.json` is never written
    /// and the on-disk assertion still finds the stale `reportsTo` entry.
    func testMigrateIfNeeded_staleDelegatorReportsTo_isStrippedAndPersisted() throws {
        let paths = NTMSPaths(workFolderRoot: root)
        try sut.ensureLayout(paths: paths)

        var delegator = TeamRoleDefinition(
            id: "coding-agent-role",
            name: "Coding Agent",
            prompt: "p",
            toolIDs: [ToolNames.readFile],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        delegator.allowDelegationToGeneratedTeams = true
        XCTAssertTrue(delegator.hasDelegationConfigured,
                      "precondition: the role must be a configured delegator")

        var team = Team(
            name: "Legacy Delegating Team",
            roles: [delegator],
            artifacts: [],
            settings: TeamSettings(),
            graphLayout: TeamGraphLayout()
        )
        team.settings.hierarchy.reportsTo = ["coding-agent-role": "supervisor-role"]

        var teamsFile = TeamsFile(schemaVersion: 1, teams: [team])
        try sut.store.write(teamsFile, to: paths.teamsJSON)

        var state = WorkFolderState(name: "wf")
        state.lastAppliedAppVersion = AppVersion.current
        state.deletedTeamTemplateIDs = Team.defaultTeams.compactMap(\.templateID)
        var index = TasksIndex()

        _ = try sut.migrateIfNeeded(
            teamsFile: &teamsFile, state: &state, tasksIndex: &index, paths: paths)

        XCTAssertNil(teamsFile.teams[0].settings.hierarchy.reportsTo["coding-agent-role"],
                     "the in-memory team must be normalised")
        let onDisk = try sut.store.read(TeamsFile.self, from: paths.teamsJSON)
        XCTAssertNil(onDisk.teams.first?.settings.hierarchy.reportsTo["coding-agent-role"],
                     "the self-heal must be PERSISTED — an in-memory-only fix leaves the "
                     + "delegator broken for anything that re-reads teams.json")
    }

    /// Control for the same call: a clean file must not be rewritten. Without this the
    /// test above would also pass if `migrateIfNeeded` wrote teams.json
    /// unconditionally, which would churn the file (and every team's stored prompts)
    /// on every single work-folder open.
    ///
    /// The probe is the ABSENCE of the file rather than its modification date: the
    /// timestamp comparison would depend on filesystem timestamp granularity, whereas
    /// `migrateIfNeeded` never READS `teams.json` (it takes the file inout), so deleting
    /// it makes "did anything write" a yes/no fact.
    ///
    /// RED: hoist `teamsNeedsWrite = true` out of its `if` so it is unconditional ->
    /// `teams.json` reappears and this fails.
    func testMigrateIfNeeded_alreadyNormalisedTeams_leavesTeamsFileUntouched() throws {
        let paths = NTMSPaths(workFolderRoot: root)
        try sut.ensureLayout(paths: paths)

        var delegator = TeamRoleDefinition(
            id: "coding-agent-role",
            name: "Coding Agent",
            prompt: "p",
            toolIDs: [ToolNames.readFile],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        delegator.allowDelegationToGeneratedTeams = true
        let team = Team(
            name: "Already Normalised Team",
            roles: [delegator],
            artifacts: [],
            settings: TeamSettings(),
            graphLayout: TeamGraphLayout()
        )

        var teamsFile = TeamsFile(schemaVersion: 1, teams: [team])
        try sut.store.write(teamsFile, to: paths.teamsJSON)
        try FileManager.default.removeItem(at: paths.teamsJSON)

        var state = WorkFolderState(name: "wf")
        state.lastAppliedAppVersion = AppVersion.current
        state.deletedTeamTemplateIDs = Team.defaultTeams.compactMap(\.templateID)
        var index = TasksIndex()

        _ = try sut.migrateIfNeeded(
            teamsFile: &teamsFile, state: &state, tasksIndex: &index, paths: paths)

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.teamsJSON.path),
                       "a clean teams.json must not be rewritten — the write is gated on an "
                       + "actual mutation, not run on every open")
        XCTAssertNil(teamsFile.teams[0].settings.hierarchy.reportsTo["coding-agent-role"],
                     "and the already-normalised team stays normalised")
    }
}
