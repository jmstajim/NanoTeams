import Darwin
import os
import XCTest
@testable import NanoTeams

/// One NanoTeams process per folder, through `openWorkFolder` (F6 C1, 2026-11-12). The "other
/// process" is a `WorkFolderInstanceLock` taken here — a second descriptor conflicts exactly as a
/// second process does — or a second orchestrator, which is what a second process is made of.
@MainActor
final class WorkFolderSecondProcessTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private let agent = AgentIdentity(
        id: UUID(uuidString: "aaaaaaaa-1111-2222-3333-4444444444d1")!, label: "Claude Code")
    /// The other process's descriptor: a raw `flock`, NOT a `WorkFolderInstanceLock` of this
    /// process — whose lock files this process's own write gate trusts from memory.
    private var otherProcessFD: Int32 = -1
    private var second: NTMSOrchestrator?

    override func tearDown() async throws {
        NTMSOrchestrator._testSearchIndexTeardownGate = nil
        releaseOtherProcess()
        second?.stopAllEngines()
        second = nil
        try await super.tearDown()
    }

    /// Holds `folder` the way another NanoTeams would: its own descriptor, its own record.
    private func holdAsAnotherProcess(_ folder: URL, pid: Int32 = 4242) throws {
        let paths = NTMSPaths(workFolderRoot: folder)
        try FileManager.default.createDirectory(at: paths.internalDir, withIntermediateDirectories: true)
        otherProcessFD = open(paths.instanceLockFile.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(otherProcessFD, 0)
        XCTAssertEqual(flock(otherProcessFD, LOCK_EX | LOCK_NB), 0)
        let record = Data(#"{"pid":\#(pid),"since":"2026-11-08T21:32:58Z"}"#.utf8)
        _ = record.withUnsafeBytes { pwrite(otherProcessFD, $0.baseAddress, record.count, 0) }
    }

    private func releaseOtherProcess() {
        if otherProcessFD >= 0 { close(otherProcessFD) }
        otherProcessFD = -1
    }

    // MARK: - A folder another process holds is not opened

    func testFolderHeldElsewhere_isNotOpenedAndNothingIsWrittenToIt() async throws {
        try holdAsAnotherProcess(tempDir)
        let errorsBefore = sut.errorSurfaceCount

        await sut.openWorkFolder(tempDir)

        XCTAssertNil(sut.snapshot, "nothing of the folder is loaded")
        XCTAssertEqual(sut.workFolderURL, tempDir, "the URL is committed, as any failed open's")
        XCTAssertEqual(sut.workFolderHeldByAnotherProcess?.pid, 4242)
        XCTAssertGreaterThan(sut.errorSurfaceCount, errorsBefore)
        let banner = try XCTUnwrap(sut.lastSurfacedError)
        XCTAssertTrue(banner.contains("already open in another NanoTeams process (PID 4242)"), banner)
        XCTAssertFalse(sut.holdsWorkFolderInstanceLock(for: tempDir))
        XCTAssertEqual(sut.externalAutovisorReadiness.state, .folderInUse)
        XCTAssertNil(sut.autovisorAutoDisableAt, "no sleep timer")
        XCTAssertNil(sut.automationPollTask, "no scheduler")

        // Nothing but the other process's lock file is in `internal/`: the open wrote nothing.
        let internalEntries = try FileManager.default.contentsOfDirectory(
            atPath: NTMSPaths(workFolderRoot: tempDir).internalDir.path)
        XCTAssertEqual(internalEntries, ["instance.lock"])

        // The writers that ask only for the URL are refused by the repository's gate, before they
        // touch anything: a create, a tool save, a settings write, a reset.
        _ = await sut.createTask(title: "t", supervisorTask: "b")
        await sut.saveToolDefinitions([])
        await sut.updateWorkFolderContext("from the refused process")
        await sut.resetWorkFolderSettings()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: NTMSPaths(workFolderRoot: tempDir).internalDir.path), ["instance.lock"])
        XCTAssertTrue(sut.lastSurfacedError?.contains("already open in another NanoTeams process") == true,
                      sut.lastSurfacedError ?? "")
    }

    /// The gate itself, at the repository: a raw writer of this process may write into a folder
    /// this process holds, and may not write into one another process holds.
    func testRepositoryGate_refusesOnlyAFolderAnotherProcessHolds() async throws {
        await sut.openWorkFolder(tempDir)
        XCTAssertNoThrow(try NTMSRepository().updateSettings(at: tempDir, activeTask: nil) { $0.context = "x" },
                         "this process holds it")

        let other = tempDir.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertNoThrow(try NTMSRepository().openOrCreateWorkFolder(at: other), "nobody holds it")
        try holdAsAnotherProcess(other, pid: 77)
        XCTAssertThrowsError(try NTMSRepository().updateSettings(at: other, activeTask: nil) { $0.context = "y" }) {
            XCTAssertEqual($0 as? WorkFolderInstanceLock.AcquireError,
                           .heldByAnotherProcess(.init(pid: 77, since: ISO8601DateFormatter().date(from: "2026-11-08T21:32:58Z"))))
        }
        XCTAssertThrowsError(try NTMSRepository().resetWorkFolderSettings(at: other))
        XCTAssertTrue(FileManager.default.fileExists(atPath: NTMSPaths(workFolderRoot: other).settingsJSON.path),
                      "the reset deleted nothing")
    }

    /// The agent hears it too: `folder_status` names the state and the path, and a create is
    /// refused with the readiness sentence — not "no work folder".
    func testFolderHeldElsewhere_isReportedToTheExternalAgent() async throws {
        try holdAsAnotherProcess(tempDir)
        await sut.openWorkFolder(tempDir)

        let status = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.folderStatus, args: [:], agent: agent)
        let data = try XCTUnwrap(try json(status.outputJSON)["data"] as? [String: Any])
        let readiness = try XCTUnwrap(data["readiness"] as? [String: Any])
        XCTAssertEqual(readiness["state"] as? String, "folder_in_use")
        XCTAssertEqual(readiness["reason"] as? String, ExternalAutovisorReadiness.Refusal.folderInUse.reason)
        XCTAssertEqual(data["path"] as? String, tempDir.path)

        let create = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.createManagedTask,
            args: ["folder_id": "AAAAAAAA-1111-2222-3333-444444444444", "title": "t", "brief": "b"],
            agent: agent)
        XCTAssertTrue(create.isError)
        let error = try XCTUnwrap(try json(create.outputJSON)["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "COMMAND_FAILED")
        XCTAssertEqual(error["message"] as? String, ExternalAutovisorReadiness.Refusal.folderInUse.message)
    }

    /// The real shape of the defect: two orchestrators — two processes' worth — on one folder. The
    /// first keeps it; the second does nothing in it.
    func testSecondOrchestratorOnTheSameFolder_isRefused() async throws {
        await sut.openWorkFolder(tempDir)
        XCTAssertNotNil(sut.snapshot)
        XCTAssertTrue(sut.holdsWorkFolderInstanceLock(for: tempDir))

        let other = TestOrchestrator.make(embeddingClient: embeddingClient, chatLifecycleClient: chatLifecycleClient)
        second = other
        await other.openWorkFolder(tempDir)

        XCTAssertNil(other.snapshot)
        XCTAssertEqual(other.workFolderHeldByAnotherProcess?.pid, getpid())
        XCTAssertNotNil(sut.snapshot, "the first keeps its folder")
        XCTAssertTrue(sut.holdsWorkFolderInstanceLock(for: tempDir))
    }

    // MARK: - The lock is let go

    func testAfterTheOtherProcessLetsGo_theFolderOpens() async throws {
        try holdAsAnotherProcess(tempDir)
        await sut.openWorkFolder(tempDir)
        XCTAssertNil(sut.snapshot)

        releaseOtherProcess()
        await sut.openWorkFolder(tempDir)

        XCTAssertNotNil(sut.snapshot)
        XCTAssertNil(sut.workFolderHeldByAnotherProcess, "the refusal is about the open that was refused")
        XCTAssertNotEqual(sut.externalAutovisorReadiness.state, .folderInUse)
        XCTAssertTrue(sut.holdsWorkFolderInstanceLock(for: tempDir))
    }

    /// Opening another folder gives the first one back; reopening the same folder in this process
    /// takes it again (the lock is let go before it is taken).
    func testSwitchingFolders_letsTheFirstGo_andReopeningTheSameFolderWorks() async throws {
        let other = tempDir.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        await sut.openWorkFolder(tempDir)
        await sut.openWorkFolder(tempDir)
        XCTAssertNotNil(sut.snapshot, "a reopen of the folder this process holds")
        XCTAssertNil(sut.workFolderHeldByAnotherProcess)

        await sut.openWorkFolder(other)
        XCTAssertTrue(sut.holdsWorkFolderInstanceLock(for: other))
        let probe = try WorkFolderInstanceLock.acquire(workFolderRoot: tempDir)
        probe.release()
        XCTAssertThrowsError(try WorkFolderInstanceLock.acquire(workFolderRoot: other))
    }

    /// An open that fails for another reason holds nothing of the folder either.
    func testFailedOpen_releasesTheLock() async throws {
        let repo = SelectivelyFailingRepository(wrapping: NTMSRepository())
        repo.failOpenOrCreate = true
        sut = TestOrchestrator.make(
            repository: repo, embeddingClient: embeddingClient, chatLifecycleClient: chatLifecycleClient)

        await sut.openWorkFolder(tempDir)

        XCTAssertNil(sut.snapshot)
        XCTAssertNil(sut.workFolderHeldByAnotherProcess, "not refused for another process")
        XCTAssertNotEqual(sut.externalAutovisorReadiness.state, .folderInUse)
        let probe = try WorkFolderInstanceLock.acquire(workFolderRoot: tempDir)
        probe.release()
    }

    /// A reset deletes `.nanoteams/` with the lock file in it; the folder is held again on the new one.
    func testResetWorkFolderSettings_holdsTheRecreatedFolder() async throws {
        await sut.openWorkFolder(tempDir)
        await sut.resetWorkFolderSettings()

        XCTAssertNotNil(sut.snapshot)
        XCTAssertTrue(sut.holdsWorkFolderInstanceLock(for: tempDir))
        XCTAssertThrowsError(try WorkFolderInstanceLock.acquire(workFolderRoot: tempDir),
                             "another process is kept out of the reset folder")
    }

    /// Dropping the orchestrator — what a process exiting does to its objects — lets the folder go.
    func testOrchestratorGoingAway_letsTheFolderGo() async throws {
        let other = TestOrchestrator.make(embeddingClient: embeddingClient, chatLifecycleClient: chatLifecycleClient)
        second = other
        await other.openWorkFolder(tempDir)
        XCTAssertTrue(other.holdsWorkFolderInstanceLock(for: tempDir))
        other.releaseWorkFolderInstanceLock()

        await sut.openWorkFolder(tempDir)
        XCTAssertNotNil(sut.snapshot)
    }

    // MARK: - Two opens in flight (D-M18 R1)

    /// The older of two overlapping opens finishes its teardown last. It used to take its own
    /// folder's lock at that point — letting go of the newer open's — and the newer open committed
    /// holding the wrong folder. Deterministic: the older open is held inside its teardown
    /// (`_testSearchIndexTeardownGate`) until the newer one has committed.
    func testOlderOpenFinishingItsTeardownLast_leavesTheNewerOpensLockAlone() async throws {
        let folderA = tempDir.appendingPathComponent("A", isDirectory: true)
        let folderB = tempDir.appendingPathComponent("B", isDirectory: true)
        for folder in [folderA, folderB] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let (entered, enteredCont) = AsyncStream<Void>.makeStream()
        let (release, releaseCont) = AsyncStream<Void>.makeStream()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        NTMSOrchestrator._testSearchIndexTeardownGate = {
            let call = calls.withLock { count -> Int in count += 1; return count }
            guard call == 1 else { return }
            enteredCont.yield()
            for await _ in release { break }
        }
        let openA = Task { await self.sut.openWorkFolder(folderA) }
        for await _ in entered { break }

        await sut.openWorkFolder(folderB)
        XCTAssertTrue(sut.holdsWorkFolderInstanceLock(for: folderB), "premise: B committed holding B")
        releaseCont.yield()
        releaseCont.finish()
        await openA.value

        XCTAssertEqual(sut.workFolderURL, folderB)
        XCTAssertNotNil(sut.snapshot)
        XCTAssertTrue(sut.holdsWorkFolderInstanceLock(for: folderB), "B is still held")
        XCTAssertThrowsError(try WorkFolderInstanceLock.acquire(workFolderRoot: folderB),
                             "a second NanoTeams is kept out of B")
        XCTAssertNoThrow(try WorkFolderInstanceLock.acquire(workFolderRoot: folderA).release(),
                         "A is not held by the superseded open")
        XCTAssertFalse(FileManager.default.fileExists(atPath: NTMSPaths(workFolderRoot: folderA).workFolderJSON.path),
                       "the superseded open read and wrote nothing of A")
    }

    // MARK: - Only the process holding the folder writes in it (D-M18 R2)

    /// The holder quits after this process's open was refused. Nothing this process does without
    /// opening the folder again writes into it, loads it, or runs in it — a Quick Capture submit,
    /// a create, a tool save, a settings write, a reset.
    func testRefusedFolder_staysUntouched_afterTheHolderLetsGo() async throws {
        try holdAsAnotherProcess(tempDir)
        await sut.openWorkFolder(tempDir)
        XCTAssertNil(sut.snapshot)
        releaseOtherProcess()

        let quickCapture = await sut.createPreparedTaskAndStart(request: TaskCreationRequest(
            title: "Quick", rawSupervisorTask: "from the hotkey", preferredTeamID: nil,
            clippedTexts: [], stagedAttachments: []))
        XCTAssertNil(quickCapture)
        let refusedCreate = await sut.createTask(title: "t", supervisorTask: "b")
        XCTAssertNil(refusedCreate)
        await sut.saveToolDefinitions([])
        await sut.updateWorkFolderContext("from the refused process")
        await sut.updateSelectedScheme("Refused")
        await sut.mutateWorkFolder { $0.settings.context = "refused" }
        await sut.resetWorkFolderSettings()

        XCTAssertNil(sut.snapshot, "nothing of the folder was loaded")
        XCTAssertTrue(sut.taskEngines.isEmpty, "nothing runs")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: NTMSPaths(workFolderRoot: tempDir).internalDir.path), ["instance.lock"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: NTMSPaths(workFolderRoot: tempDir).tasksDir.path))
        XCTAssertTrue(sut.lastSurfacedError?.contains("isn't open in this NanoTeams") == true,
                      sut.lastSurfacedError ?? "")
        XCTAssertNoThrow(try WorkFolderInstanceLock.acquire(workFolderRoot: tempDir).release(),
                         "the folder is free for whoever opens it")

        // Opening it again is the way in.
        await sut.openWorkFolder(tempDir)
        XCTAssertNotNil(sut.snapshot)
        let created = await sut.createTask(title: "now", supervisorTask: "b")
        XCTAssertNotNil(created)
    }

    /// A second orchestrator in THIS process — what the process-wide write gate trusts from memory
    /// — writes nothing into the folder the first one holds.
    func testSecondOrchestratorInThisProcess_writesNothingIntoTheFirstsFolder() async throws {
        await sut.openWorkFolder(tempDir)
        let tasksBefore = sut.snapshot?.tasksIndex.tasks.count
        let other = TestOrchestrator.make(embeddingClient: embeddingClient, chatLifecycleClient: chatLifecycleClient)
        second = other
        await other.openWorkFolder(tempDir)
        XCTAssertNil(other.snapshot)

        let refusedCreate = await other.createTask(title: "from the second", supervisorTask: "b")
        XCTAssertNil(refusedCreate)
        await other.saveToolDefinitions([])

        XCTAssertNil(other.snapshot)
        XCTAssertEqual(try NTMSRepository().openOrCreateWorkFolder(at: tempDir).tasksIndex.tasks.count, tasksBefore)
        XCTAssertTrue(sut.holdsWorkFolderInstanceLock(for: tempDir))
    }

    /// An open that failed for a reason of its own holds nothing, so it writes nothing either.
    func testFailedOpen_writesNothingAfterwards() async throws {
        let repo = SelectivelyFailingRepository(wrapping: NTMSRepository())
        repo.failOpenOrCreate = true
        sut = TestOrchestrator.make(
            repository: repo, embeddingClient: embeddingClient, chatLifecycleClient: chatLifecycleClient)
        await sut.openWorkFolder(tempDir)
        XCTAssertNil(sut.snapshot)

        let refusedCreate = await sut.createTask(title: "t", supervisorTask: "b")
        XCTAssertNil(refusedCreate)
        XCTAssertFalse(FileManager.default.fileExists(atPath: NTMSPaths(workFolderRoot: tempDir).tasksDir.path))
        XCTAssertTrue(sut.lastSurfacedError?.contains("isn't open in this NanoTeams") == true,
                      sut.lastSurfacedError ?? "")
    }

    /// After a switch to another folder, a write still addressed to the first is refused: the
    /// first is free for another process now.
    func testAfterSwitchingFolders_aWriteIntoTheFirstIsRefused() async throws {
        let other = tempDir.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        await sut.openWorkFolder(tempDir)
        await sut.openWorkFolder(other)

        XCTAssertThrowsError(try sut.repository.updateSettings(at: tempDir, activeTask: nil) { $0.context = "late" }) {
            XCTAssertEqual($0 as? WorkFolderHold.Refusal, .notHeld(tempDir))
        }
        XCTAssertNoThrow(try sut.repository.updateSettings(at: other, activeTask: nil) { $0.context = "here" })
    }

    // MARK: - Reset All Data (D-M18 R3)

    /// Another NanoTeams holds default storage: Reset All Data deletes none of it, says so, and the
    /// open after it is refused as any open of a held folder is.
    func testResetAllData_whenAnotherProcessHoldsDefaultStorage_deletesNothing() async throws {
        let defaultURL = NTMSOrchestrator.defaultStorageURL
        try FileManager.default.createDirectory(at: defaultURL, withIntermediateDirectories: true)
        let marker = NTMSPaths(workFolderRoot: defaultURL).nanoteamsDir
            .appendingPathComponent("r3-marker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("the other process's".utf8).write(to: marker)
        defer { try? FileManager.default.removeItem(at: marker) }
        // The other process holds the lock file this orchestrator's locking names for default storage.
        let lockFile = sut.workFolderLocking.lockFile(defaultURL)
        try FileManager.default.createDirectory(at: lockFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        otherProcessFD = open(lockFile.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        XCTAssertEqual(flock(otherProcessFD, LOCK_EX | LOCK_NB), 0)

        await sut.resetAllData()

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "nothing of default storage was deleted")
        XCTAssertEqual(sut.lastSurfacedError, NTMSOrchestrator.resetAllDataHeldElsewhereMessage)
        XCTAssertNil(sut.snapshot)
        XCTAssertFalse(sut.holdsWorkFolderInstanceLock(for: defaultURL))
    }

    /// Reset All Data holds default storage from before its delete to after its open.
    func testResetAllData_holdsDefaultStorageThroughout() async throws {
        await sut.resetAllData()
        let defaultURL = NTMSOrchestrator.defaultStorageURL
        XCTAssertNotNil(sut.snapshot)
        XCTAssertTrue(sut.holdsWorkFolderInstanceLock(for: defaultURL))
        let lockFile = sut.workFolderLocking.lockFile(defaultURL)
        let probe = open(lockFile.path, O_RDWR | O_CLOEXEC)
        defer { close(probe) }
        XCTAssertNotEqual(flock(probe, LOCK_EX | LOCK_NB), 0, "another process is kept out")
    }

    // MARK: - A folder that is gone (D-M18 R4)

    /// A folder deleted while NanoTeams ran, still in the recents: the open says it is not
    /// accessible and brings back nothing.
    func testOpeningAFolderThatIsGone_doesNotRecreateIt() async throws {
        let gone = tempDir.appendingPathComponent("moved-away", isDirectory: true)

        await sut.openWorkFolder(gone)

        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path))
        XCTAssertNil(sut.snapshot)
        XCTAssertEqual(sut.lastSurfacedError, NTMSRepositoryError.invalidProjectFolder(gone).localizedDescription)
        XCTAssertNil(sut.workFolderHeldByAnotherProcess)
    }

    // MARK: - A volume without advisory locks (D-M18 R6)

    /// The folder opens, and the person is told nothing keeps a second NanoTeams out of it.
    func testVolumeWithoutAdvisoryLocks_opensWithAWarning() async throws {
        sut = TestOrchestrator.make(
            embeddingClient: embeddingClient, chatLifecycleClient: chatLifecycleClient,
            workFolderLocking: WorkFolderInstanceLocking(
                lockFile: { NTMSPaths(workFolderRoot: $0).instanceLockFile }, lockOperation: { _, _ in ENOTSUP }))

        await sut.openWorkFolder(tempDir)

        XCTAssertNotNil(sut.snapshot)
        XCTAssertTrue(sut.holdsWorkFolderInstanceLock(for: tempDir))
        XCTAssertEqual(sut.lastInfoMessage, NTMSOrchestrator.folderWithoutAdvisoryLocksMessage)
        let created = await sut.createTask(title: "t", supervisorTask: "b")
        XCTAssertNotNil(created, "it works there")
    }

    // MARK: - Reset of the folder's settings (D-M18 R7)

    /// The reset keeps the lock file, so the lock is on the same file before and after it.
    func testResetWorkFolderSettings_keepsTheLockOnTheSameFile() async throws {
        await sut.openWorkFolder(tempDir)
        let lockFile = NTMSPaths(workFolderRoot: tempDir).instanceLockFile
        let inodeBefore = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: lockFile.path)[.systemFileNumber] as? Int)

        await sut.resetWorkFolderSettings()

        let inodeAfter = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: lockFile.path)[.systemFileNumber] as? Int)
        XCTAssertEqual(inodeAfter, inodeBefore)
        XCTAssertTrue(try XCTUnwrap(sut.workFolderHold.lock(for: tempDir)).locksTheFileAtItsPath)
    }

    /// A reset that fails for a reason of its own lets go of the snapshot it no longer describes,
    /// and of the folder — as a failed open does.
    func testResetWorkFolderSettings_thatFails_letsTheFolderGo() async throws {
        let repo = SelectivelyFailingRepository(wrapping: NTMSRepository())
        sut = TestOrchestrator.make(
            repository: repo, embeddingClient: embeddingClient, chatLifecycleClient: chatLifecycleClient)
        await sut.openWorkFolder(tempDir)
        XCTAssertNotNil(sut.snapshot)
        repo.failResetWorkFolderSettings = true

        await sut.resetWorkFolderSettings()

        XCTAssertNil(sut.snapshot)
        XCTAssertFalse(sut.holdsWorkFolderInstanceLock(for: tempDir))
        XCTAssertNoThrow(try WorkFolderInstanceLock.acquire(workFolderRoot: tempDir).release())
    }

    // MARK: - Default storage

    /// The factories' default-storage lock is their own, so a test never contends with the
    /// NanoTeams the developer is running there — and `.system` takes the real one.
    func testIsolatedDefaultStorage_usesAPrivateLockFile_andSystemUsesTheFolders() throws {
        let isolated = WorkFolderInstanceLocking.isolatingDefaultStorage()
        let lock = try isolated.acquire(NTMSPaths.defaultStorageURL)
        defer { lock.release() }
        XCTAssertNotEqual(lock.fileURL, NTMSPaths(workFolderRoot: NTMSPaths.defaultStorageURL).instanceLockFile)
        XCTAssertTrue(lock.fileURL.path.hasPrefix(FileManager.default.temporaryDirectory.path))

        let folderLock = try isolated.acquire(tempDir)
        defer { folderLock.release() }
        XCTAssertEqual(folderLock.fileURL, NTMSPaths(workFolderRoot: tempDir).instanceLockFile)
        XCTAssertThrowsError(try WorkFolderInstanceLocking.system.acquire(tempDir),
                             "the real lock of a real folder")
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
