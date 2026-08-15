import XCTest

@testable import NanoTeams

/// Covers the artifact half of `LLMExecutionService+ConsultationChat`: the three
/// private context builders (`buildOwnArtifactsContext` / `buildUpstreamArtifactsContext`
/// / `buildArtifactUpdateMessage`), their disk-reading dependency `readArtifactContent`,
/// and the pure collectors that feed them.
///
/// The three builders are `private`, so every one of them is driven through the real
/// entry point `getOrCreateConsultationChat` — the new-chat branch reaches the two
/// "own"/"upstream" builders, the existing-chat branch reaches the update builder.
/// Artifacts are written as REAL files into a temp `.nanoteams/` tree so
/// `readArtifactContent` executes its success arm as well as each of its four
/// failure arms (no work folder, no/empty `relativePath`, missing file, non-UTF-8),
/// plus the `ArtifactConstants.maxContentBytes` byte cap.
///
/// Filler characters are chosen so they appear NOWHERE else in the rendered message
/// (`X` / `Y` / `Z` — absent from every header, fence and truncation marker), which
/// makes `filter { $0 == "X" }.count` an exact assertion on the character cap.
@MainActor
final class ConsultationChatArtifactContextTests: XCTestCase {

    private var service: LLMExecutionService!
    /// A service with NO delegate attached — pins `readArtifactContent`'s
    /// `guard let delegate` arm, which no amount of delegate scripting can reach.
    private var detachedService: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var tempDir: URL!

    private let ownRoleID = "team_pm"
    private let upstreamRoleID = "team_software_engineer"

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        service = LLMExecutionService(repository: NTMSRepository())
        detachedService = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("consult-artifacts-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        mockDelegate.workFolderURL = tempDir
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        mockDelegate = nil
        detachedService = nil
        service = nil
        try await super.tearDown()
    }

    // MARK: - readArtifactContent: success + the byte cap

    func testReadArtifactContent_realFileOnDisk_returnsExactContent() async throws {
        let artifact = try writeArtifact(
            name: "Product Requirements",
            relativePath: "tasks/1/runs/0/roles/team_pm/artifact_product_requirements.md",
            text: "# PRD\n\nShip the calculator."
        )

        let content = service.readArtifactContent(artifact)

        XCTAssertEqual(content, "# PRD\n\nShip the calculator.",
                       "A readable artifact must come back byte-for-byte from <root>/.nanoteams/<relativePath>.")
    }

    func testReadArtifactContent_overByteCap_truncatesWithMarker() async throws {
        // 60 KB of ASCII — comfortably past the 50 KB cap, and 1 byte == 1 Character
        // so the byte prefix can never land mid-scalar and fail UTF-8 decoding.
        let big = String(repeating: "A", count: 60_000)
        let artifact = try writeArtifact(
            name: "Huge Notes",
            relativePath: "tasks/1/runs/0/roles/team_pm/artifact_huge_notes.md",
            text: big
        )

        let content = service.readArtifactContent(artifact)

        XCTAssertNotNil(content, "An over-cap artifact must be truncated, not dropped.")
        XCTAssertTrue(content?.hasSuffix("\n... (truncated)") ?? false,
                      "The cap must be announced, not applied silently. got length: "
                      + String(content?.count ?? -1))
        XCTAssertEqual(content?.filter({ $0 == "A" }).count, ArtifactConstants.maxContentBytes,
                       "Exactly maxContentBytes of payload survives the cap.")
    }

    // MARK: - readArtifactContent: every failure arm

    func testReadArtifactContent_noWorkFolder_returnsNil() async {
        mockDelegate.workFolderURL = nil
        let artifact = Artifact(name: "Anything", relativePath: "tasks/1/x.md")

        XCTAssertNil(service.readArtifactContent(artifact),
                     "Without a work folder there is no root to resolve against.")
    }

    func testReadArtifactContent_noDelegate_returnsNil() async {
        let artifact = Artifact(name: "Anything", relativePath: "tasks/1/x.md")

        XCTAssertNil(detachedService.readArtifactContent(artifact),
                     "A detached service must not crash or fabricate content.")
    }

    func testReadArtifactContent_nilRelativePath_returnsNil() async {
        let artifact = Artifact(name: "Never Persisted")

        XCTAssertNil(service.readArtifactContent(artifact),
                     "An artifact with no persisted payload has no content to read.")
    }

    func testReadArtifactContent_emptyRelativePath_returnsNil() async {
        let artifact = Artifact(name: "Empty Path", relativePath: "")

        XCTAssertNil(service.readArtifactContent(artifact),
                     "An empty relativePath must not resolve to the .nanoteams directory itself.")
    }

    func testReadArtifactContent_missingFile_returnsNil() async {
        let artifact = Artifact(
            name: "Ghost",
            relativePath: "tasks/9/runs/0/roles/ghost/artifact_ghost.md"
        )

        XCTAssertNil(service.readArtifactContent(artifact),
                     "A relativePath pointing at nothing must fail closed, not throw.")
    }

    func testReadArtifactContent_nonUTF8Bytes_returnsNil() async throws {
        // 0xFF is not a legal byte anywhere in UTF-8, so decoding cannot succeed.
        let artifact = try writeArtifact(
            name: "Binary Blob",
            relativePath: "tasks/1/runs/0/roles/team_pm/artifact_binary_blob.md",
            data: Data([0xFF, 0xFE, 0x00, 0xFF, 0xFE])
        )

        XCTAssertNil(service.readArtifactContent(artifact),
                     "Undecodable bytes must read as 'no content', never as mojibake.")
    }

    // MARK: - collectNewArtifacts: dedup semantics against the already-injected set

    func testCollectNewArtifacts_emptyRun_returnsEmpty() async {
        let result = service.collectNewArtifacts(run: Run(id: 0), alreadyInjected: [])

        XCTAssertTrue(result.isEmpty, "A run with no steps has nothing to inject.")
    }

    func testCollectNewArtifacts_stepsWithNoArtifacts_returnsEmpty() async {
        let run = Run(id: 0, steps: [
            makeStep(id: ownRoleID, role: .productManager, artifacts: []),
            makeStep(id: upstreamRoleID, role: .softwareEngineer, artifacts: []),
        ])

        let result = service.collectNewArtifacts(run: run, alreadyInjected: [])

        XCTAssertTrue(result.isEmpty, "Steps that produced nothing contribute nothing.")
    }

    func testCollectNewArtifacts_emptyAlreadyInjected_returnsEveryArtifact() async {
        let run = Run(id: 0, steps: [
            makeStep(id: ownRoleID, role: .productManager,
                     artifacts: [Artifact(name: "Product Requirements")]),
            makeStep(id: upstreamRoleID, role: .softwareEngineer,
                     artifacts: [Artifact(name: "Engineering Notes")]),
        ])

        let result = service.collectNewArtifacts(run: run, alreadyInjected: [])

        XCTAssertEqual(Set(result.map(\.id)), ["product_requirements", "engineering_notes"],
                       "An empty injected-set means the whole run is new.")
    }

    func testCollectNewArtifacts_fullOverlap_returnsEmpty() async {
        let run = Run(id: 0, steps: [
            makeStep(id: ownRoleID, role: .productManager,
                     artifacts: [Artifact(name: "Product Requirements")]),
            makeStep(id: upstreamRoleID, role: .softwareEngineer,
                     artifacts: [Artifact(name: "Engineering Notes")]),
        ])

        let result = service.collectNewArtifacts(
            run: run, alreadyInjected: ["product_requirements", "engineering_notes"]
        )

        XCTAssertTrue(result.isEmpty,
                      "Nothing may be re-injected once every id is already in the chat.")
    }

    func testCollectNewArtifacts_partialOverlap_returnsOnlyTheUninjectedOnes() async {
        let run = Run(id: 0, steps: [
            makeStep(id: ownRoleID, role: .productManager,
                     artifacts: [Artifact(name: "Product Requirements"),
                                 Artifact(name: "Design Spec")]),
            makeStep(id: upstreamRoleID, role: .softwareEngineer,
                     artifacts: [Artifact(name: "Engineering Notes")]),
        ])

        let result = service.collectNewArtifacts(
            run: run, alreadyInjected: ["product_requirements"]
        )

        XCTAssertEqual(Set(result.map(\.id)), ["design_spec", "engineering_notes"],
                       "Only the delta is injected — the already-seen artifact is skipped.")
    }

    /// The injected-set is keyed by `Artifact.id`, which is the SLUG of the name, not
    /// the display name. A set holding the display name would re-inject every round.
    func testCollectNewArtifacts_matchesBySlugID_notDisplayName() async {
        let run = Run(id: 0, steps: [
            makeStep(id: ownRoleID, role: .productManager,
                     artifacts: [Artifact(name: "Product Requirements")]),
        ])

        let bySlug = service.collectNewArtifacts(
            run: run, alreadyInjected: ["product_requirements"])
        let byDisplayName = service.collectNewArtifacts(
            run: run, alreadyInjected: ["Product Requirements"])

        XCTAssertTrue(bySlug.isEmpty, "The slug id is the dedup key.")
        XCTAssertEqual(byDisplayName.count, 1,
                       "A display name in the injected-set must NOT suppress the artifact.")
    }

    // MARK: - collectAllArtifactIDs

    func testCollectAllArtifactIDs_emptyRun_returnsEmptySet() async {
        XCTAssertTrue(service.collectAllArtifactIDs(run: Run(id: 0)).isEmpty)
    }

    func testCollectAllArtifactIDs_acrossSteps_dedupesBySlug() async {
        // Two steps produce artifacts whose names slugify to the SAME id.
        let run = Run(id: 0, steps: [
            makeStep(id: ownRoleID, role: .productManager,
                     artifacts: [Artifact(name: "Design Spec")]),
            makeStep(id: upstreamRoleID, role: .softwareEngineer,
                     artifacts: [Artifact(name: "design spec"),
                                 Artifact(name: "Engineering Notes")]),
        ])

        let ids = service.collectAllArtifactIDs(run: run)

        XCTAssertEqual(ids, ["design_spec", "engineering_notes"],
                       "Ids are slugs, so two spellings of one name collapse to one entry.")
    }

    // MARK: - collectUpstreamArtifacts

    func testCollectUpstreamArtifacts_excludesTheConsultedRolesOwnStep() async {
        let run = Run(id: 0, steps: [
            makeStep(id: ownRoleID, role: .productManager,
                     artifacts: [Artifact(name: "Product Requirements")]),
            makeStep(id: upstreamRoleID, role: .softwareEngineer,
                     artifacts: [Artifact(name: "Engineering Notes")]),
        ])

        let upstream = service.collectUpstreamArtifacts(run: run, excludeRoleID: ownRoleID)

        XCTAssertEqual(upstream.map(\.id), ["engineering_notes"],
                       "A role's own output belongs to the 'Your produced artifacts' block, not the team block.")
    }

    func testCollectUpstreamArtifacts_onlyOwnStepExists_returnsEmpty() async {
        let run = Run(id: 0, steps: [
            makeStep(id: ownRoleID, role: .productManager,
                     artifacts: [Artifact(name: "Product Requirements")]),
        ])

        XCTAssertTrue(service.collectUpstreamArtifacts(run: run, excludeRoleID: ownRoleID).isEmpty)
    }

    // MARK: - buildOwnArtifactsContext (new-chat branch)

    func testNewChat_ownArtifact_injectsHeaderAndFencedContentAfterTheTaskTurn() async throws {
        let own = try writeArtifact(
            name: "Product Requirements",
            relativePath: "tasks/1/runs/0/roles/team_pm/artifact_product_requirements.md",
            text: "Calculator must add and subtract."
        )
        let chat = makeChat(ownArtifacts: [own])

        XCTAssertEqual(chat.messages.count, 3,
                       "system + task context + own artifacts, and nothing else.")
        XCTAssertEqual(chat.messages[2].role, .user,
                       "Artifact context rides the user channel (it is data, not instruction).")
        let msg = chat.messages[2].content
        XCTAssertTrue(msg.hasPrefix("Your produced artifacts:"), "got: \(msg.prefix(60))")
        XCTAssertTrue(msg.contains("[Product Requirements]:\n```\nCalculator must add and subtract.\n```"),
                      "Content must be fenced under its bracketed name. got: \(msg)")
    }

    func testNewChat_ownArtifactWithNoPersistedFile_saysContentNotAvailable() async {
        let chat = makeChat(ownArtifacts: [Artifact(name: "Never Persisted")])

        let msg = chat.messages[2].content
        XCTAssertTrue(msg.contains("[Never Persisted]: (content not available)"),
                      "An unreadable OWN artifact must say so — the role produced it and needs to know. got: \(msg)")
        XCTAssertFalse(msg.contains("```"),
                       "No fence may be opened for content that does not exist.")
    }

    func testNewChat_ownArtifactOver2000Chars_truncatesWithMarker() async throws {
        let own = try writeArtifact(
            name: "Big Doc",
            relativePath: "tasks/1/runs/0/roles/team_pm/artifact_big_doc.md",
            text: String(repeating: "X", count: 2500)
        )
        let chat = makeChat(ownArtifacts: [own])

        let msg = chat.messages[2].content
        XCTAssertEqual(msg.filter({ $0 == "X" }).count, 2000,
                       "Own-artifact content is capped at 2000 characters.")
        XCTAssertTrue(msg.contains("... (truncated)"),
                      "The cut must be announced so the role knows the doc continues.")
    }

    func testNewChat_ownArtifactExactly2000Chars_isNotMarkedTruncated() async throws {
        let own = try writeArtifact(
            name: "Big Doc",
            relativePath: "tasks/1/runs/0/roles/team_pm/artifact_big_doc.md",
            text: String(repeating: "X", count: 2000)
        )
        let chat = makeChat(ownArtifacts: [own])

        let msg = chat.messages[2].content
        XCTAssertEqual(msg.filter({ $0 == "X" }).count, 2000)
        XCTAssertFalse(msg.contains("... (truncated)"),
                       "Exactly at the cap nothing was cut — claiming truncation would be a lie.")
    }

    // MARK: - buildUpstreamArtifactsContext (new-chat branch)

    func testNewChat_upstreamArtifact_injectsTeamHeaderAndFencedContent() async throws {
        let upstream = try writeArtifact(
            name: "Engineering Notes",
            relativePath: "tasks/1/runs/0/roles/team_software_engineer/artifact_engineering_notes.md",
            text: "Used a state machine."
        )
        let chat = makeChat(ownArtifacts: [], upstreamArtifacts: [upstream])

        XCTAssertEqual(chat.messages.count, 3,
                       "system + task context + upstream artifacts (the own block is skipped).")
        let msg = chat.messages[2].content
        XCTAssertTrue(msg.hasPrefix("Available team artifacts:"), "got: \(msg.prefix(60))")
        XCTAssertTrue(msg.contains("[Engineering Notes]:\n```\nUsed a state machine.\n```"),
                      "got: \(msg)")
    }

    func testNewChat_ownAndUpstream_areSeparateTurnsInOrder() async throws {
        let own = try writeArtifact(
            name: "Product Requirements",
            relativePath: "tasks/1/runs/0/roles/team_pm/artifact_product_requirements.md",
            text: "own body"
        )
        let upstream = try writeArtifact(
            name: "Engineering Notes",
            relativePath: "tasks/1/runs/0/roles/team_software_engineer/artifact_engineering_notes.md",
            text: "upstream body"
        )
        let chat = makeChat(ownArtifacts: [own], upstreamArtifacts: [upstream])

        XCTAssertEqual(chat.messages.count, 4)
        XCTAssertTrue(chat.messages[2].content.hasPrefix("Your produced artifacts:"),
                      "Own output comes first — it is the role's own memory.")
        XCTAssertTrue(chat.messages[3].content.hasPrefix("Available team artifacts:"))
        XCTAssertFalse(chat.messages[2].content.contains("upstream body"),
                       "The two blocks must not bleed into each other.")
        XCTAssertFalse(chat.messages[3].content.contains("own body"))
    }

    func testNewChat_upstreamArtifactOver1500Chars_truncatesWithMarker() async throws {
        let upstream = try writeArtifact(
            name: "Long Notes",
            relativePath: "tasks/1/runs/0/roles/team_software_engineer/artifact_long_notes.md",
            text: String(repeating: "Y", count: 1800)
        )
        let chat = makeChat(ownArtifacts: [], upstreamArtifacts: [upstream])

        let msg = chat.messages[2].content
        XCTAssertEqual(msg.filter({ $0 == "Y" }).count, 1500,
                       "Upstream content is capped tighter (1500) than the role's own (2000).")
        XCTAssertTrue(msg.contains("... (truncated)"))
    }

    func testNewChat_unreadableUpstreamArtifact_isStillAnnouncedByName() async {
        let chat = makeChat(
            ownArtifacts: [],
            upstreamArtifacts: [Artifact(name: "Ghost Notes")]
        )

        let msg = chat.messages[2].content
        XCTAssertTrue(msg.contains("[Ghost Notes]:"),
                      "An upstream artifact with no readable payload is still worth naming — "
                      + "the role can ask for it. got: \(msg)")
        XCTAssertFalse(msg.contains("```"),
                       "No fence may be opened for content that does not exist.")
    }

    // MARK: - New-chat shape when there is nothing to inject

    func testNewChat_noArtifactsAnywhere_hasOnlySystemAndTaskTurns() async {
        let chat = makeChat(ownArtifacts: [], upstreamArtifacts: [])

        XCTAssertEqual(chat.messages.count, 2)
        XCTAssertEqual(chat.messages[0].role, .system)
        XCTAssertEqual(chat.messages[1].role, .user)
        XCTAssertFalse(chat.messages[1].content.contains("Your produced artifacts:"),
                       "An empty artifact block must not be emitted at all.")
        XCTAssertFalse(chat.messages[1].content.contains("Available team artifacts:"))
        XCTAssertTrue(chat.injectedArtifactIDs.isEmpty)
    }

    func testNewChat_injectedArtifactIDs_seededWithEveryArtifactInTheRun() async throws {
        let own = try writeArtifact(
            name: "Product Requirements",
            relativePath: "tasks/1/runs/0/roles/team_pm/artifact_product_requirements.md",
            text: "prd"
        )
        let chat = makeChat(
            ownArtifacts: [own],
            upstreamArtifacts: [Artifact(name: "Engineering Notes")]
        )

        XCTAssertEqual(chat.injectedArtifactIDs, ["product_requirements", "engineering_notes"],
                       "A freshly seeded chat has already 'seen' the whole run, so the next "
                       + "getOrCreate must not re-inject any of it.")
    }

    /// The three builders are siblings with identical shape, but only
    /// `buildOwnArtifactsContext` ever had the `else` arm. In the other two an
    /// unreadable artifact rendered as a bare `[Name]:` running straight into
    /// the next entry — indistinguishable, to the model, from an artifact that
    /// was genuinely submitted empty. It would then reason about content that
    /// exists but could not be read, and say nothing about the gap.
    func testNewChat_upstreamArtifactWithNoPersistedFile_saysContentNotAvailable() async {
        let chat = makeChat(
            ownArtifacts: [], upstreamArtifacts: [Artifact(name: "Never Persisted")])

        let msg = chat.messages[2].content
        XCTAssertTrue(msg.contains("[Never Persisted]: (content not available)"),
                      "an unreadable UPSTREAM artifact must say so too. got: \(msg)")
        XCTAssertFalse(msg.contains("```"),
                       "no fence may be opened for content that does not exist")
    }

    /// Same arm, the other builder. This is the likelier one to hit in practice:
    /// the update path fires mid-consultation, when a producing role has just
    /// written a file the consulting role may not be able to read yet.
    func testExistingChat_unreadableNewArtifact_saysContentNotAvailable() async {
        let task = makeTask(
            ownArtifacts: [],
            upstreamArtifacts: [Artifact(name: "Never Persisted")],
            existingChat: seededChat(injected: []))

        let chat = service.getOrCreateConsultationChat(
            roleID: ownRoleID, task: task, runIndex: 0, team: makeTeam())

        let update = chat.messages[1].content
        XCTAssertTrue(update.hasPrefix("New artifacts available:"), "got: \(update)")
        XCTAssertTrue(update.contains("[Never Persisted]: (content not available)"),
                      "got: \(update)")
        XCTAssertFalse(update.contains("```"))
    }

    // MARK: - buildArtifactUpdateMessage (existing-chat branch)

    func testExistingChat_newArtifactAppears_appendsUpdateTurnAndRecordsTheID() async throws {
        let fresh = try writeArtifact(
            name: "Engineering Notes",
            relativePath: "tasks/1/runs/0/roles/team_software_engineer/artifact_engineering_notes.md",
            text: "Shipped behind a flag."
        )
        let task = makeTask(
            ownArtifacts: [],
            upstreamArtifacts: [fresh],
            existingChat: seededChat(injected: [])
        )

        let chat = service.getOrCreateConsultationChat(
            roleID: ownRoleID, task: task, runIndex: 0, team: makeTeam())

        XCTAssertEqual(chat.messages.count, 2, "The seeded turn survives; exactly one update is appended.")
        XCTAssertEqual(chat.messages[0].content, "SEEDED-HISTORY",
                       "The existing branch must NOT rebuild the system prompt or task turn.")
        let update = chat.messages[1]
        XCTAssertEqual(update.role, .user)
        XCTAssertTrue(update.content.hasPrefix("New artifacts available:"), "got: \(update.content)")
        XCTAssertTrue(update.content.contains("[Engineering Notes]:\n```\nShipped behind a flag.\n```"),
                      "got: \(update.content)")
        XCTAssertTrue(chat.injectedArtifactIDs.contains("engineering_notes"),
                      "The id must be recorded or the same artifact re-injects every round.")
    }

    func testExistingChat_nothingNew_isReturnedUntouched() async throws {
        let known = try writeArtifact(
            name: "Engineering Notes",
            relativePath: "tasks/1/runs/0/roles/team_software_engineer/artifact_engineering_notes.md",
            text: "Shipped behind a flag."
        )
        let task = makeTask(
            ownArtifacts: [],
            upstreamArtifacts: [known],
            existingChat: seededChat(injected: ["engineering_notes"])
        )

        let chat = service.getOrCreateConsultationChat(
            roleID: ownRoleID, task: task, runIndex: 0, team: makeTeam())

        XCTAssertEqual(chat.messages.count, 1, "No delta ⇒ no appended turn.")
        XCTAssertEqual(chat.messages[0].content, "SEEDED-HISTORY")
        XCTAssertEqual(chat.injectedArtifactIDs, ["engineering_notes"],
                       "A no-op round must not mutate the injected-set either.")
    }

    func testExistingChat_partialOverlap_listsOnlyTheNewArtifact() async throws {
        let known = try writeArtifact(
            name: "Product Requirements",
            relativePath: "tasks/1/runs/0/roles/team_pm/artifact_product_requirements.md",
            text: "KNOWN-BODY"
        )
        let fresh = try writeArtifact(
            name: "Engineering Notes",
            relativePath: "tasks/1/runs/0/roles/team_software_engineer/artifact_engineering_notes.md",
            text: "FRESH-BODY"
        )
        let task = makeTask(
            ownArtifacts: [known],
            upstreamArtifacts: [fresh],
            existingChat: seededChat(injected: ["product_requirements"])
        )

        let chat = service.getOrCreateConsultationChat(
            roleID: ownRoleID, task: task, runIndex: 0, team: makeTeam())

        let update = chat.messages[1].content
        XCTAssertTrue(update.contains("FRESH-BODY"), "got: \(update)")
        XCTAssertFalse(update.contains("KNOWN-BODY"),
                       "Re-sending an already-injected body burns context for nothing.")
        XCTAssertFalse(update.contains("[Product Requirements]:"),
                       "The already-injected artifact must not even be named again.")
        XCTAssertEqual(chat.injectedArtifactIDs, ["product_requirements", "engineering_notes"])
    }

    func testExistingChat_newArtifactOver1500Chars_truncatesWithMarker() async throws {
        let fresh = try writeArtifact(
            name: "Long Notes",
            relativePath: "tasks/1/runs/0/roles/team_software_engineer/artifact_long_notes.md",
            text: String(repeating: "Z", count: 1900)
        )
        let task = makeTask(
            ownArtifacts: [],
            upstreamArtifacts: [fresh],
            existingChat: seededChat(injected: [])
        )

        let chat = service.getOrCreateConsultationChat(
            roleID: ownRoleID, task: task, runIndex: 0, team: makeTeam())

        let update = chat.messages[1].content
        XCTAssertEqual(update.filter({ $0 == "Z" }).count, 1500,
                       "The update message shares the upstream 1500-character cap.")
        XCTAssertTrue(update.contains("... (truncated)"))
    }

    func testExistingChat_unreadableNewArtifact_isAnnouncedByNameAndStillMarkedInjected() async {
        let task = makeTask(
            ownArtifacts: [],
            upstreamArtifacts: [Artifact(name: "Ghost Notes")],
            existingChat: seededChat(injected: [])
        )

        let chat = service.getOrCreateConsultationChat(
            roleID: ownRoleID, task: task, runIndex: 0, team: makeTeam())

        let update = chat.messages[1].content
        XCTAssertTrue(update.contains("[Ghost Notes]:"), "got: \(update)")
        XCTAssertFalse(update.contains("```"))
        XCTAssertTrue(chat.injectedArtifactIDs.contains("ghost_notes"),
                      "Even an unreadable artifact must be marked injected, or it re-announces forever.")
    }

    // MARK: - Fixtures

    private func makeTeam() -> Team {
        let pm = TeamRoleDefinition(
            id: ownRoleID, name: "Product Manager", prompt: "p",
            toolIDs: [ToolNames.askTeammate], usePlanningPhase: false,
            dependencies: RoleDependencies(), systemRoleID: "productManager"
        )
        let swe = TeamRoleDefinition(
            id: upstreamRoleID, name: "Software Engineer", prompt: "p",
            toolIDs: [ToolNames.askTeammate], usePlanningPhase: false,
            dependencies: RoleDependencies(), systemRoleID: "softwareEngineer"
        )
        return Team(
            name: "TestTeam", roles: [pm, swe], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout()
        )
    }

    private func makeStep(id: String, role: Role, artifacts: [Artifact]) -> StepExecution {
        StepExecution(id: id, role: role, title: "\(id) step",
                      status: .done, artifacts: artifacts)
    }

    private func makeTask(
        ownArtifacts: [Artifact],
        upstreamArtifacts: [Artifact] = [],
        existingChat: RoleConsultationChat? = nil
    ) -> NTMSTask {
        var steps = [makeStep(id: ownRoleID, role: .productManager, artifacts: ownArtifacts)]
        if !upstreamArtifacts.isEmpty {
            steps.append(makeStep(id: upstreamRoleID, role: .softwareEngineer,
                                  artifacts: upstreamArtifacts))
        }
        var run = Run(id: 0, steps: steps)
        if let existingChat = existingChat { run.consultationChats[ownRoleID] = existingChat }
        return NTMSTask(id: 1, title: "Test Task", supervisorTask: "Build a calculator", runs: [run])
    }

    /// Drives the REAL new-chat entry point and returns the produced chat.
    private func makeChat(
        ownArtifacts: [Artifact],
        upstreamArtifacts: [Artifact] = []
    ) -> RoleConsultationChat {
        service.getOrCreateConsultationChat(
            roleID: ownRoleID,
            task: makeTask(ownArtifacts: ownArtifacts, upstreamArtifacts: upstreamArtifacts),
            runIndex: 0,
            team: makeTeam()
        )
    }

    /// A pre-existing chat carrying one recognisable turn, so a test can tell the
    /// existing-chat branch (turn survives) from the new-chat branch (rebuilt).
    private func seededChat(injected: Set<String>) -> RoleConsultationChat {
        RoleConsultationChat(
            id: ownRoleID,
            messages: [LLMMessage(role: .system, content: "SEEDED-HISTORY")],
            injectedArtifactIDs: injected
        )
    }

    @discardableResult
    private func writeArtifact(
        name: String, relativePath: String, text: String
    ) throws -> Artifact {
        return try writeArtifact(
            name: name, relativePath: relativePath, data: Data(text.utf8))
    }

    /// Writes REAL bytes at `<tempDir>/.nanoteams/<relativePath>` — the exact path
    /// `ArtifactService.readContent` resolves — so `readArtifactContent` does real I/O.
    @discardableResult
    private func writeArtifact(
        name: String, relativePath: String, data: Data
    ) throws -> Artifact {
        let url = tempDir
            .appendingPathComponent(".nanoteams", isDirectory: true)
            .appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return Artifact(name: name, relativePath: relativePath)
    }
}
