import XCTest

@testable import NanoTeams

/// The fixture every work-folder lifecycle test builds on: an orchestrator over a repository that
/// can hold or refuse a folder's read (`SelectivelyFailingRepository.openReadHolds` — an
/// `OpenReadHold` the test releases — / `openFailurePaths`) and hold one task write on its writer
/// (`TaskWriteHold`), two folders whose
/// task ids collide by construction, and the holds that stop one lifecycle at a named step
/// (`NTMSOrchestrator._testWorkFolderOpenGate`).
///
/// The question every subclass asks is the same: an action that began in folder A and suspended —
/// an open, a run start, a scheduler pass, an Autovisor action, a queued message's wake — must not
/// finish in folder B. The holds are how a test makes "suspended" deterministic: a read that
/// held until a later open's whole run is over, a write blocked until the test releases it, a step
/// held while the next open commits. No hold is a delay: each ends where the test releases it.
///
/// No `func test…` lives here, so the class runs nothing of its own and the class selector skips
/// it; `WorkFolderOpenSupersessionTests` and its siblings inherit the fixture.
@MainActor
class WorkFolderLifecycleTestCase: XCTestCase {

    var repository: SelectivelyFailingRepository!
    var sut: NTMSOrchestrator!
    var folderA: URL!
    var folderB: URL!

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        folderA = root.appendingPathComponent("A", isDirectory: true)
        folderB = root.appendingPathComponent("B", isDirectory: true)
        for folder in [folderA!, folderB!] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        repository = SelectivelyFailingRepository(wrapping: NTMSRepository())
        sut = TestOrchestrator.make(repository: repository)
    }

    override func tearDown() async throws {
        NTMSOrchestrator._testWorkFolderOpenGate = nil
        NTMSOrchestrator._testSearchIndexTeardownGate = nil
        NTMSOrchestrator._testResidencyReconcileGate = nil
        sut?.llmExecutionService.stepCancelHold = nil
        for hold in holds { await hold.release() }
        holds = []
        for hold in stepCancelHolds { await hold.release() }
        stepCancelHolds = []
        for (path, read) in repository?.releaseAllOpenReads() ?? [:] where read.timedOut {
            XCTFail("the read of \((path as NSString).lastPathComponent) was held until its "
                + "\(OpenReadHold.defaultCap) s cap: the test awaited an open whose read it never released")
        }
        repository?.taskWriteHold?.release()
        await sut?.drainRunStartLaunches()
        sut?.stopAllEngines()
        await sut?.tearDownMCPServerManager(budget: 0)
        await sut?.tearDownSearchIndexCoordinator()
        scriptedMCP?.cleanUp()
        scriptedMCP = nil
        sut = nil
        repository = nil
        if let folderA {
            try? FileManager.default.removeItem(at: folderA.deletingLastPathComponent())
        }
        folderA = nil
        folderB = nil
        try await super.tearDown()
    }

    /// Starts an open of `folder` and returns once that open is inside its off-main read.
    func startOpen(of folder: URL) async throws -> Task<Void, Never> {
        let earlierStarts = repository.openStarts.count
        let open = Task { await sut.openWorkFolder(folder) }
        for _ in 0..<400 {
            if repository.openStarts.dropFirst(earlierStarts).contains(folder.path) { return open }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("the open of \(folder.lastPathComponent) never reached its read")
        return open
    }

    /// Holds every read of `folder` until the returned hold is released — the test's own moment,
    /// not a delay. A released hold lets every later read of the folder through.
    func holdReads(of folder: URL) -> OpenReadHold {
        let hold = OpenReadHold()
        repository.openReadHolds[folder.path] = hold
        return hold
    }

    /// Starts an open of `slow` that is still reading when an open of `fast` runs to completion:
    /// `slow`'s read is held until `fast`'s open has returned, then released.
    func overlapSlowOpen(of slow: URL, byOpenOf fast: URL) async throws {
        let slowRead = holdReads(of: slow)
        let slowOpen = try await startOpen(of: slow)
        await sut.openWorkFolder(fast)
        slowRead.release()
        await slowOpen.value
    }

    /// Holds ONE folder lifecycle at `step` — `NTMSOrchestrator._testWorkFolderOpenGate` — until
    /// `release()`; every other lifecycle and step passes straight through. A lifecycle is told
    /// apart by its generation: each open's is the one before it plus one.
    actor StepHold {
        private let generation: Int
        private let step: WorkFolderOpenStep
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var isHeld = false
        private(set) var visitedSteps: [WorkFolderOpenStep] = []
        private var released = false

        init(generation: Int, at step: WorkFolderOpenStep) {
            self.generation = generation
            self.step = step
        }

        func pass(_ lifecycle: WorkFolderLifecycle, _ step: WorkFolderOpenStep) async {
            if lifecycle.generation == generation {
                visitedSteps.append(step)
            }
            guard lifecycle.generation == generation, step == self.step, !released, !isHeld else { return }
            isHeld = true
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    /// Holds one `cancelStepExecution` call (`LLMExecutionService.stepCancelHold`) whose
    /// `(stepID, taskID)` matches, modelled on `TaskWriteHold` / `StepHold`: the verb suspends at
    /// the cancellation-handler wait until the test calls `release()`.
    actor StepCancelHold {
        private let matches: @Sendable (String, Int) -> Bool
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var isHeld = false
        private var used = false
        private var released = false

        init(matching matches: @escaping @Sendable (_ stepID: String, _ taskID: Int) -> Bool) {
            self.matches = matches
        }

        func holdIfMatching(stepID: String, taskID: Int) async {
            guard !used, !released, matches(stepID, taskID) else { return }
            used = true
            isHeld = true
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            released = true
            isHeld = false
            continuation?.resume()
            continuation = nil
        }
    }

    /// Every hold installed in this test, asked in turn by the gate.
    var holds: [StepHold] = []
    var stepCancelHolds: [StepCancelHold] = []

    /// Installs a `StepCancelHold` on `sut.llmExecutionService` for the first matching
    /// `cancelStepExecution` call.
    func holdStepCancel(
        matching matches: @escaping @Sendable (_ stepID: String, _ taskID: Int) -> Bool
    ) -> StepCancelHold {
        let hold = StepCancelHold(matching: matches)
        stepCancelHolds.append(hold)
        sut.llmExecutionService.stepCancelHold = { stepID, taskID in
            await hold.holdIfMatching(stepID: stepID, taskID: taskID)
        }
        return hold
    }

    /// Waits until `hold` holds its step cancellation.
    func waitHeld(_ hold: StepCancelHold, _ what: String) async throws {
        for _ in 0..<600 {
            if await hold.isHeld { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("\(what) never reached its held step cancellation")
    }

    /// Installs a hold for the NEXT open's lifecycle at `step` — the open started right after this.
    func holdNextOpen(at step: WorkFolderOpenStep) -> StepHold {
        let hold = StepHold(generation: sut.workFolderOpenGeneration + 1, at: step)
        holds.append(hold)
        let all = holds
        NTMSOrchestrator._testWorkFolderOpenGate = { lifecycle, step in
            for hold in all { await hold.pass(lifecycle, step) }
        }
        return hold
    }

    /// Waits until `hold` holds its lifecycle.
    func waitHeld(_ hold: StepHold, _ what: String) async throws {
        for _ in 0..<600 {
            if await hold.isHeld { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("\(what) never reached its step")
    }

    /// Opens `held` and waits until it is held at `step`, having finished its read.
    func holdOpen(of held: URL, at step: WorkFolderOpenStep) async throws -> (Task<Void, Never>, StepHold) {
        let hold = holdNextOpen(at: step)
        let open = Task { await sut.openWorkFolder(held) }
        try await waitHeld(hold, "the open of \(held.lastPathComponent) at \(step)")
        return (open, hold)
    }

    /// Opens `later` far enough to be inside its read — past its teardown — and returns it with
    /// the hold its read waits on: the test releases that hold before it awaits the open, so the
    /// read finishes after everything the test did meanwhile.
    func startReadingOpen(of later: URL) async throws -> (Task<Void, Never>, OpenReadHold) {
        let read = holdReads(of: later)
        return (try await startOpen(of: later), read)
    }

    var scriptedMCP: ScriptedMCPEnvironment?

    /// An orchestrator whose MCP environment writes the frame log and runs one scripted server,
    /// so a connection built for a folder leaves a trace under it.
    func useLoggingMCP() throws -> MCPServerConfig {
        let trust = folderA.deletingLastPathComponent().appendingPathComponent("mcp", isDirectory: true)
        let scripted = ScriptedMCPEnvironment(trustDirectory: trust)
        scriptedMCP = scripted
        let url = "https://a.test/mcp"
        scripted.register(url: url) {
            let transport = ScriptedTransport()
            transport.script(MCPWire.discoverMethod, [.result(.object([:]))])
            transport.script(MCPWire.toolsListMethod, [.result(.object(["tools": .array([])]))])
            return transport
        }
        let catalogue = MCPServerCatalogueStore(directory: trust)
        let config = MCPServerConfig(
            slug: try XCTUnwrap(MCPServerSlug("folio")), displayName: "Folio",
            transport: .http(MCPHTTPConfig(urlString: url)), isEnabled: true)
        try catalogue.upsert(config)
        sut = TestOrchestrator.make(
            repository: repository,
            mcpEnvironment: MCPEnvironment(
                makeTransport: scripted.environment.makeTransport, secretStorage: scripted.secretStorage,
                trustDirectory: trust, writesRPCLog: true),
            mcpCatalogueStore: catalogue)
        return config
    }

    /// The three files of `folder` that say what the folder is — what "nothing written into it"
    /// is compared against.
    func folderFiles(_ folder: URL) -> [String: Data] {
        let paths = NTMSPaths(workFolderRoot: folder)
        var files: [String: Data] = [:]
        for url in [paths.settingsJSON, paths.teamsJSON, paths.workFolderJSON, paths.tasksIndexJSON] {
            files[url.lastPathComponent] = try? Data(contentsOf: url)
        }
        return files
    }

    /// A manager task made by hand in the open folder — not the active task, so nothing has
    /// loaded it — with the Autovisor switched on for the folder.
    func handMadeManager(pausedRun: Bool = false) async throws -> Int {
        let managerIDCreated = await sut.createTask(title: "Autovisor", supervisorTask: "goal", makeActive: false)
        let managerID = try XCTUnwrap(managerIDCreated)
        if pausedRun {
            // Loaded first: `mutateTask` refuses a task nothing has loaded ("task not loaded"), so
            // until 2026-10-28 this run was never written, and the `.autovisorTask` test
            // below read an engine state no load could seed.
            _ = await sut.ensureTaskLoaded(managerID)
            await sut.mutateTask(taskID: managerID) { task in
                var run = Run(id: 0, roleStatuses: ["worker": .working])
                run.steps = [StepExecution(id: "worker", role: .softwareEngineer, title: "Work", status: .paused)]
                task.runs = [run]
            }
            XCTAssertEqual(sut.loadedTask(managerID)?.runs.count, 1, "premise: the manager's paused run is written")
        }
        await sut.mutateWorkFolder {
            $0.state.autovisorTaskID = managerID
            $0.settings.autovisorEnabled = true
        }
        return managerID
    }

    /// Two fresh folders under the test's root.
    func freshFolders(_ label: String) throws -> (URL, URL) {
        let root = folderA.deletingLastPathComponent()
        let a = root.appendingPathComponent("\(label)-A", isDirectory: true)
        let b = root.appendingPathComponent("\(label)-B", isDirectory: true)
        for folder in [a, b] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        return (a, b)
    }

    /// The Autovisor manager's tools in `teams`, or nil when there is no Autovisor team.
    static func managerTools(_ teams: [Team]) -> [String]? {
        teams.first { $0.templateID == AutovisorConstants.teamTemplateID }?
            .roles.first { $0.systemRoleID == AutovisorConstants.managerRoleSystemID }?.toolIDs
    }

    /// Holds the write of the run a start materialized for `taskID` in `folder` — the one
    /// suspension of `createNewRun` (`mutateTask`'s detached write), between the start's claim and
    /// its launch.
    func holdRunMaterialization(in folder: URL, of taskID: Int, runsBefore: Int = 0) -> TaskWriteHold {
        let path = folder.path
        let hold = TaskWriteHold { written, task in
            written.path == path && task.id == taskID && task.runs.count == runsBefore + 1
        }
        repository.taskWriteHold = hold
        return hold
    }

    /// Waits until `write` holds its writer.
    func waitHeld(_ write: TaskWriteHold, _ what: String) async throws {
        for _ in 0..<600 {
            if write.isHeld { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("\(what) never reached its held write")
    }

    /// Nothing of a run start survives into the folder now open: no engine, no engine state and
    /// no claim for `taskID`, and the task of that id there is not written.
    func assertNothingStarted(
        _ taskID: Int, taskJSON: URL, before: Data, _ label: String = "", line: UInt = #line
    ) {
        XCTAssertTrue(sut.taskEngines.isEmpty, "\(label): an engine was started in the folder now open", line: line)
        XCTAssertNil(sut.taskEngineStates[taskID], "\(label): task #\(taskID) has an engine state", line: line)
        XCTAssertFalse(sut.engineState.isInitializingRun(taskID), "\(label): the start's claim survived", line: line)
        XCTAssertEqual(try? Data(contentsOf: taskJSON), before, "\(label): the folder now open's task #\(taskID) was written",
                       line: line)
    }

    /// Two folders whose first task has the same id — B's the active one — and A's task, created
    /// in A (the folder open when this returns).
    func sameIDTasks(activeInA: Bool = true) async throws -> (a: Int, bTaskJSON: URL) {
        await sut.openWorkFolder(folderB)
        let bCreated = await sut.createTask(title: "B one", supervisorTask: "b", makeActive: true)
        let bOne = try XCTUnwrap(bCreated)
        await sut.openWorkFolder(folderA)
        let aCreated = await sut.createTask(title: "A one", supervisorTask: "a", makeActive: activeInA)
        let aOne = try XCTUnwrap(aCreated)
        XCTAssertEqual(aOne, bOne, "premise: both folders number their first task the same")
        return (aOne, NTMSPaths(workFolderRoot: folderB).taskJSON(taskID: bOne))
    }

    /// The three files of `folder` a create touches, read from disk.
    func createdState(_ folder: URL) -> (index: TasksIndex?, state: WorkFolderState?) {
        let paths = NTMSPaths(workFolderRoot: folder)
        return (try? AtomicJSONStore().read(TasksIndex.self, from: paths.tasksIndexJSON),
                try? AtomicJSONStore().read(WorkFolderState.self, from: paths.workFolderJSON))
    }

    /// A pending active-task write the test releases — what a `createTask` flushes first.
    func holdPendingPointerWrite() -> AsyncStream<Void>.Continuation {
        let (release, released) = AsyncStream<Void>.makeStream()
        sut.pendingActiveTaskWrite = Task<Void, Error> { for await _ in release { break } }
        return released
    }

    /// Waits until exactly `count` automation poll loops are alive, or fails.
    func waitForLiveLoops(_ count: Int, _ what: String, line: UInt = #line) async throws {
        for _ in 0..<600 {
            if sut._testLiveAutomationLoops == count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("\(what): \(sut._testLiveAutomationLoops) poll loops are alive, expected \(count)", line: line)
    }

    /// A recurring task of A whose slot passed while the app was closed, and A opened and left.
    func missedRecurrence() async throws -> (taskID: Int, missed: Date) {
        await sut.openWorkFolder(folderA)
        let created = await sut.createTask(title: "recurring", supervisorTask: "x")
        let taskID = try XCTUnwrap(created)
        let missed = Date(timeIntervalSinceNow: -7200)
        await sut.mutateTask(taskID: taskID) {
            $0.recurrence = TaskRecurrence(rule: .interval(seconds: 3600), isEnabled: true, nextFireAt: missed)
        }
        return (taskID, missed)
    }

    /// Holds A's reconcile — the write rescheduling the missed slot of `taskID`.
    func holdReconcile(of taskID: Int, missed: Date) -> TaskWriteHold {
        let path = folderA.path
        let hold = TaskWriteHold { written, task in
            written.path == path && task.id == taskID
                && (task.recurrence?.nextFireAt).map { $0 > missed.addingTimeInterval(60) } == true
        }
        repository.taskWriteHold = hold
        return hold
    }

    /// A committed open of `folder`, held at its first step after its read.
    func holdCommittedOpen(of folder: URL) async throws -> (Task<Void, Never>, StepHold) {
        try await holdOpen(of: folder, at: .delegationHistory)
    }

    /// A task of the open folder with a paused run — what an engine state is seeded from.
    func pausedTask(active: Bool) async throws -> Int {
        let created = await sut.createTask(title: "paused", supervisorTask: "x", makeActive: active)
        let taskID = try XCTUnwrap(created)
        _ = await sut.ensureTaskLoaded(taskID)
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, roleStatuses: ["worker": .working])
            run.steps = [StepExecution(id: "worker", role: .softwareEngineer, title: "Work", status: .paused)]
            task.runs = [run]
        }
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.count, 1, "premise: the paused run is written")
        return taskID
    }
}
