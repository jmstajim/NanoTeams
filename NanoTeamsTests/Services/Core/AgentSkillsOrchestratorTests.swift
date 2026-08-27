import XCTest

@testable import NanoTeams

/// Orchestrator side of per-role agent skills: the in-memory `roleSkills`
/// snapshot is populated on work-folder open, refreshed on demand (the hook
/// `startRun` fires), memoised within its TTL, and reports attachments it could
/// not resolve instead of dropping them silently.
///
/// Assertions are scoped to PROJECT skills written into `tempDir`. The scan also
/// picks up the machine's global skills (`~/.claude/skills`, plugins), but ids
/// are namespaced by origin (`…|project|…` vs `…|global|…`) so those can never
/// collide with a fixture.
@MainActor
final class AgentSkillsOrchestratorTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    /// Writes a project skill and returns the id the scanner actually assigns.
    ///
    /// The id is DERIVED from a real scan rather than spelled out here: its
    /// shape (`"<agentID>|<origin>|<relPathUnderRoot>"`, where `relPath` for a
    /// skill directory ends in `/SKILL.md`) is the scanner's business, and
    /// hard-coding it would make these tests assert a format instead of a
    /// behaviour. The probe scan uses an empty isolated home so it cannot pick
    /// up the developer's real global skills.
    @discardableResult
    private func writeProjectSkill(_ name: String, body: String) throws -> String {
        let dir = tempDir.appendingPathComponent(".claude/skills/\(name)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try body.write(to: dir.appendingPathComponent("SKILL.md"),
                       atomically: true, encoding: .utf8)

        let isolatedHome = tempDir.appendingPathComponent("__probe_home__")
        try? FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        let probe = AgentSkillsScanner.scan(projectRoot: tempDir, homeDirectory: isolatedHome)
        guard let id = probe.items.first(where: { $0.name == name && $0.origin == .project })?.id
        else {
            XCTFail("Scanner did not discover the project skill '\(name)' just written")
            return ""
        }
        return id
    }

    private func skillURL(_ name: String) -> URL {
        tempDir.appendingPathComponent(".claude/skills/\(name)/SKILL.md")
    }

    /// Attaches ids to the first non-Supervisor role of the active team.
    private func attach(_ ids: [String]) async {
        await sut.mutateWorkFolder { projection in
            guard let teamIndex = projection.teams.firstIndex(where: { $0.id == projection.activeTeamID })
            else { return }
            guard let roleIndex = projection.teams[teamIndex].roles
                .firstIndex(where: { !$0.isSupervisor })
            else { return }
            projection.teams[teamIndex].roles[roleIndex].attachedSkillIDs = ids
        }
    }

    /// When the cached catalogue was last taken — the observable that says whether
    /// a WALK happened, as opposed to a body re-read.
    private func catalogueStamp() -> Date? {
        sut.skillsCatalogueStore.load(projectRoot: tempDir)?.scannedAt
    }

    // MARK: - Open / refresh

    func testOpenWorkFolder_populatesSnapshot() async throws {
        let id = try writeProjectSkill("tdd", body: "# TDD\nWrite the test first.")

        await sut.openWorkFolder(tempDir)

        XCTAssertNotNil(sut.roleSkills)
        XCTAssertTrue(sut.roleSkills?.items.contains(where: { $0.id == id }) ?? false,
                      "The project skill must appear in the discovered catalogue")
    }

    func testAttachedSkill_bodyIsRead() async throws {
        let id = try writeProjectSkill("tdd", body: "# TDD\nWrite the test first.")
        await sut.openWorkFolder(tempDir)

        await attach([id])
        await sut.refreshAgentSkills()

        XCTAssertEqual(sut.roleSkills?.bodies[id], "# TDD\nWrite the test first.")
        XCTAssertTrue(sut.roleSkills?.unresolvedIDs.isEmpty ?? false)
    }

    /// Only attached ids get their bodies read — a discovered-but-unattached
    /// skill must not be loaded (a typical install discovers 130+ of them).
    func testUnattachedSkill_bodyIsNotRead() async throws {
        let attached = try writeProjectSkill("tdd", body: "body")
        let unattached = try writeProjectSkill("unused", body: "body")
        await sut.openWorkFolder(tempDir)

        await attach([attached])
        await sut.refreshAgentSkills()

        XCTAssertNotNil(sut.roleSkills?.bodies[attached])
        XCTAssertNil(sut.roleSkills?.bodies[unattached],
                     "Unattached skills must not be read into the body cache")
    }

    func testRefresh_picksUpBodyEditedAfterOpen() async throws {
        let id = try writeProjectSkill("tdd", body: "v1")
        await sut.openWorkFolder(tempDir)
        await attach([id])
        await sut.refreshAgentSkills()
        XCTAssertEqual(sut.roleSkills?.bodies[id], "v1")

        try "v2".write(to: skillURL("tdd"), atomically: true, encoding: .utf8)
        await sut.refreshAgentSkills()

        XCTAssertEqual(sut.roleSkills?.bodies[id], "v2",
                       "Each run start re-reads bodies, so a SKILL.md edited since open is picked up")
    }

    // MARK: - Catalogue is cached, content is not

    /// The split the 5-second memo could not express. It gated BOTH halves, so a
    /// second send within five seconds saw neither a new skill nor an edited one —
    /// and a send more than five seconds later (i.e. every real one) paid the whole
    /// walk. Now the walk is cached and the bytes are not.
    func testRefresh_rereadsBodies_withoutRewalkingTheCatalogue() async throws {
        let id = try writeProjectSkill("tdd", body: "v1")
        await sut.openWorkFolder(tempDir)
        await attach([id])
        await sut.refreshAgentSkills()
        XCTAssertEqual(sut.roleSkills?.bodies[id], "v1")
        let stampBefore = catalogueStamp()

        try "v2".write(to: skillURL("tdd"), atomically: true, encoding: .utf8)
        await sut.refreshAgentSkills()

        XCTAssertEqual(sut.roleSkills?.bodies[id], "v2",
                       "An edited SKILL.md must reach the very next prompt")
        XCTAssertEqual(catalogueStamp(), stampBefore,
                       "…and it must not have cost a walk of every skill root")
    }

    /// The other side of the same split, and the deliberate staleness: a skill
    /// installed since the catalogue was taken is invisible until someone asks.
    func testRefresh_doesNotDiscoverASkillInstalledSinceTheCatalogueWasTaken() async throws {
        await sut.openWorkFolder(tempDir)
        let late = try writeProjectSkill("late", body: "late body")

        await sut.refreshAgentSkills()

        XCTAssertFalse(sut.roleSkills?.items.contains { $0.id == late } ?? true,
                       "Discovery is cached; nothing on the run-start path re-walks")
    }

    /// …and the verb that resolves it. This is what the Refresh control beside both
    /// catalogue lists calls.
    func testRescanCatalogue_discoversASkillInstalledSinceTheCatalogueWasTaken() async throws {
        await sut.openWorkFolder(tempDir)
        let late = try writeProjectSkill("late", body: "late body")

        await sut.rescanAgentSkillCatalogue()

        XCTAssertTrue(sut.roleSkills?.items.contains { $0.id == late } ?? false)
    }

    /// Attaching a skill must make its body available immediately — the prompt
    /// preview and the Role editor's cost banner both read it on the next tick.
    func testAttachingASkill_readsItsBody_withoutRewalking() async throws {
        let tdd = try writeProjectSkill("tdd", body: "TDD body")
        let review = try writeProjectSkill("review", body: "Review body")
        await sut.openWorkFolder(tempDir)

        await attach([tdd])
        await sut.refreshAgentSkills()
        XCTAssertNil(sut.roleSkills?.bodies[review])
        let stampBefore = catalogueStamp()

        await attach([tdd, review])
        await sut.refreshAgentSkills()

        XCTAssertEqual(sut.roleSkills?.bodies[review], "Review body")
        XCTAssertEqual(catalogueStamp(), stampBefore,
                       "Both ids were already in the catalogue — nothing to re-walk")
    }

    /// The whole reason a submit used to spend seconds here: no bundled template
    /// ships `attachedSkillIDs`, so on a default install the run-start path has
    /// nothing to read and must touch no file at all.
    func testRefresh_withNothingAttached_readsNoBodies() async throws {
        try writeProjectSkill("tdd", body: "body")
        await sut.openWorkFolder(tempDir)
        let stampBefore = catalogueStamp()

        await sut.refreshAgentSkills()

        XCTAssertEqual(sut.roleSkills?.bodies, [:])
        XCTAssertEqual(sut.roleSkills?.unresolvedIDs, [])
        XCTAssertEqual(catalogueStamp(), stampBefore)
    }

    // MARK: - The bounded retry

    /// A skill installed AND attached since the catalogue was taken would otherwise
    /// read as unresolved forever: the cache is wrong and nothing asks it to look
    /// again. One retry closes that.
    func testAttachedID_missingFromTheCatalogue_triggersARescan() async throws {
        await sut.openWorkFolder(tempDir)
        let late = try writeProjectSkill("late", body: "late body")

        await attach([late])
        await sut.refreshAgentSkills()

        XCTAssertEqual(sut.roleSkills?.bodies[late], "late body",
                       "An id the cache does not know earns one fresh look")
    }

    /// …bounded to ONE look per attachment set. A dangling attachment (file deleted
    /// after the role attached it) is unresolvable by definition, so an unbounded
    /// retry would walk every skill root on every run start — reintroducing the
    /// exact cost the cache removes, and silently, because the OUTCOME is identical
    /// either way. Only the walk count can tell the two apart.
    func testDanglingAttachment_doesNotRewalkOnEveryRefresh() async throws {
        let id = try writeProjectSkill("tdd", body: "body")
        await sut.openWorkFolder(tempDir)
        await attach([id])
        await sut.refreshAgentSkills()

        try FileManager.default.removeItem(
            at: tempDir.appendingPathComponent(".claude/skills/tdd"))
        await sut.refreshAgentSkills()
        let stampAfterFirst = catalogueStamp()
        await sut.refreshAgentSkills()
        await sut.refreshAgentSkills()

        XCTAssertTrue(sut.roleSkills?.unresolvedIDs.contains(id) ?? false)
        XCTAssertEqual(catalogueStamp(), stampAfterFirst,
                       "Repeated refreshes of an unresolvable set must not keep re-walking")
    }

    // MARK: - Default storage (the divergence from agent instructions)

    /// `refreshAgentInstructions` clears its snapshot with no work folder — there
    /// is nothing to scan. Skills are the opposite: global skills and plugin
    /// skills live under the home dir and are available before any folder is
    /// opened, which is the mode the app boots into.
    func testRefresh_withoutWorkFolder_stillProducesASnapshot() async {
        await sut.refreshAgentSkills()

        XCTAssertNotNil(sut.roleSkills,
                        "Skills must still resolve in default storage — global skills do not "
                            + "depend on a work folder")
    }

    // MARK: - Failure modes (no silent drops)

    func testAttachedSkill_fileDeleted_isReportedUnresolved() async throws {
        let id = try writeProjectSkill("tdd", body: "body")
        await sut.openWorkFolder(tempDir)
        await attach([id])
        await sut.refreshAgentSkills()
        XCTAssertNotNil(sut.roleSkills?.bodies[id])

        try FileManager.default.removeItem(
            at: tempDir.appendingPathComponent(".claude/skills/tdd"))
        await sut.refreshAgentSkills()

        XCTAssertNil(sut.roleSkills?.bodies[id])
        XCTAssertTrue(sut.roleSkills?.unresolvedIDs.contains(id) ?? false,
                      "A deleted skill must be reported, not silently dropped")
    }

    func testAttachedSkill_nonUTF8_isReportedUnresolved() async throws {
        let id = try writeProjectSkill("binary", body: "placeholder")
        await sut.openWorkFolder(tempDir)
        await attach([id])

        try Data([0xFF, 0xFE, 0x00, 0x01]).write(to: skillURL("binary"))
        await sut.refreshAgentSkills()

        XCTAssertNil(sut.roleSkills?.bodies[id])
        XCTAssertTrue(sut.roleSkills?.unresolvedIDs.contains(id) ?? false)
    }

    // MARK: - End-to-end resolution

    func testResolveThroughSnapshot_yieldsPromptReadyValues() async throws {
        let tdd = try writeProjectSkill("tdd", body: "TDD body")
        let review = try writeProjectSkill("review", body: "Review body")
        await sut.openWorkFolder(tempDir)

        await attach([review, tdd])   // deliberately not alphabetical
        await sut.refreshAgentSkills()

        let resolved = sut.roleSkills?.resolve([review, tdd]) ?? []
        XCTAssertEqual(resolved.map(\.name), ["review", "tdd"])
        XCTAssertEqual(resolved.map(\.body), ["Review body", "TDD body"])
    }

    // MARK: - On-demand body reads (unsaved editor attachments)

    /// The snapshot caches bodies only for ids some role has PERSISTED. The Role
    /// editor needs the body of a skill the user just ticked — unsaved, so absent
    /// from that read set — or the cost banner prices it at zero, which is the
    /// one number that tab exists to show.
    func testSkillBodies_unsavedAttachment_isReadOnDemand() async throws {
        let id = try writeProjectSkill("tdd", body: "# TDD\nWrite the test first.")
        await sut.openWorkFolder(tempDir)

        // Nothing attached anywhere: the snapshot deliberately holds no body.
        XCTAssertNil(sut.roleSkills?.bodies[id])

        let fetched = await sut.skillBodies(forIDs: [id])
        XCTAssertEqual(fetched[id], "# TDD\nWrite the test first.")
    }

    /// An id the snapshot already carries is not re-read — the caller merges the
    /// two dictionaries, so returning it again would be pure duplicate disk I/O.
    func testSkillBodies_alreadyCachedID_isNotReturnedAgain() async throws {
        let id = try writeProjectSkill("tdd", body: "cached body")
        await sut.openWorkFolder(tempDir)
        await attach([id])
        await sut.refreshAgentSkills()
        XCTAssertEqual(sut.roleSkills?.bodies[id], "cached body")

        let fetched = await sut.skillBodies(forIDs: [id])
        XCTAssertTrue(fetched.isEmpty,
                      "Already-snapshotted bodies must not be re-read on demand")
    }

    /// Mixed batch: only the uncached half comes back.
    func testSkillBodies_mixedBatch_returnsOnlyTheUncachedOnes() async throws {
        let saved = try writeProjectSkill("saved", body: "saved body")
        let fresh = try writeProjectSkill("fresh", body: "fresh body")
        await sut.openWorkFolder(tempDir)
        await attach([saved])
        await sut.refreshAgentSkills()

        let fetched = await sut.skillBodies(forIDs: [saved, fresh])
        XCTAssertEqual(fetched, [fresh: "fresh body"])
    }

    /// A dangling id contributes nothing rather than an empty string — the tab
    /// renders it as a "Missing" row and must not price it as a real skill.
    func testSkillBodies_unknownID_isOmitted() async throws {
        await sut.openWorkFolder(tempDir)

        let fetched = await sut.skillBodies(forIDs: ["nope|project|nope/SKILL.md"])
        XCTAssertTrue(fetched.isEmpty)
    }

    /// Discovered in the catalogue but deleted before the read: still omitted,
    /// never a zero-length body that would render an empty `### Skill:` header.
    func testSkillBodies_deletedBetweenScanAndRead_isOmitted() async throws {
        let id = try writeProjectSkill("doomed", body: "body")
        await sut.openWorkFolder(tempDir)
        XCTAssertTrue(sut.roleSkills?.items.contains(where: { $0.id == id }) ?? false)

        try FileManager.default.removeItem(at: skillURL("doomed"))

        let fetched = await sut.skillBodies(forIDs: [id])
        XCTAssertTrue(fetched.isEmpty)
    }

    func testSkillBodies_emptyInput_readsNothing() async {
        await sut.openWorkFolder(tempDir)
        let fetched = await sut.skillBodies(forIDs: [])
        XCTAssertTrue(fetched.isEmpty)
    }

    /// A duplicate id in the request must not produce a duplicate read or a
    /// different result — the editor can transiently hold one while reordering.
    func testSkillBodies_duplicateID_resolvesOnce() async throws {
        let id = try writeProjectSkill("tdd", body: "body")
        await sut.openWorkFolder(tempDir)

        let fetched = await sut.skillBodies(forIDs: [id, id])
        XCTAssertEqual(fetched, [id: "body"])
    }
}
