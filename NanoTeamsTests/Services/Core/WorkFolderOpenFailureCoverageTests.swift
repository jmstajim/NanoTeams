import XCTest

@testable import NanoTeams

/// Pins what the process looks like after something on the work-folder open/close path fails
/// — a cluster whose members share one shape: the failure happened, and nobody could tell.
///
/// Four defects meet here.
///
///  1. `workFolderURL = url` is committed BEFORE the open can fail (deliberately — `closeProject`
///     and `resetAllData` read it as their "no project open" signal), and the catch only set a
///     banner. So a failed open left the process describing TWO folders: the new URL beside the
///     previous folder's snapshot, active task and loaded tasks. `mutateWorkFolder` binds those
///     separately and writes folder A's teams/settings/state WHOLESALE into folder B's files;
///     `mutateTask` writes folder A's task into `B/tasks/<same sequential id>/task.json`. That is
///     the collision `apply(_:)` guards against, reached through the one path where `apply`
///     never runs.
///  2. The active task's stale-status recovery persisted with a bare `try` inside the open's own
///     do/catch, so one failed write to a COSMETIC repair aborted the entire open — no snapshot,
///     no scheduler, no Autovisor, an empty app over intact data.
///  3. Turning Exploratory Search off dropped the coordinator on the line after `clear()`, taking
///     the only record of a failed delete with it.
///  4. `setAgentInstructionInjected` inferred "isn't readable text" from the path's absence in the
///     refreshed scan — which a failed settings.json write produces just as reliably as a binary
///     file, since `mutateWorkFolder` reverts memory from disk on failure.
@MainActor
final class WorkFolderOpenFailureCoverageTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private var otherDir: URL!
    /// Directories whose permissions a test narrowed; restored in tearDown or the recursive
    /// cleanup of `tempDir` fails and leaks (2026-08-08).
    private var chmodRestore: [URL] = []

    override func setUp() async throws {
        try await super.setUp()
        otherDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf19-other-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for url in chmodRestore {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        chmodRestore = []
        if let otherDir { try? FileManager.default.removeItem(at: otherDir) }
        otherDir = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// A path that cannot be a work folder: a plain FILE. `openOrCreateWorkFolder` rejects it at
    /// its `fileExists(isDirectory:)` guard, the simplest reachable open failure.
    private func makeNonFolder() throws -> URL {
        let url = tempDir.appendingPathComponent("not-a-folder.txt")
        try "x".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A REAL, fully-provisioned work folder whose open now throws. Corrupting the active task's
    /// `task.json` is the one shape that gets past every recovery wrapper: state / settings /
    /// teams / index all route through `loadOrRecoverFile`, while the active-task read is a bare
    /// `try store.read` (NTMSRepository.swift:68). This is what makes the cross-folder-write test
    /// possible at all — a folder that is otherwise intact and writable.
    private func makeCorruptButRealWorkFolder(at root: URL, contextPrompt: String) async throws {
        await sut.openWorkFolder(root)
        _ = await sut.createTask(title: "B task", supervisorTask: "b")
        await sut.updateContextPrompt(contextPrompt)
        guard let taskID = sut.activeTaskID else { return XCTFail("fixture needs an active task") }

        let paths = NTMSPaths(workFolderRoot: root)
        try "{ not json".write(
            to: paths.taskJSON(taskID: taskID), atomically: true, encoding: .utf8)
        // Leave the orchestrator pointing nowhere in particular; each test opens what it needs.
        sut = TestOrchestrator.make(
            embeddingClient: embeddingClient, chatLifecycleClient: chatLifecycleClient)
    }

    private func settingsBytes(of root: URL) -> Data? {
        try? Data(contentsOf: NTMSPaths(workFolderRoot: root).settingsJSON)
    }

    // MARK: - 1. A failed open leaves ONE folder described

    /// RED: delete `discardWorkFolderState()` from the catch → `snapshot`, `activeTask` and
    /// `activeTaskID` still describe folder A while `workFolderURL` is the folder that failed.
    func testFailedOpen_dropsThePreviousFoldersState() async throws {
        await sut.openWorkFolder(tempDir)
        _ = await sut.createTask(title: "A task", supervisorTask: "a")
        XCTAssertNotNil(sut.snapshot)
        XCTAssertNotNil(sut.activeTask)

        let bogus = try makeNonFolder()
        await sut.openWorkFolder(bogus)

        XCTAssertEqual(sut.workFolderURL, bogus, "the URL commit is deliberate and stays")
        XCTAssertNil(sut.snapshot, "the previous folder's snapshot must not survive")
        XCTAssertNil(sut.activeTask)
        XCTAssertNil(sut.activeTaskID)
        XCTAssertNotNil(sut.lastErrorMessage)
    }

    /// The consequence, end to end: after a failed open, a perfectly ordinary settings mutation
    /// must not reach the folder that failed to open.
    ///
    /// RED: delete `discardWorkFolderState()` → `mutateWorkFolder` takes `url` from the new
    /// folder and `projection` from the old one, and folder B's `settings.json` comes back
    /// carrying folder A's context prompt.
    func testFailedOpen_cannotWriteTheOldFoldersSettingsIntoTheNewFolder() async throws {
        try await makeCorruptButRealWorkFolder(at: otherDir, contextPrompt: "FOLDER-B-PROMPT")

        await sut.openWorkFolder(tempDir)
        await sut.updateContextPrompt("FOLDER-A-PROMPT")

        await sut.openWorkFolder(otherDir)   // fails: corrupt active task.json
        XCTAssertNotNil(sut.lastErrorMessage, "the open must have failed for this test to mean anything")

        let before = settingsBytes(of: otherDir)
        await sut.updateContextPrompt("POISON")
        let after = settingsBytes(of: otherDir)

        XCTAssertEqual(before, after, "folder B's settings.json must not be rewritten")
        let text = String(data: after ?? Data(), encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("POISON"), text)
        XCTAssertFalse(text.contains("FOLDER-A-PROMPT"), "folder A's content must not land in B")
    }

    /// RED: restore `configuration.lastOpenedWorkFolderPath = url.path` to `SidebarView`'s
    /// `.onChange(of: store.workFolderURL)` (which fires at the assignment, before the outcome
    /// is known) → the folder that failed becomes the launch-time restore target and the folder
    /// that was working is dropped.
    func testFailedOpen_doesNotBecomeTheLaunchRestoreTarget() async throws {
        await sut.openWorkFolder(tempDir)
        XCTAssertEqual(sut.configuration.lastOpenedWorkFolderPath, tempDir.path)

        await sut.openWorkFolder(try makeNonFolder())

        XCTAssertEqual(
            sut.configuration.lastOpenedWorkFolderPath, tempDir.path,
            "the last folder that actually opened stays the restore target")
    }

    /// The positive control: without it, "never record anything" would satisfy the test above.
    ///
    /// RED: drop the `configuration.lastOpenedWorkFolderPath` write from `openWorkFolder`'s
    /// success path → nothing is ever restored on the next launch.
    func testSuccessfulOpen_recordsTheRestoreTarget() async {
        XCTAssertNil(sut.configuration.lastOpenedWorkFolderPath)
        await sut.openWorkFolder(tempDir)
        XCTAssertEqual(sut.configuration.lastOpenedWorkFolderPath, tempDir.path)
    }

    /// Default storage is not a "project" and must never be recorded — otherwise Close Project
    /// would pin Application Support as the thing to reopen.
    ///
    /// RED: drop the `hasRealWorkFolder` guard on that write → the restore target becomes the
    /// default-storage path.
    func testOpeningDefaultStorage_isNotRecordedAsTheRestoreTarget() async {
        await sut.openWorkFolder(tempDir)
        await sut.closeProject()

        XCTAssertFalse(sut.hasRealWorkFolder)
        XCTAssertNil(sut.configuration.lastOpenedWorkFolderPath)
    }

    // MARK: - 2. A cosmetic repair cannot abort the open

    /// RED: restore the bare `try repository.updateTaskOnly(...)` in `openWorkFolder` → the throw
    /// reaches the catch, `apply(snapshot)` never runs, and the app opens to nothing over intact
    /// data.
    func testRecoveryPersistFailure_stillOpensTheFolder() async throws {
        // Seed: quit mid-run — an active task whose worker step is still `.running`.
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "s")
        await sut.mutateTask(taskID: taskID ?? 0) { task in
            task.status = .running
            var run = Run(id: 0, roleStatuses: ["worker": .working])
            run.steps = [StepExecution(id: "worker", role: .softwareEngineer, title: "W", status: .running)]
            task.runs = [run]
        }

        let repo = AOrchFailingRepository(wrapping: NTMSRepository())
        sut = TestOrchestrator.make(
            repository: repo, embeddingClient: embeddingClient,
            chatLifecycleClient: chatLifecycleClient)
        repo.failUpdateTaskOnly = true

        let errorsBefore = sut.errorSurfaceCount
        await sut.openWorkFolder(tempDir)

        XCTAssertNotNil(sut.snapshot, "a failed cosmetic repair must not abort the open")
        XCTAssertNotNil(sut.activeTask)
        XCTAssertEqual(
            sut.activeTask?.runs.last?.steps.first?.status, .paused,
            "the in-memory recovery still stands even though the write failed")
        XCTAssertNotNil(
            sut.errorSurfaced(since: errorsBefore),
            "the divergence must be reported, not swallowed")
    }

    /// The happy path is unchanged — the repair persists and says nothing.
    ///
    /// RED: make the new catch banner unconditionally → this reds while the test above still
    /// passes, so the pair separates "reports a real failure" from "always complains".
    func testRecoveryPersistSuccess_opensQuietly() async throws {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "s")
        await sut.mutateTask(taskID: taskID ?? 0) { task in
            task.status = .running
            var run = Run(id: 0, roleStatuses: ["worker": .working])
            run.steps = [StepExecution(id: "worker", role: .softwareEngineer, title: "W", status: .running)]
            task.runs = [run]
        }

        sut = TestOrchestrator.make(
            embeddingClient: embeddingClient, chatLifecycleClient: chatLifecycleClient)
        await sut.openWorkFolder(tempDir)

        XCTAssertNotNil(sut.snapshot)
        XCTAssertEqual(sut.activeTask?.runs.last?.steps.first?.status, .paused)
        XCTAssertNil(sut.lastErrorMessage)
    }

    // MARK: - 3. A failed index delete is still readable after the coordinator is gone

    /// RED: move `searchIndexClearFailure = coordinator.lastError` after `searchIndexCoordinator
    /// = nil` (or delete it) → the only object that knew the delete failed is gone and the user
    /// is told nothing while the index files remain on disk.
    func testDisablingSearch_whenTheIndexCannotBeDeleted_saysSo() async throws {
        sut.configuration.exploratorySearchEnabled = true
        await sut.openWorkFolder(tempDir)
        guard sut.searchIndexCoordinator != nil else {
            throw XCTSkip("coordinator not installed for this folder")
        }
        // Force a real index file to exist, then make its directory unremovable-from —
        // `SearchIndexService.clear()` guards on `fileExists` first, so an absent file is a
        // clean no-op and would prove nothing.
        let paths = NTMSPaths(workFolderRoot: tempDir)
        let indexFile = paths.internalDir.appendingPathComponent("search_index.json")
        try "{}".write(to: indexFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: paths.internalDir.path)
        chmodRestore.append(paths.internalDir)

        sut.configuration.exploratorySearchEnabled = false
        await sut.onExploratorySearchSettingChanged()

        XCTAssertNil(sut.searchIndexCoordinator, "disable still drops the coordinator")
        XCTAssertNotNil(
            sut.searchIndexClearFailure,
            "a delete that did not happen must remain readable after the coordinator is dropped")
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexFile.path))
    }

    /// The positive control — a clean disable leaves no warning, so the slot means what it says.
    ///
    /// RED: assign `coordinator.lastError` unconditionally without reading it (e.g. hard-code a
    /// message) → this reds while the test above still passes.
    func testDisablingSearch_cleanDelete_leavesNoWarning() async {
        sut.configuration.exploratorySearchEnabled = true
        await sut.openWorkFolder(tempDir)
        sut.configuration.exploratorySearchEnabled = false
        await sut.onExploratorySearchSettingChanged()

        XCTAssertNil(sut.searchIndexCoordinator)
        XCTAssertNil(sut.searchIndexClearFailure)
    }

    /// RED: drop the `searchIndexClearFailure = nil` from the enable branch → a stale warning
    /// about a previous disable is still rendered under a feature that is now on.
    func testReEnablingSearch_clearsAStaleWarning() async {
        sut.searchIndexClearFailure = "stale"
        sut.configuration.exploratorySearchEnabled = true
        await sut.openWorkFolder(tempDir)
        await sut.onExploratorySearchSettingChanged()

        XCTAssertNil(sut.searchIndexClearFailure)
    }

    // MARK: - 4. "Isn't readable text" is not the diagnosis for a failed write

    /// Every fixture below uses a WELL-KNOWN instruction basename, because that is the only
    /// thing this API can be called on: the "All files" popover iterates
    /// `agentInstructions.items` — discovered instruction files plus manual attachments — not
    /// the folder's contents (its own help string reads "Show every found instruction file").
    /// An arbitrary `NOTES.md` never appears there, so no INJECT button can target it and a
    /// test that promotes one is testing a path production cannot reach.
    ///
    /// `CLAUDE.md` outranks `AGENTS.md`, so it takes the main slot and `docs/AGENTS.md` stays a
    /// listed, un-injected hit — exactly the row that carries an INJECT button.
    private func seedDiscoveredInstructionFiles(nestedBody: String) throws {
        try "# main".write(
            to: tempDir.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        let nested = tempDir.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try nestedBody.write(
            to: nested.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    }

    /// RED: delete the `persisted` guard from `setAgentInstructionInjected` → a settings.json
    /// write failure is reported to the user as a property of their file, and the
    /// `lastInfoMessage` write displaces the real error in the single banner slot.
    func testInject_whenTheSettingsWriteFails_doesNotBlameTheFile() async throws {
        let repo = AOrchFailingRepository(wrapping: NTMSRepository())
        sut = TestOrchestrator.make(
            repository: repo, embeddingClient: embeddingClient,
            chatLifecycleClient: chatLifecycleClient)
        try seedDiscoveredInstructionFiles(nestedBody: "# nested guidance")
        await sut.openWorkFolder(tempDir)

        repo.failUpdateSettings = true
        sut.lastInfoMessage = nil
        await sut.setAgentInstructionInjected(relativePath: "docs/AGENTS.md", injected: true)

        XCTAssertNil(
            sut.lastInfoMessage,
            "a failed write must not be narrated as a property of the file")
        XCTAssertNotNil(sut.lastErrorMessage, "the real cause must be the message that stands")
    }

    /// An EMPTY file is the commonest reason a promotion yields nothing — a placeholder
    /// `AGENTS.md` — and "isn't readable text" is simply false about it. The message must
    /// describe the outcome and list the possibilities rather than assert one.
    ///
    /// RED: restore the "isn't readable text" wording → this reds on a file that is readable,
    /// is text, and is empty.
    func testInject_emptyFile_doesNotClaimItIsNotText() async throws {
        try seedDiscoveredInstructionFiles(nestedBody: "")
        await sut.openWorkFolder(tempDir)

        await sut.setAgentInstructionInjected(relativePath: "docs/AGENTS.md", injected: true)

        let message = sut.lastInfoMessage ?? ""
        XCTAssertTrue(message.contains("docs/AGENTS.md"), message)
        XCTAssertFalse(message.contains("isn't readable text"), message)
        XCTAssertTrue(message.contains("empty"), "the likeliest cause should be named: \(message)")
        XCTAssertFalse(
            sut.workFolder?.settings.agentInstructionInjectedPaths.contains("docs/AGENTS.md") ?? true,
            "the dangling override is still dropped")
    }

    /// The promotion that works must keep working, and must say nothing.
    ///
    /// RED: make the new `persisted` guard return unconditionally → the success path stops
    /// injecting and this reds while the two tests above still pass, so the trio separates
    /// "reports honestly" from "reports nothing".
    func testInject_readableFile_isInjectedSilently() async throws {
        try seedDiscoveredInstructionFiles(nestedBody: "# nested guidance")
        await sut.openWorkFolder(tempDir)
        XCTAssertFalse(
            sut.agentInstructions?.injectedFiles.contains { $0.relativePath == "docs/AGENTS.md" } ?? true,
            "fixture premise: the nested hit starts listed, not injected")

        await sut.setAgentInstructionInjected(relativePath: "docs/AGENTS.md", injected: true)

        XCTAssertNil(sut.lastInfoMessage)
        XCTAssertTrue(
            sut.agentInstructions?.injectedFiles.contains { $0.relativePath == "docs/AGENTS.md" } ?? false)
    }

    // MARK: - 5. Attaching reports what actually persisted

    /// `addAgentInstructions` is the sibling of the defect above and had the same shape: the
    /// rejection notice asserts the OTHER files were attached, and overwrites the write-failure
    /// banner in the single-shot slot while doing it.
    ///
    /// RED: delete the `persistFailed` check → `lastErrorMessage` reads "Only files inside the
    /// work folder can be attached — skipped: …", claiming an attach that did not happen and
    /// destroying the reason it did not.
    func testAddInstructions_whenTheWriteFails_doesNotClaimTheOthersWereAttached() async throws {
        let repo = AOrchFailingRepository(wrapping: NTMSRepository())
        sut = TestOrchestrator.make(
            repository: repo, embeddingClient: embeddingClient,
            chatLifecycleClient: chatLifecycleClient)
        let inside = tempDir.appendingPathComponent("GUIDE.md")
        try "# guide".write(to: inside, atomically: true, encoding: .utf8)
        await sut.openWorkFolder(tempDir)

        repo.failUpdateSettings = true
        await sut.addAgentInstructions(urls: [inside, URL(fileURLWithPath: "/etc/hosts")])

        let banner = sut.lastErrorMessage ?? ""
        XCTAssertFalse(
            banner.contains("skipped:"),
            "the rejection notice must not stand in for — or displace — the write failure: \(banner)")
        XCTAssertFalse(
            sut.workFolder?.settings.agentInstructionExtraPaths.contains("GUIDE.md") ?? true,
            "nothing persisted, which is exactly why the notice would have been a lie")
    }

    /// The ordinary mixed selection still reports its rejects.
    ///
    /// RED: gate the notice on something always-false → this reds while the test above passes.
    func testAddInstructions_mixedSelection_reportsOnlyTheRejects() async throws {
        let inside = tempDir.appendingPathComponent("GUIDE.md")
        try "# guide".write(to: inside, atomically: true, encoding: .utf8)
        await sut.openWorkFolder(tempDir)

        await sut.addAgentInstructions(urls: [inside, URL(fileURLWithPath: "/etc/hosts")])

        XCTAssertTrue(sut.lastErrorMessage?.contains("skipped:") ?? false, sut.lastErrorMessage ?? "nil")
        XCTAssertTrue(
            sut.workFolder?.settings.agentInstructionExtraPaths.contains("GUIDE.md") ?? false)
    }

    // MARK: - 6. Destructive operations report their own failure

    /// RED: restore `try? fileManager.removeItem(at: nanoteamsDir)` → the delete is refused, the
    /// re-open reads the intact tree back in, and "Reset Everything" reports success over data it
    /// did not destroy.
    func testResetAllData_whenTheDeleteIsRefused_saysSo() async throws {
        let defaultURL = NTMSOrchestrator.defaultStorageURL
        let nanoteams = defaultURL.appendingPathComponent(".nanoteams", isDirectory: true)
        try FileManager.default.createDirectory(at: nanoteams, withIntermediateDirectories: true)
        // Refuse the delete by making the PARENT unwritable — `removeItem` needs write
        // permission on the containing directory, not on the target.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: defaultURL.path)
        chmodRestore.append(defaultURL)

        await sut.resetAllData()

        XCTAssertTrue(
            sut.lastErrorMessage?.contains("Reset incomplete") ?? false,
            "a refused delete must not be reported as a completed reset: \(sut.lastErrorMessage ?? "nil")")
        XCTAssertTrue(FileManager.default.fileExists(atPath: nanoteams.path))
    }

    /// RED: banner the reset unconditionally → this reds while the test above passes.
    func testResetAllData_cleanDelete_saysNothing() async {
        await sut.resetAllData()
        XCTAssertNil(sut.lastErrorMessage)
    }

    /// RED: drop the `unreachableRestoreTarget` notice → the app boots into internal storage with
    /// an empty sidebar and no way for the user to tell "the volume isn't mounted" from "my data
    /// is gone".
    func testBootstrap_rememberedFolderIsGone_saysWhyItFellBack() async {
        let vanished = tempDir.appendingPathComponent("moved-away", isDirectory: true)
        sut.configuration.lastOpenedWorkFolderPath = vanished.path

        await sut.bootstrapDefaultStorageIfNeeded()

        XCTAssertFalse(sut.hasRealWorkFolder, "it must still fall back, not fail to boot")
        XCTAssertTrue(
            sut.lastInfoMessage?.contains("moved-away") ?? false,
            "the folder that couldn't be reopened must be named: \(sut.lastInfoMessage ?? "nil")")
    }

    /// RED: emit the notice unconditionally → a normal restore complains on every launch.
    func testBootstrap_rememberedFolderIsPresent_saysNothing() async {
        sut.configuration.lastOpenedWorkFolderPath = tempDir.path

        await sut.bootstrapDefaultStorageIfNeeded()

        XCTAssertEqual(sut.workFolderURL, tempDir)
        XCTAssertNil(sut.lastInfoMessage)
    }

    // MARK: - 7. The refresh reports whether its scan is authoritative

    /// The three branches a caller can reach deterministically. The supersede branch is pinned
    /// structurally instead — see `WorkFolderRaceGuardPinTests`.
    ///
    /// RED: return `false` from the completed-scan arm → `setAgentInstructionInjected` stops
    /// concluding anything and `testInject_emptyFile_doesNotClaimItIsNotText` reds with it.
    func testRefreshAgentInstructions_reportsAuthoritative_onEveryUncontendedPath() async throws {
        // No folder: the snapshot is cleared, which IS the right answer for these inputs.
        let noFolder = await sut.refreshAgentInstructions()
        XCTAssertTrue(noFolder)

        try seedDiscoveredInstructionFiles(nestedBody: "# nested")
        await sut.openWorkFolder(tempDir)

        // Memo hit — the snapshot already reflects these inputs.
        let memoHit = await sut.refreshAgentInstructions()
        XCTAssertTrue(memoHit)

        // A real, uncontended walk.
        sut.agentInstructionsLastScanAt = .distantPast
        let freshWalk = await sut.refreshAgentInstructions()
        XCTAssertTrue(freshWalk)
    }
}
