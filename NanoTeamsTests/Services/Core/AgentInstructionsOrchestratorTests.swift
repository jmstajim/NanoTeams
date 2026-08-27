import XCTest

@testable import NanoTeams

/// Pins the orchestrator side of agent-instruction discovery: the in-memory
/// `agentInstructions` snapshot is populated on work-folder open, refreshed on
/// demand (the same hook `startRun` fires), and edited via the persisted
/// add/remove/restore APIs.
@MainActor
final class AgentInstructionsOrchestratorTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private func writeFile(_ relativePath: String, _ content: String = "instructions") throws {
        let url = tempDir.appendingPathComponent(relativePath)
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The DISCOVERY window — "which instruction files exist" — is memoised;
    /// CONTENT is re-read on every refresh. Tests that want a fresh WALK (a file
    /// created since the last one) must expire it explicitly. Tests that want fresh
    /// BYTES must not: that is unconditional.
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

    /// The window covers DISCOVERY only. It used to cover content too, at 5
    /// seconds — which meant a send inside the window silently used yesterday's
    /// `CLAUDE.md`, and a send outside it (i.e. every real one, since composing a
    /// message takes longer than five seconds) paid a full recursive walk of the
    /// work folder. Both halves were wrong in opposite directions.
    func testRefresh_withinTheWindow_stillPicksUpAnEditedFile() async throws {
        try writeFile("CLAUDE.md", "v1")
        await sut.openWorkFolder(tempDir)
        XCTAssertEqual(sut.agentInstructions?.mainFile?.injectedContent, "v1")

        try writeFile("CLAUDE.md", "v2")
        await sut.refreshAgentInstructions()

        XCTAssertEqual(sut.agentInstructions?.mainFile?.injectedContent, "v2",
                       "Content is re-read unconditionally — an edit reaches the next prompt")
    }

    /// The other half, and the deliberate narrowing: a file that did not exist when
    /// the folder was walked is not discovered until the window lapses (or a
    /// Settings edit changes the scan key, or the folder is reopened).
    func testRefresh_withinTheWindow_doesNotDiscoverANewFile() async throws {
        try writeFile("CLAUDE.md", "root")
        await sut.openWorkFolder(tempDir)

        try writeFile("docs/AGENTS.md", "nested")
        await sut.refreshAgentInstructions()

        XCTAssertFalse(
            sut.agentInstructions?.items.contains { $0.relativePath == "docs/AGENTS.md" } ?? true,
            "Discovery is what the window gates")

        expireScanTTL()
        await sut.refreshAgentInstructions()
        XCTAssertTrue(
            sut.agentInstructions?.items.contains { $0.relativePath == "docs/AGENTS.md" } ?? false)
    }

    /// A content re-read says nothing about whether new files appeared, so it must
    /// not renew the window. If it did, a folder someone sends to every 30 seconds
    /// would never run discovery again — the window would be kept alive by exactly
    /// the calls that do not answer its question.
    func testContentReread_doesNotRenewTheDiscoveryWindow() async throws {
        try writeFile("CLAUDE.md", "v1")
        await sut.openWorkFolder(tempDir)
        let stampAfterWalk = sut.agentInstructionsLastScanAt

        try writeFile("CLAUDE.md", "v2")
        await sut.refreshAgentInstructions()

        XCTAssertEqual(sut.agentInstructionsLastScanAt, stampAfterWalk,
                       "Only a walk may stamp the discovery window")
    }

    /// A file deleted since the walk must leave the snapshot on the next refresh —
    /// otherwise the prompt keeps listing a path the sandboxed `read_file` would
    /// refuse, until the window lapses.
    func testRefresh_dropsAnInjectedFileThatHasBeenDeleted() async throws {
        try writeFile("CLAUDE.md", "v1")
        await sut.openWorkFolder(tempDir)
        XCTAssertEqual(sut.agentInstructions?.mainFile?.relativePath, "CLAUDE.md")

        try FileManager.default.removeItem(at: tempDir.appendingPathComponent("CLAUDE.md"))
        await sut.refreshAgentInstructions()

        XCTAssertTrue(sut.agentInstructions?.isEmpty ?? false,
                      "A vanished file is dropped, not left in the path list")
    }

    /// An injected file that has become unreadable (turned binary) demotes from
    /// content-injected to path-listed — the same outcome a full walk produces,
    /// because the role can still be told the path exists.
    func testRefresh_demotesAnInjectedFileThatBecameUnreadable() async throws {
        try writeFile("CLAUDE.md", "v1")
        try writeFile("docs/notes.md", "readable")
        await sut.openWorkFolder(tempDir)
        await sut.addAgentInstructions(urls: [tempDir.appendingPathComponent("docs/notes.md")])
        XCTAssertNotNil(
            sut.agentInstructions?.items.first { $0.relativePath == "docs/notes.md" }?.injectedContent)

        try Data([0xFF, 0xFE, 0x00, 0x01])
            .write(to: tempDir.appendingPathComponent("docs/notes.md"))
        await sut.refreshAgentInstructions()

        let item = sut.agentInstructions?.items.first { $0.relativePath == "docs/notes.md" }
        XCTAssertNotNil(item, "still listed")
        XCTAssertNil(item?.injectedContent, "…but no longer content-injected")
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
        _ = sut.engineState.beginRunStart(taskID)
        await sut.startRun(taskID: taskID)
        sut.engineState.endRunStart(taskID)

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
