import XCTest

@testable import NanoTeams

/// Pins the orchestrator side of agent-instruction discovery: the in-memory
/// `agentInstructions` snapshot is populated on work-folder open, refreshed on
/// demand (the same hook `startRun` fires), and edited via the persisted
/// add/remove/restore APIs.
@MainActor
final class AgentInstructionsOrchestratorTests: NTMSOrchestratorTestBase {

    private func writeFile(_ relativePath: String, _ content: String = "instructions") throws {
        let url = tempDir.appendingPathComponent(relativePath)
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The refresh memo skips a rescan when inputs are unchanged within the
    /// TTL — tests that WANT a rescan must expire it explicitly.
    private func expireScanTTL() {
        sut.agentInstructionsLastScanAt = .distantPast
    }

    // MARK: - Open / refresh

    func testOpenWorkFolder_withClaudeMd_populatesSnapshot() async throws {
        try writeFile("CLAUDE.md", "# Rules\nBe terse.")
        try writeFile("docs/AGENTS.md", "nested")

        await sut.openWorkFolder(tempDir)

        XCTAssertEqual(sut.agentInstructions?.mainFile?.relativePath, "CLAUDE.md")
        XCTAssertEqual(sut.agentInstructions?.mainFile?.injectedContent, "# Rules\nBe terse.")
        XCTAssertEqual(sut.agentInstructions?.listedPaths, ["docs/AGENTS.md"])
    }

    func testOpenWorkFolder_noInstructionFiles_snapshotEmptyNotNil() async throws {
        try writeFile("README.md")

        await sut.openWorkFolder(tempDir)

        // Real folder, just nothing to find → `.empty`, not `nil`.
        XCTAssertNotNil(sut.agentInstructions)
        XCTAssertTrue(sut.agentInstructions?.isEmpty ?? false)
    }

    func testRefreshAgentInstructions_picksUpFileAddedAfterOpen() async throws {
        await sut.openWorkFolder(tempDir)
        XCTAssertTrue(sut.agentInstructions?.isEmpty ?? true)

        // A CLAUDE.md written after open is picked up by the next refresh — the
        // same hook `startRun` fires so each run's first prompt sees fresh disk.
        try writeFile("CLAUDE.md", "added later")
        expireScanTTL()
        await sut.refreshAgentInstructions()

        XCTAssertEqual(sut.agentInstructions?.mainFile?.relativePath, "CLAUDE.md")
        XCTAssertEqual(sut.agentInstructions?.mainFile?.injectedContent, "added later")
    }

    func testRefresh_withinTTL_sameInputs_skipsRescan() async throws {
        try writeFile("CLAUDE.md", "v1")
        await sut.openWorkFolder(tempDir)
        XCTAssertEqual(sut.agentInstructions?.mainFile?.injectedContent, "v1")

        // Disk changed, but inputs are identical and the last scan just landed
        // → the memo intentionally skips (back-to-back run starts collapse).
        try writeFile("CLAUDE.md", "v2")
        await sut.refreshAgentInstructions()
        XCTAssertEqual(sut.agentInstructions?.mainFile?.injectedContent, "v1",
                       "within-TTL refresh with unchanged inputs is a no-op")

        expireScanTTL()
        await sut.refreshAgentInstructions()
        XCTAssertEqual(sut.agentInstructions?.mainFile?.injectedContent, "v2")
    }

    // MARK: - Add / remove / restore

    func testAddAgentInstructions_insideFolder_persistsAndInjects() async throws {
        try writeFile("docs/style.md", "Use tabs.")
        await sut.openWorkFolder(tempDir)

        await sut.addAgentInstructions(urls: [tempDir.appendingPathComponent("docs/style.md")])

        XCTAssertEqual(sut.workFolder?.settings.agentInstructionExtraPaths, ["docs/style.md"])
        let item = sut.agentInstructions?.items.first { $0.relativePath == "docs/style.md" }
        XCTAssertEqual(item?.source, .manual)
        XCTAssertEqual(item?.injectedContent, "Use tabs.")
        XCTAssertNil(sut.lastErrorMessage)
    }

    func testAddAgentInstructions_outsideFolder_rejectedWithBanner() async throws {
        await sut.openWorkFolder(tempDir)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString).md")
        try "x".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        await sut.addAgentInstructions(urls: [outside])

        XCTAssertEqual(sut.workFolder?.settings.agentInstructionExtraPaths, [])
        XCTAssertNotNil(sut.lastErrorMessage, "outside-folder pick must surface an error banner")
    }

    func testRemoveAgentInstruction_manual_detaches() async throws {
        try writeFile("notes.md", "n")
        await sut.openWorkFolder(tempDir)
        await sut.addAgentInstructions(urls: [tempDir.appendingPathComponent("notes.md")])
        XCTAssertEqual(sut.agentInstructions?.items.count, 1)

        await sut.removeAgentInstruction(relativePath: "notes.md")

        XCTAssertEqual(sut.workFolder?.settings.agentInstructionExtraPaths, [])
        XCTAssertTrue(sut.agentInstructions?.isEmpty ?? false)
    }

    func testRemoveAgentInstruction_discovered_excludesAndKeepsInGrid() async throws {
        try writeFile("CLAUDE.md", "claude")
        try writeFile("AGENTS.md", "agents")
        await sut.openWorkFolder(tempDir)
        XCTAssertEqual(sut.agentInstructions?.mainFile?.relativePath, "CLAUDE.md")

        await sut.removeAgentInstruction(relativePath: "CLAUDE.md")

        XCTAssertEqual(sut.workFolder?.settings.agentInstructionExcludedPaths, ["CLAUDE.md"])
        XCTAssertEqual(sut.agentInstructions?.mainFile?.relativePath, "AGENTS.md",
                       "next priority candidate becomes main")
        let excluded = sut.agentInstructions?.items.first { $0.relativePath == "CLAUDE.md" }
        XCTAssertEqual(excluded?.isExcluded, true, "excluded file stays visible in the grid")
    }

    func testRestoreAgentInstruction_reinjects() async throws {
        try writeFile("CLAUDE.md", "claude")
        await sut.openWorkFolder(tempDir)
        await sut.removeAgentInstruction(relativePath: "CLAUDE.md")
        XCTAssertNil(sut.agentInstructions?.mainFile)

        await sut.restoreAgentInstruction(relativePath: "CLAUDE.md")

        XCTAssertEqual(sut.workFolder?.settings.agentInstructionExcludedPaths, [])
        XCTAssertEqual(sut.agentInstructions?.mainFile?.relativePath, "CLAUDE.md")
    }

    // MARK: - Injection toggle (quick INJECT from the All-files list)

    func testSetAgentInstructionInjected_promotesAndDemotes() async throws {
        try writeFile("CLAUDE.md", "main")
        try writeFile("sub/AGENTS.md", "sub rules")
        await sut.openWorkFolder(tempDir)
        XCTAssertEqual(sut.agentInstructions?.injectedFiles.map(\.relativePath), ["CLAUDE.md"])

        await sut.setAgentInstructionInjected(relativePath: "sub/AGENTS.md", injected: true)
        XCTAssertEqual(sut.workFolder?.settings.agentInstructionInjectedPaths, ["sub/AGENTS.md"])
        XCTAssertEqual(sut.agentInstructions?.injectedFiles.map(\.relativePath),
                       ["CLAUDE.md", "sub/AGENTS.md"])

        await sut.setAgentInstructionInjected(relativePath: "sub/AGENTS.md", injected: false)
        XCTAssertEqual(sut.workFolder?.settings.agentInstructionInjectedPaths, [])
        XCTAssertTrue(sut.agentInstructions?.listedPaths.contains("sub/AGENTS.md") ?? false,
                      "demoted file stays path-listed")
    }

    func testSetAgentInstructionInjected_binary_reportsAndStaysListed() async throws {
        try Data([0xFF, 0xFE, 0x00, 0xFF])
            .write(to: tempDir.appendingPathComponent("GEMINI.md"))
        await sut.openWorkFolder(tempDir)
        XCTAssertTrue(sut.agentInstructions?.injectedFiles.isEmpty ?? false)

        await sut.setAgentInstructionInjected(relativePath: "GEMINI.md", injected: true)

        XCTAssertEqual(sut.workFolder?.settings.agentInstructionInjectedPaths, [],
                       "unreadable promotion is undone, no dangling override")
        XCTAssertNotNil(sut.lastInfoMessage, "user is told why nothing changed")
        XCTAssertTrue(sut.agentInstructions?.listedPaths.contains("GEMINI.md") ?? false)
    }

    func testRemoveExcludedFile_staysInPromptPathList() async throws {
        try writeFile("CLAUDE.md", "claude")
        await sut.openWorkFolder(tempDir)

        await sut.removeAgentInstruction(relativePath: "CLAUDE.md")

        XCTAssertNil(sut.agentInstructions?.mainFile, "content injection stopped")
        XCTAssertEqual(sut.agentInstructions?.listedPaths, ["CLAUDE.md"],
                       "…but the file remains in the prompt's path list")
    }

    // MARK: - Override lifecycle corners

    func testDetachExcludedManual_removesGhostExclusion() async throws {
        try writeFile("notes.md", "n")
        await sut.openWorkFolder(tempDir)
        await sut.addAgentInstructions(urls: [tempDir.appendingPathComponent("notes.md")])
        await sut.setAgentInstructionInjected(relativePath: "notes.md", injected: false)
        XCTAssertEqual(sut.workFolder?.settings.agentInstructionExcludedPaths, ["notes.md"])

        await sut.removeAgentInstruction(relativePath: "notes.md")

        XCTAssertEqual(sut.workFolder?.settings.agentInstructionExtraPaths, [])
        XCTAssertEqual(sut.workFolder?.settings.agentInstructionExcludedPaths, [],
                       "detaching a manual file must not leave a ghost exclusion behind")
        XCTAssertTrue(sut.agentInstructions?.isEmpty ?? false)
    }

    func testRestore_neverExcludedPath_noOp() async throws {
        try writeFile("CLAUDE.md", "main")
        await sut.openWorkFolder(tempDir)
        let before = sut.agentInstructions

        await sut.restoreAgentInstruction(relativePath: "never/EXCLUDED.md")

        XCTAssertEqual(sut.agentInstructions, before)
        XCTAssertEqual(sut.workFolder?.settings.agentInstructionExcludedPaths, [])
    }

    func testAddSameFileTwice_singleExtraEntry() async throws {
        try writeFile("notes.md", "n")
        await sut.openWorkFolder(tempDir)
        let url = tempDir.appendingPathComponent("notes.md")

        await sut.addAgentInstructions(urls: [url])
        await sut.addAgentInstructions(urls: [url])

        XCTAssertEqual(sut.workFolder?.settings.agentInstructionExtraPaths, ["notes.md"])
        XCTAssertEqual(sut.agentInstructions?.items.count, 1)
    }

    func testReattachExcludedDiscovered_reenablesInjection() async throws {
        try writeFile("CLAUDE.md", "claude")
        await sut.openWorkFolder(tempDir)
        await sut.removeAgentInstruction(relativePath: "CLAUDE.md")
        XCTAssertNil(sut.agentInstructions?.mainFile)

        // Re-attaching via the picker means "inject it again" — exclusion clears.
        await sut.addAgentInstructions(urls: [tempDir.appendingPathComponent("CLAUDE.md")])

        XCTAssertEqual(sut.workFolder?.settings.agentInstructionExcludedPaths, [])
        XCTAssertEqual(sut.agentInstructions?.mainFile?.relativePath, "CLAUDE.md")
    }

    func testAddDirectory_rejectedWithBanner() async throws {
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("docs"), withIntermediateDirectories: true)
        await sut.openWorkFolder(tempDir)

        await sut.addAgentInstructions(urls: [tempDir.appendingPathComponent("docs")])

        XCTAssertEqual(sut.workFolder?.settings.agentInstructionExtraPaths, [])
        XCTAssertNotNil(sut.lastErrorMessage)
    }

    // MARK: - startRun integration corners

    func testStartRun_topLevelTask_picksUpDiskChange() async throws {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "brief") else {
            return XCTFail("task not created")
        }

        try writeFile("CLAUDE.md", "fresh from disk")
        expireScanTTL()
        await sut.startRun(taskID: taskID)

        XCTAssertEqual(sut.agentInstructions?.mainFile?.injectedContent, "fresh from disk",
                       "startRun rescans so the run's first prompt sees current disk")
        await sut.pauseRun(taskID: taskID)
    }

    func testStartRun_whileAlreadyStarting_isReentrancyGuarded() async throws {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "brief") else {
            return XCTFail("task not created")
        }
        let runsBefore = sut.loadedTask(taskID)?.runs.count ?? 0

        // Simulate an in-flight startRun for the same task: the second call
        // must bail before creating a duplicate run.
        sut.startingRunTaskIDs.insert(taskID)
        await sut.startRun(taskID: taskID)
        sut.startingRunTaskIDs.remove(taskID)

        XCTAssertEqual(sut.loadedTask(taskID)?.runs.count ?? 0, runsBefore,
                       "guarded startRun must not create a run")
    }

    func testSettingsPersistence_roundTripsThroughDisk() async throws {
        try writeFile("CLAUDE.md", "claude")
        try writeFile("extra.md", "extra")
        await sut.openWorkFolder(tempDir)
        await sut.addAgentInstructions(urls: [tempDir.appendingPathComponent("extra.md")])
        await sut.removeAgentInstruction(relativePath: "CLAUDE.md")

        // Reopen the same folder: overrides come back from settings.json.
        await sut.openWorkFolder(tempDir)

        XCTAssertEqual(sut.workFolder?.settings.agentInstructionExtraPaths, ["extra.md"])
        XCTAssertEqual(sut.workFolder?.settings.agentInstructionExcludedPaths, ["CLAUDE.md"])
        XCTAssertNil(sut.agentInstructions?.mainFile, "exclusion survives reopen")
        XCTAssertEqual(
            sut.agentInstructions?.items.first { $0.relativePath == "extra.md" }?.injectedContent,
            "extra")
    }
}
