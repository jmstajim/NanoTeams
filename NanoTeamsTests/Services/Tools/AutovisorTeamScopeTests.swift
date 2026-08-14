import XCTest
@testable import NanoTeams

/// The Autovisor team block-list where it crosses surfaces: the tool schema the model reads,
/// the Settings card the human clicks, and the persisted settings that feed both.
final class AutovisorTeamScopeTests: XCTestCase {

    private func team(_ name: String) -> Team { TeamTemplateFactory.empty(name: name) }

    /// Team ids the catalog actually advertises (the `generated` sentinel excluded — it is a
    /// mode, not a team, and counting it would let a catalog with zero real teams look full).
    private func catalogTeamIDs(_ schema: ToolSchema) -> [String] {
        schema.description
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard line.hasPrefix("- `"), let close = line.dropFirst(3).firstIndex(of: "`") else { return nil }
                let id = String(line.dropFirst(3)[..<close])
                return id == DelegationConstants.generatedTeamSentinel ? nil : id
            }
    }

    // MARK: - Byte identity for the default (no-migration promise)

    /// An empty block list must leave the schema BYTE-identical to the pre-feature build.
    /// This is the whole "existing folders see no change" guarantee.
    func testEmptyBlockList_schemaIsByteIdenticalToUnrestricted() {
        let teams = [team("Alpha"), team("Beta")]
        for generation in [true, false] {
            let unrestricted = CreateManagedTaskTool.buildSchema(
                allTeams: teams, policy: AutovisorTeamPolicy(allowGeneration: generation))
            let emptyBlockList = CreateManagedTaskTool.buildSchema(
                allTeams: teams,
                policy: AutovisorTeamPolicy(blockedTeamIDs: [], allowGeneration: generation))
            XCTAssertEqual(unrestricted.description, emptyBlockList.description)
        }
    }

    /// A folder with only hidden teams keeps the historical bare header — the empty-catalog
    /// note fires on BLOCKING, not on emptiness, so a user who never touched the setting sees
    /// no prompt-byte change.
    func testHiddenOnlyFolder_withNoBlocking_emitsNoEmptyCatalogNote() {
        let schema = CreateManagedTaskTool.buildSchema(
            allTeams: [TeamTemplateFactory.autovisor()],
            policy: AutovisorTeamPolicy(allowGeneration: false))
        XCTAssertTrue(schema.description.contains("Available teams:"))
        XCTAssertFalse(schema.description.contains("every team in this folder is excluded"))
    }

    // MARK: - The block list reaches the schema

    /// RED-4 shape: a NON-EMPTY block list over ≥2 candidates. With a single team (or an empty
    /// list) the catalog and the checked rows coincide trivially and this passes even if
    /// `buildSchema` ignored the policy entirely.
    func testBlockedTeam_isAbsentFromTheCatalogWhileItsSiblingRemains() {
        let a = team("Alpha"), b = team("Beta")
        let schema = CreateManagedTaskTool.buildSchema(
            allTeams: [a, b], policy: AutovisorTeamPolicy(blockedTeamIDs: [a.id]))
        XCTAssertEqual(catalogTeamIDs(schema), [b.id])
    }

    /// The catalog and the Settings card must be two renderings of ONE decision.
    func testSchemaCatalogEqualsTheCheckedRowsInSettings() {
        let a = team("Alpha"), b = team("Beta"), c = team("Gamma")
        let policy = AutovisorTeamPolicy(blockedTeamIDs: [b.id])
        let catalog = catalogTeamIDs(CreateManagedTaskTool.buildSchema(allTeams: [a, b, c], policy: policy))
        let checked = AutovisorTeamsCardPolicy.rows(allTeams: [a, b, c], policy: policy)
            .filter { $0.isAllowed && !$0.isOrphan }
            .map(\.id)
        XCTAssertEqual(catalog, checked)
    }

    /// Blocking everything with generation off is legal — and the catalog says so instead of
    /// silently shipping an empty list the model would read as "pick one".
    func testEverythingBlocked_generationOff_catalogSaysSoAndDropsTheOmitAdvice() {
        let a = team("Alpha")
        let schema = CreateManagedTaskTool.buildSchema(
            allTeams: [a],
            policy: AutovisorTeamPolicy(blockedTeamIDs: [a.id], allowGeneration: false))
        XCTAssertTrue(schema.description.contains("every team in this folder is excluded"))
        XCTAssertTrue(schema.description.contains("team generation is off"))
        // The description must not advertise a path the runtime refuses: with no selectable
        // team, omitting `team_id` cannot succeed either.
        let teamIDDescription = schema.parameters.properties?["team_id"]?.description ?? ""
        XCTAssertFalse(teamIDDescription.contains("Omit"), "got: \(teamIDDescription)")
        XCTAssertFalse(teamIDDescription.contains("generated"), "got: \(teamIDDescription)")
    }

    func testEverythingBlocked_generationOn_stillOffersTheSentinel() {
        let a = team("Alpha")
        let schema = CreateManagedTaskTool.buildSchema(
            allTeams: [a],
            policy: AutovisorTeamPolicy(blockedTeamIDs: [a.id], allowGeneration: true))
        XCTAssertTrue(schema.description.contains(DelegationConstants.generatedTeamSentinel))
        XCTAssertFalse(schema.description.contains("team generation is off"))
    }

    /// `create_managed_task` is mandatory and named by the manager's prompt in three places,
    /// so it is never withheld — withholding it would leave the model told to call a tool
    /// that vanished.
    func testSchemaIsStillBuiltWhenNothingIsAvailable() {
        let a = team("Alpha")
        let schema = CreateManagedTaskTool.buildSchema(
            allTeams: [a],
            policy: AutovisorTeamPolicy(blockedTeamIDs: [a.id], allowGeneration: false))
        XCTAssertEqual(schema.name, ToolNames.createManagedTask)
        XCTAssertFalse(schema.description.isEmpty)
    }

    // MARK: - Persistence

    func testAbsentKeyOnALegacySettingsFile_decodesToAnEmptyBlockList() throws {
        let json = #"{"schemaVersion":3,"context":"","contextPrompt":"p"}"#
        let settings = try JSONCoderFactory.makeDateDecoder()
            .decode(ProjectSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.autovisorBlockedTeamIDs, [])
        XCTAssertTrue(AutovisorTeamPolicy(settings: settings).blockedTeamIDs.isEmpty)
    }

    /// The sorted-array argument only holds if EVERY write normalizes, not just decode and the
    /// orchestrator setters. A plain `var` left that to each future writer's memory, so two
    /// orderings of the same block set compared unequal and dirtied `mutateWorkFolder`'s
    /// structural settings diff on a semantic no-op.
    func testDirectVarWrite_isNormalized_soOrderingCannotDirtyTheDiff() {
        var a = ProjectSettings(contextPrompt: "p")
        var b = ProjectSettings(contextPrompt: "p")
        a.autovisorBlockedTeamIDs = ["alpha", "beta"]
        b.autovisorBlockedTeamIDs = ["beta", "alpha"]
        XCTAssertEqual(a.autovisorBlockedTeamIDs, ["alpha", "beta"])
        XCTAssertEqual(a, b, "same block SET ⇒ no settings change ⇒ no settings.json rewrite")

        var c = ProjectSettings(contextPrompt: "p")
        c.autovisorBlockedTeamIDs = ["zeta", " alpha ", "zeta", ""]
        XCTAssertEqual(c.autovisorBlockedTeamIDs, ["alpha", "zeta"],
                       "a direct write trims, dedupes and sorts like every other entry point")
    }

    /// Encode∘decode must be a fixed point from the FIRST round, not the second — otherwise the
    /// first save after a direct write rewrites the file for no semantic reason.
    func testEncodeDecode_isAFixedPointFromTheFirstRound() throws {
        var s = ProjectSettings(contextPrompt: "p")
        s.autovisorBlockedTeamIDs = ["zeta", "alpha", "zeta", " beta "]
        let enc = JSONCoderFactory.makePersistenceEncoder()
        let dec = JSONCoderFactory.makeDateDecoder()
        let e1 = try enc.encode(s)
        let e2 = try enc.encode(try dec.decode(ProjectSettings.self, from: e1))
        XCTAssertEqual(e1, e2)
    }

    func testBlockList_roundTripsAndSelfHealsAHandEditedFile() throws {
        let json = #"{"schemaVersion":3,"autovisorBlockedTeamIDs":["beta"," alpha ","beta",""]}"#
        let decoded = try JSONCoderFactory.makeDateDecoder()
            .decode(ProjectSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.autovisorBlockedTeamIDs, ["alpha", "beta"],
                       "decode normalizes so a hand-edited file converges on first load")

        let reEncoded = try JSONCoderFactory.makePersistenceEncoder().encode(decoded)
        let round = try JSONCoderFactory.makeDateDecoder()
            .decode(ProjectSettings.self, from: reEncoded)
        XCTAssertEqual(round.autovisorBlockedTeamIDs, ["alpha", "beta"])
        XCTAssertTrue(String(data: reEncoded, encoding: .utf8)!.contains("autovisorBlockedTeamIDs"))
    }

    // MARK: - Settings card rows + warnings

    func testRows_markOrphansAndPreserveTheStoredBlock() {
        let a = team("Alpha")
        let policy = AutovisorTeamPolicy(blockedTeamIDs: [a.id, "deleted_team"])
        let rows = AutovisorTeamsCardPolicy.rows(allTeams: [a], policy: policy)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.id, a.id)
        XCTAssertFalse(rows.first?.isAllowed ?? true)
        XCTAssertTrue(rows.last?.isOrphan ?? false)
    }

    func testRows_hideInfrastructureTeams() {
        let rows = AutovisorTeamsCardPolicy.rows(
            allTeams: [TeamTemplateFactory.autovisor(), TeamTemplateFactory.generatedTeam()],
            policy: AutovisorTeamPolicy())
        XCTAssertTrue(rows.isEmpty, "the manager's own team and the generated placeholder "
                      + "aren't blockable — a checkbox there would be a silent no-op")
    }

    func testWarning_tracksTheThreeConfigurationsWorthTelling() {
        let a = team("Alpha")
        XCTAssertNil(AutovisorTeamsCardPolicy.warning(
            allTeams: [a], policy: AutovisorTeamPolicy(), activeTeam: a))

        XCTAssertEqual(AutovisorTeamsCardPolicy.warning(
            allTeams: [a],
            policy: AutovisorTeamPolicy(blockedTeamIDs: [a.id], allowGeneration: false),
            activeTeam: a), .cannotCreateAnyTask)

        XCTAssertEqual(AutovisorTeamsCardPolicy.warning(
            allTeams: [a],
            policy: AutovisorTeamPolicy(blockedTeamIDs: [a.id], allowGeneration: true),
            activeTeam: a), .generatedTeamsOnly)

        let b = team("Beta")
        XCTAssertEqual(AutovisorTeamsCardPolicy.warning(
            allTeams: [a, b],
            policy: AutovisorTeamPolicy(blockedTeamIDs: [a.id]),
            activeTeam: a), .activeTeamBlocked("Alpha"))
    }

    func testEveryWarning_hasNonEmptyDistinctCopy() {
        let all: [AutovisorTeamsCardPolicy.Warning] =
            [.cannotCreateAnyTask, .generatedTeamsOnly, .activeTeamBlocked("Alpha")]
        let messages = all.map(\.message)
        XCTAssertEqual(Set(messages).count, all.count, "each warning needs its own copy")
        XCTAssertTrue(messages.allSatisfy { !$0.isEmpty })
    }
}
