import XCTest
@testable import NanoTeams

/// Lifecycle + mirror invariants for the Autovisor Goal composer's attachments
/// and skill/clip cards. All paths are file ops + in-memory task mutation — no
/// engine, no LM Studio.
@MainActor
final class AutovisorGoalAttachmentTests: NTMSOrchestratorTestBase {

    /// Opens the temp work folder and pins a freshly-created (non-running) task as
    /// the manager, without enabling the feature (no engine/LLM started).
    private func openAndPinManager() async -> Int {
        await sut.openWorkFolder(tempDir)
        let mgrID = await sut.createTask(title: "Manager", supervisorTask: "oversee", makeActive: false)!
        await sut.mutateWorkFolder { $0.state.autovisorTaskID = mgrID }
        return mgrID
    }

    /// A readable text file OUTSIDE the work folder → gets copied into the store.
    private func makeExternalFile(name: String, content: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try! content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func settings() -> ProjectSettings? { sut.snapshot?.workFolder.settings }

    // MARK: - Staging

    func testStage_externalFile_copiesIntoStore_notAReference() async throws {
        _ = await openAndPinManager()
        let src = makeExternalFile(name: "notes.txt", content: "hello")

        let staged = sut.stageAutovisorGoalAttachment(url: src)
        let card = try XCTUnwrap(staged)

        XCTAssertFalse(card.isProjectReference, "an external file is copied, not referenced")
        XCTAssertTrue(card.stagedRelativePath.contains("autovisor/attachments"),
                      "external files land in the folder-level goal store")
        XCTAssertTrue(FileManager.default.fileExists(atPath: card.url.path),
                      "the finalized copy must exist on disk")
    }

    func testStage_inProjectFile_isReference_noCopy() async throws {
        _ = await openAndPinManager()
        // A file already inside the work folder (outside .nanoteams/).
        let inFolder = tempDir.appendingPathComponent("in_repo.txt")
        try! "x".write(to: inFolder, atomically: true, encoding: .utf8)

        let card = try XCTUnwrap(sut.stageAutovisorGoalAttachment(url: inFolder))
        XCTAssertTrue(card.isProjectReference, "in-project file is referenced, not copied")
        XCTAssertFalse(card.stagedRelativePath.contains("autovisor/attachments"),
                       "a reference points at the user's real file, not the store")
    }

    // MARK: - Persist + mirror (embed OFF, the default)

    func testSetAttachmentPaths_embedOff_mirrorsPathsToManagerBrief() async throws {
        let mgrID = await openAndPinManager()
        sut.configuration.embedFilesInPrompt = false
        await sut.updateAutovisorGoal("Ship the docs")

        let staged = try XCTUnwrap(sut.stageAutovisorGoalAttachment(url: makeExternalFile(name: "a.txt", content: "alpha")))
        await sut.setAutovisorGoalAttachmentPaths([staged.stagedRelativePath])

        XCTAssertEqual(settings()?.autovisorGoalAttachmentPaths, [staged.stagedRelativePath],
                       "the path list persists to settings")
        let task = try XCTUnwrap(sut.loadedTask(mgrID))
        XCTAssertEqual(task.supervisorTask, "Ship the docs",
                       "embed OFF keeps the brief == the raw goal")
        XCTAssertEqual(task.attachmentPaths, [staged.stagedRelativePath],
                       "the path rides on the manager task → effectiveSupervisorBrief lists it")
        XCTAssertTrue(task.effectiveSupervisorBrief.contains("## Attached Files"))
        XCTAssertTrue(task.effectiveSupervisorBrief.contains(staged.stagedRelativePath))
    }

    func testSetClips_mirrorsToManagerBrief() async throws {
        let mgrID = await openAndPinManager()
        sut.configuration.embedFilesInPrompt = false
        await sut.updateAutovisorGoal("Goal text")

        await sut.setAutovisorGoalClips(["remember this"])

        XCTAssertEqual(settings()?.autovisorGoalClips, ["remember this"])
        let task = try XCTUnwrap(sut.loadedTask(mgrID))
        XCTAssertEqual(task.clippedTexts, ["remember this"])
        XCTAssertTrue(task.effectiveSupervisorBrief.contains("remember this"),
                      "the clip renders in the brief via clipSections")
    }

    // MARK: - Embed ON (gear toggle)

    func testEmbedOn_bakesFileTextIntoBrief_imageStaysAsPath() async throws {
        let mgrID = await openAndPinManager()
        sut.configuration.embedFilesInPrompt = true
        await sut.updateAutovisorGoal("Base goal")

        let text = try XCTUnwrap(sut.stageAutovisorGoalAttachment(url: makeExternalFile(name: "spec.txt", content: "SPEC BODY")))
        let image = try XCTUnwrap(sut.stageAutovisorGoalAttachment(url: makeExternalFile(name: "pic.png", content: "fakepng")))
        await sut.setAutovisorGoalAttachmentPaths([text.stagedRelativePath, image.stagedRelativePath])

        let task = try XCTUnwrap(sut.loadedTask(mgrID))
        XCTAssertTrue(task.supervisorTask.contains("## Attached File: spec.txt"),
                      "embed ON inlines readable file text into the brief")
        XCTAssertTrue(task.supervisorTask.contains("SPEC BODY"))
        XCTAssertTrue(task.clippedTexts.isEmpty, "embed ON folds clips/embeds into supervisorTask")
        XCTAssertEqual(task.attachmentPaths, [image.stagedRelativePath],
                       "the non-embeddable image stays as a path; the embedded text file does not double-list")
    }

    // MARK: - Remove + reconstruction

    func testRemove_copy_deletesFile() async throws {
        _ = await openAndPinManager()
        let staged = try XCTUnwrap(sut.stageAutovisorGoalAttachment(url: makeExternalFile(name: "gone.txt", content: "x")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.url.path))

        sut.removeAutovisorGoalFile(staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.url.path),
                       "removing a copied attachment deletes its backing file")
    }

    func testRemove_projectReference_leavesUserFileIntact() async throws {
        _ = await openAndPinManager()
        let inFolder = tempDir.appendingPathComponent("keep.txt")
        try! "keep me".write(to: inFolder, atomically: true, encoding: .utf8)
        let ref = try XCTUnwrap(sut.stageAutovisorGoalAttachment(url: inFolder))

        sut.removeAutovisorGoalFile(ref)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inFolder.path),
                      "a project reference must NEVER delete the user's real file")
    }

    func testGoalAttachments_reconstructsFromSettings_skipsMissingFile() async throws {
        _ = await openAndPinManager()
        let staged = try XCTUnwrap(sut.stageAutovisorGoalAttachment(url: makeExternalFile(name: "b.txt", content: "beta")))
        await sut.setAutovisorGoalAttachmentPaths([staged.stagedRelativePath, ".nanoteams/autovisor/attachments/ghost.txt"])

        let cards = sut.autovisorGoalAttachments
        XCTAssertEqual(cards.map(\.stagedRelativePath), [staged.stagedRelativePath],
                       "a path whose file no longer exists is skipped in the reconstructed cards")
    }

    // MARK: - Self-heal + no-manager no-op

    func testMirror_selfHealsDanglingPath() async throws {
        let mgrID = await openAndPinManager()
        await sut.updateAutovisorGoal("Goal")
        let staged = try XCTUnwrap(sut.stageAutovisorGoalAttachment(url: makeExternalFile(name: "c.txt", content: "gamma")))
        await sut.setAutovisorGoalAttachmentPaths([staged.stagedRelativePath])

        // Delete the file behind the settings path, then trigger a re-mirror.
        try! FileManager.default.removeItem(at: staged.url)
        await sut.syncAutovisorGoalToManagerBrief()

        XCTAssertEqual(settings()?.autovisorGoalAttachmentPaths, [],
                       "the dangling path is dropped from settings on re-mirror")
        let task = try XCTUnwrap(sut.loadedTask(mgrID))
        XCTAssertEqual(task.attachmentPaths, [], "and no longer rides on the manager brief")
    }

    func testMirror_noManager_isNoOp() async throws {
        await sut.openWorkFolder(tempDir)
        // No manager pinned → autovisorTaskID == nil.
        XCTAssertNil(sut.autovisorTaskID)
        await sut.setAutovisorGoalClips(["pre-enable clip"])
        // Persists to settings (survives until Enable seeds the manager), no crash.
        XCTAssertEqual(settings()?.autovisorGoalClips, ["pre-enable clip"])
    }

    // MARK: - Corner cases

    /// Staging before any work folder is open must fail softly (nil + a surfaced
    /// error), never crash. The goal composer can appear on the Setup pane before
    /// a folder is guaranteed loaded.
    func testStage_noWorkFolder_returnsNilWithError() {
        XCTAssertFalse(sut.hasRealWorkFolder, "precondition: no folder open")
        sut.lastErrorMessage = nil
        XCTAssertNil(sut.stageAutovisorGoalAttachment(url: makeExternalFile(name: "x.txt", content: "x")))
        XCTAssertNotNil(sut.lastErrorMessage, "a stage with no folder must surface why")
    }

    /// A source file that vanishes before the copy runs must fail softly — the
    /// copy throws, is caught, and no card is returned.
    func testStage_missingSourceFile_returnsNil() async {
        _ = await openAndPinManager()
        let src = makeExternalFile(name: "vanishing.txt", content: "x")
        try! FileManager.default.removeItem(at: src)
        sut.lastErrorMessage = nil
        XCTAssertNil(sut.stageAutovisorGoalAttachment(url: src))
        XCTAssertNotNil(sut.lastErrorMessage)
    }

    /// THE regression the mirror seam exists for: editing the goal TEXT while
    /// attachments are present must not drop them. The old inline `supervisorTask =
    /// goal` clobbered clips/paths; the seam re-reads them from settings every time.
    func testEditGoalText_withAttachmentsAndClipsPresent_keepsThemInBrief() async throws {
        let mgrID = await openAndPinManager()
        sut.configuration.embedFilesInPrompt = false
        await sut.updateAutovisorGoal("First goal")
        let staged = try XCTUnwrap(sut.stageAutovisorGoalAttachment(url: makeExternalFile(name: "keep.txt", content: "k")))
        await sut.setAutovisorGoalAttachmentPaths([staged.stagedRelativePath])
        await sut.setAutovisorGoalClips(["a clip"])

        // Edit ONLY the goal text.
        await sut.updateAutovisorGoal("Second goal")

        let task = try XCTUnwrap(sut.loadedTask(mgrID))
        XCTAssertEqual(task.supervisorTask, "Second goal")
        XCTAssertEqual(task.attachmentPaths, [staged.stagedRelativePath],
                       "attachments survive a goal-text edit")
        XCTAssertEqual(task.clippedTexts, ["a clip"], "clips survive a goal-text edit")
    }

    /// Clearing the attachment list re-mirrors to an empty path list on the manager.
    func testClearAttachments_removesFromBrief() async throws {
        let mgrID = await openAndPinManager()
        await sut.updateAutovisorGoal("Goal")
        let staged = try XCTUnwrap(sut.stageAutovisorGoalAttachment(url: makeExternalFile(name: "d.txt", content: "d")))
        await sut.setAutovisorGoalAttachmentPaths([staged.stagedRelativePath])
        XCTAssertEqual(try XCTUnwrap(sut.loadedTask(mgrID)).attachmentPaths, [staged.stagedRelativePath])

        await sut.setAutovisorGoalAttachmentPaths([])
        XCTAssertEqual(try XCTUnwrap(sut.loadedTask(mgrID)).attachmentPaths, [])
        XCTAssertEqual(settings()?.autovisorGoalAttachmentPaths, [])
    }

    /// Multiple attachments keep user order in both settings and the rendered brief.
    func testMultipleAttachments_orderPreservedInBrief() async throws {
        let mgrID = await openAndPinManager()
        sut.configuration.embedFilesInPrompt = false
        await sut.updateAutovisorGoal("Goal")
        let a = try XCTUnwrap(sut.stageAutovisorGoalAttachment(url: makeExternalFile(name: "one.txt", content: "1")))
        let b = try XCTUnwrap(sut.stageAutovisorGoalAttachment(url: makeExternalFile(name: "two.txt", content: "2")))
        await sut.setAutovisorGoalAttachmentPaths([a.stagedRelativePath, b.stagedRelativePath])

        let task = try XCTUnwrap(sut.loadedTask(mgrID))
        XCTAssertEqual(task.attachmentPaths, [a.stagedRelativePath, b.stagedRelativePath])
        // The rendered path list keeps that order.
        let brief = task.effectiveSupervisorBrief
        let iA = try XCTUnwrap(brief.range(of: a.stagedRelativePath)).lowerBound
        let iB = try XCTUnwrap(brief.range(of: b.stagedRelativePath)).lowerBound
        XCTAssertLessThan(iA, iB, "path list preserves attachment order")
    }

    /// Empty goal + a single attachment (embed OFF): the brief is just the path
    /// list — the manager still receives the reference with no goal prose.
    func testEmptyGoal_onlyAttachment_briefIsPathListOnly() async throws {
        let mgrID = await openAndPinManager()
        sut.configuration.embedFilesInPrompt = false
        await sut.updateAutovisorGoal("")
        let staged = try XCTUnwrap(sut.stageAutovisorGoalAttachment(url: makeExternalFile(name: "e.txt", content: "e")))
        await sut.setAutovisorGoalAttachmentPaths([staged.stagedRelativePath])

        let task = try XCTUnwrap(sut.loadedTask(mgrID))
        XCTAssertEqual(task.supervisorTask, "", "empty goal stays empty")
        let brief = task.effectiveSupervisorBrief
        XCTAssertTrue(brief.contains("## Attached Files"))
        XCTAssertTrue(brief.contains(staged.stagedRelativePath))
    }

    /// Flipping the gear's embed toggle and re-mirroring reflects the new state:
    /// the seam reads the LIVE `embedFilesInPrompt`, not a value captured at attach time.
    func testEmbedToggleFlip_reMirrorReflectsNewState() async throws {
        let mgrID = await openAndPinManager()
        await sut.updateAutovisorGoal("Goal")
        let staged = try XCTUnwrap(sut.stageAutovisorGoalAttachment(url: makeExternalFile(name: "spec.txt", content: "BODY")))

        sut.configuration.embedFilesInPrompt = false
        await sut.setAutovisorGoalAttachmentPaths([staged.stagedRelativePath])
        var task = try XCTUnwrap(sut.loadedTask(mgrID))
        XCTAssertEqual(task.supervisorTask, "Goal", "embed OFF: brief is the raw goal")
        XCTAssertEqual(task.attachmentPaths, [staged.stagedRelativePath])

        sut.configuration.embedFilesInPrompt = true
        await sut.syncAutovisorGoalToManagerBrief()
        task = try XCTUnwrap(sut.loadedTask(mgrID))
        XCTAssertTrue(task.supervisorTask.contains("BODY"), "embed ON: file text now inlined")
        XCTAssertEqual(task.attachmentPaths, [], "embedded text file no longer path-listed")
    }

    /// An in-project reference round-trips through settings reconstruction as a
    /// reference (not mistaken for a deletable store copy).
    func testGoalAttachments_inProjectReference_reconstructsAsReference() async throws {
        _ = await openAndPinManager()
        let inFolder = tempDir.appendingPathComponent("ref.txt")
        try! "ref".write(to: inFolder, atomically: true, encoding: .utf8)
        let ref = try XCTUnwrap(sut.stageAutovisorGoalAttachment(url: inFolder))
        await sut.setAutovisorGoalAttachmentPaths([ref.stagedRelativePath])

        let cards = sut.autovisorGoalAttachments
        XCTAssertEqual(cards.count, 1)
        XCTAssertTrue(cards[0].isProjectReference,
                      "a path outside the store reconstructs as a project reference")
    }
}
