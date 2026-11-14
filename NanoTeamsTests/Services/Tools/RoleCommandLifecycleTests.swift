import XCTest

@testable import NanoTeams

/// A role's shell command is its process group, and the group lives exactly as long as the
/// command: what it left running (`server &`) dies when it returns, every stop reaches the whole
/// group, and a reservation stops a command running in the foreground too (review 2026-11-08).
/// Live: real processes, each named by a sleep duration no other test uses — and matched by the
/// sleep's OWN command line (`^(/bin/)?sleep N$`), never by a shell's that merely mentions it: the
/// shell `zsh -lc "sleep 7707 & sleep 7708"` would otherwise satisfy a precondition before its
/// sleep exists, and the teardown's `pkill` would kill any shell whose script names the duration.
final class RoleCommandLifecycleTests: XCTestCase {

    private var work: URL!

    override func setUp() {
        super.setUp()
        work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-lifecycle-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDown() {
        BackgroundBashRegistry.shared.terminate(taskID: 7701)
        _ = try? ProcessRunner.run(
            executable: "/usr/bin/pkill", arguments: ["-f", Self.sleeping("77[0-9][0-9]")], currentDirectory: nil)
        if let work { try? FileManager.default.removeItem(at: work) }
        work = nil
        super.tearDown()
    }

    /// The command line of a `sleep` whose duration matches `seconds` (an extended regex) — the
    /// sleep itself, spawned as `sleep N` by a shell or as `/bin/sleep N` directly.
    private static func sleeping(_ seconds: String) -> String { "^(/bin/)?sleep \(seconds)$" }

    /// Whether a `sleep` whose duration matches `seconds` is alive — polled until it is in the
    /// state the caller waits for (`expectGone`: gone; otherwise running) or `within` has passed,
    /// and then the LAST observation, never the expectation: returning the expectation at the
    /// deadline made every "the leftover died" assertion here pass after five seconds with the
    /// leftover alive (what let mutation N4 survive, 2026-11-08).
    private func alive(sleeping seconds: String, expectGone: Bool = true, within timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let found = (try? ProcessRunner.run(
                executable: "/usr/bin/pgrep", arguments: ["-f", Self.sleeping(seconds)], currentDirectory: nil))?
                .exitCode == 0
            if found != expectGone || Date() >= deadline { return found }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    // MARK: - CommandProcessGroup

    func testAGroupIsNeverTheAppsOwnNorNone() {
        XCTAssertNil(CommandProcessGroup(id: getpgrp()), "a signal for a command can never reach the app's group")
        XCTAssertNil(CommandProcessGroup(id: 0))
        XCTAssertNil(CommandProcessGroup(id: -5))
        XCTAssertNil(CommandProcessGroup(id: 1), "`kill(-1, …)` is a broadcast to every process the user can signal")
        XCTAssertFalse(CommandProcessGroup(id: 999_999)?.signal(0) ?? true, "a group that is not there receives nothing")
    }

    /// A leader that moved itself into ANOTHER process group is still stopped. Unconfined, the
    /// leader IS the role's own command (`ProcessRunner.runShell` with no profile runs the login
    /// shell directly), so it can leave the group NanoTeams recorded — measured 2026-11-08: the
    /// group signal then returns ESRCH and the command runs on. NanoTeams holds the leader's pid,
    /// and a pid it has not reaped cannot be another process, so the stop reaches it there.
    /// Confined, the leader is `sandbox-exec` and a role cannot move it: it is not the role's
    /// child. What the role takes out of the group itself stays in DEBTS.md D-M16.
    func testACommandWhoseLeaderLeftItsGroupIsStillStopped() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // `exec` keeps the pid, so the leader itself is what moves — as a role's command that
        // execs a process manager would. It joins the app's own group, which NanoTeams refuses
        // to signal by design, so no group signal can reach it.
        process.arguments = ["-lc", "exec /usr/bin/python3 -I -c "
            + "'import os,time; os.setpgid(0, os.getpgid(os.getppid())); time.sleep(7712)'"]
        try process.run()
        defer { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }
        let group = try XCTUnwrap(CommandProcessGroup(leading: process))
        for _ in 0..<100 where getpgid(process.processIdentifier) == group.id {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(getpgid(process.processIdentifier), getpgrp(), "precondition: the leader left its group")
        XCTAssertTrue(process.isRunning)

        XCTAssertTrue(CommandProcessGroup.kill(group, process: process), "the stop reached the command")
        CommandProcessGroup.awaitExit(of: [process], timeout: 5)
        XCTAssertFalse(process.isRunning, "a leader that left its group is still stopped")
    }

    /// The child leads a group of its own, and one signal reaches it and what it started — also
    /// after the leader exited, which is how a command's leftovers are stopped.
    func testTheGroupReachesWhatTheCommandStarted_evenAfterItsLeaderExited() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 7701 & exit 0"]
        try process.run()
        let group = try XCTUnwrap(CommandProcessGroup(leading: process))
        XCTAssertEqual(group.id, process.processIdentifier, "the child is its group's leader")
        XCTAssertNotEqual(group.id, getpgrp())
        process.waitUntilExit()
        XCTAssertTrue(alive(sleeping: "7701", expectGone: false, within: 2), "precondition: the leftover runs")
        XCTAssertTrue(group.signal(SIGKILL), "the group still has a member")
        XCTAssertFalse(alive(sleeping: "7701"), "the leftover died with the group")
        XCTAssertFalse(group.signal(0), "and the group is gone")
    }

    /// A child that already exited is still recorded — it was made the leader at the spawn, so
    /// its pid is its group's id, and `getpgid` answering ESRCH says only that the leader is
    /// reaped — while a process that never ran has no pid and no group.
    func testAGroupIsRecordedForAChildThatExited_andNoneForOneThatNeverRan() throws {
        XCTAssertNil(CommandProcessGroup(leading: Process()), "no pid, no group")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        let group = try XCTUnwrap(CommandProcessGroup(leading: process), "recorded after the exit")
        XCTAssertEqual(group.id, process.processIdentifier)
        XCTAssertFalse(group.hasMembers, "and empty")
    }

    /// A leader that is not leading its own group gets no group: a signal to the group numbered
    /// by its pid would go to whoever owns that group — here the app's own. The leader itself
    /// is still reachable, by its pid, which is the only stop such a command has.
    func testNoGroupIsRecordedForALeaderInAnotherGroup_andTheLeaderIsStillStopped() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-c", "import os,time; os.setpgid(0, os.getpgid(os.getppid())); time.sleep(7716)"]
        try process.run()
        defer { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }
        for _ in 0..<100 where getpgid(process.processIdentifier) != getpgrp() {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(getpgid(process.processIdentifier), getpgrp(), "precondition: the leader is in the app's group")
        XCTAssertNil(CommandProcessGroup(leading: process), "never the app's own group")

        XCTAssertTrue(CommandProcessGroup.stop(SIGKILL, group: nil, process: process), "the leader by its pid")
        CommandProcessGroup.awaitExit(of: [process], timeout: 5)
        XCTAssertFalse(process.isRunning)
        XCTAssertFalse(CommandProcessGroup.stop(SIGKILL, group: nil, process: process), "a finished command is not signalled")
    }

    // MARK: - ProcessRunner

    /// A foreground `bash` command's leftovers die when it returns, and the call does not wait out
    /// the pipe drain for them (a backgrounded child holds stdout open).
    func testRunShell_killsWhatTheCommandLeftRunning() throws {
        let started = Date()
        let result = try ProcessRunner.runShell("sleep 7702 & echo started", in: work, timeout: 30, sandboxProfile: nil)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("started"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 4, "no five-second drain wait for the leftover")
        XCTAssertFalse(alive(sleeping: "7702"), "the leftover died with its command")
    }

    /// The control: git and xcodebuild do not reap their group — a build service that outlives one
    /// build is how the next one is fast.
    func testRun_withoutReaping_leavesTheGroupAlone() throws {
        _ = try ProcessRunner.run(
            executable: "/bin/sh", arguments: ["-c", "sleep 7703 >/dev/null 2>&1 & echo x"], currentDirectory: work)
        XCTAssertTrue(alive(sleeping: "7703", expectGone: false, within: 2), "a plain run leaves it")
    }

    /// A command that ignores SIGTERM no longer hangs a timeout: two seconds' grace, then SIGKILL —
    /// to the whole group for `bash`.
    func testATimeoutEscalatesToSIGKILL_forACommandThatIgnoresSIGTERM() throws {
        let started = Date()
        XCTAssertThrowsError(try ProcessRunner.runShell(
            "trap '' TERM; sleep 7704 & sleep 7705; wait", in: work, timeout: 1, sandboxProfile: nil)) { error in
            guard case ProcessRunnerError.timeout = error else { return XCTFail("\(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
        XCTAssertFalse(alive(sleeping: "770[45]"), "the whole group is gone")

        let plainStart = Date()
        XCTAssertThrowsError(try ProcessRunner.run(
            executable: "/bin/sh", arguments: ["-c", "trap '' TERM; while :; do sleep 0.1; done"],
            currentDirectory: work, timeout: 1))
        XCTAssertLessThan(Date().timeIntervalSince(plainStart), 8, "the leader alone, without a group")
    }

    // MARK: - Background commands

    /// What a background command left running dies when its shell exits: a process that outlived
    /// it would keep this command's profile with nothing tracking it.
    func testABackgroundCommandsLeftoversDieWithItsShell() throws {
        let id = try BackgroundBashRegistry.shared.start(
            command: "sleep 7706 & exit 0", directory: work, confinement: nil, taskID: 7701)
        for _ in 0..<100 where BackgroundBashRegistry.shared.read(commandID: id)?.running == true {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(BackgroundBashRegistry.shared.read(commandID: id)?.running, false)
        XCTAssertFalse(alive(sleeping: "7706"))
    }

    /// `bash_output stop` reaches the whole group — the shell AND the server it started — which is
    /// now the only way a role stops its own background command.
    func testStop_reachesTheWholeGroup() throws {
        let id = try BackgroundBashRegistry.shared.start(
            command: "sleep 7707 & sleep 7708", directory: work, confinement: nil, taskID: 7701)
        XCTAssertTrue(alive(sleeping: "7707", expectGone: false, within: 3), "precondition")
        XCTAssertTrue(BackgroundBashRegistry.shared.stop(commandID: id))
        XCTAssertFalse(alive(sleeping: "7707"))
        XCTAssertFalse(alive(sleeping: "7708"))
    }

    /// The signal at exit is the command's, not the registry's: what a background command left
    /// running dies when its shell exits even if the registry that started it is gone by then.
    func testLeftoversDieAtExit_evenWhenTheRegistryThatStartedThemIsGone() throws {
        var registry: BackgroundBashRegistry? = BackgroundBashRegistry()
        _ = try XCTUnwrap(registry).start(
            command: "sleep 7717 & sleep 0.5", directory: work, confinement: nil, taskID: 7701)
        XCTAssertTrue(alive(sleeping: "7717", expectGone: false, within: 2), "precondition: the leftover runs")
        registry = nil
        XCTAssertFalse(alive(sleeping: "7717"), "the shell exited half a second in, and its leftover died with it")
    }

    // MARK: - Foreground commands and reservations

    /// A run an earlier reservation already marked is not marked again — the first stop's reason
    /// stands — and a run whose profile holds every reserved port is not touched.
    func testAReservationSkipsARunAlreadyMarked_andOneHoldingThePorts() throws {
        let reservations = LoopbackPortReservations(registry: .shared)
        func spawn(_ seconds: Int) throws -> (Process, CommandProcessGroup?) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = [String(seconds)]
            try process.run()
            return (process, CommandProcessGroup(leading: process))
        }
        let (stale, staleGroup) = try spawn(7720)
        defer { if stale.isRunning { stale.terminate() } }
        let run = reservations.trackForeground(stale, group: staleGroup, guardedPorts: [47321])
        reservations.reserve([3845])
        CommandProcessGroup.awaitExit(of: [stale], timeout: 5)
        XCTAssertFalse(stale.isRunning, "precondition: the first reservation stopped it")
        reservations.reserve([3846])
        let reason = try XCTUnwrap(reservations.untrackForeground(run))
        XCTAssertTrue(reason.contains("3845"), reason)
        XCTAssertFalse(reason.contains("3846"), "the first stop's reason stands: \(reason)")

        let (holding, holdingGroup) = try spawn(7721)
        defer { holding.terminate() }
        let kept = reservations.trackForeground(holding, group: holdingGroup, guardedPorts: [47321, 3845, 3846])
        reservations.reserve([3845, 3846])
        XCTAssertTrue(holding.isRunning, "a run holding the ports is left alone")
        XCTAssertNil(reservations.untrackForeground(kept))
    }

    /// A run whose command had already finished when a reservation reached it is not reported
    /// stopped — nothing was stopped, and a reason would be a lie — on both paths: the scan in
    /// `reserve`, and `attach` finding a port reserved before the pid was known.
    func testAFinishedForegroundRunIsNotReportedStopped() throws {
        let reservations = LoopbackPortReservations(registry: .shared)
        func finished() throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            try process.run()
            process.waitUntilExit()
            return process
        }
        let scanned = try finished()
        let scannedRun = reservations.trackForeground(
            scanned, group: CommandProcessGroup(leading: scanned), guardedPorts: [47321])
        reservations.reserve([3845])
        XCTAssertNil(reservations.untrackForeground(scannedRun), "finished before the reservation: no stop, no reason")

        let attached = try finished()
        let pending = reservations.beginForeground(guardedPorts: [47321])
        reservations.attach(attached, group: CommandProcessGroup(leading: attached), to: pending)
        XCTAssertNil(reservations.untrackForeground(pending), "the port was reserved before it attached, but it had finished")
        XCTAssertEqual(reservations._testTrackedForegroundCount, 0)
    }

    /// A foreground run tracked under a profile older than a reservation is stopped at once, and
    /// `untrackForeground` says why; one tracked with the port is left alone.
    func testTrackForeground_stopsARunWhoseProfilePredatesAReservation() throws {
        let reservations = LoopbackPortReservations(registry: .shared)
        reservations.reserve([3845])
        func spawn(_ seconds: Int) throws -> (Process, CommandProcessGroup?) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = [String(seconds)]
            try process.run()
            return (process, CommandProcessGroup(leading: process))
        }
        let (stale, staleGroup) = try spawn(7709)
        defer { if stale.isRunning { stale.terminate() } }
        let run = reservations.trackForeground(stale, group: staleGroup, guardedPorts: [47321])
        // Bounded: a run that is NOT stopped must fail this test, not hang it for 7709 seconds
        // (`waitUntilExit()` did, under mutation N8).
        CommandProcessGroup.awaitExit(of: [stale], timeout: 5)
        XCTAssertFalse(stale.isRunning, "the stale run was stopped")
        if !stale.isRunning { XCTAssertEqual(stale.terminationStatus, SIGKILL) }
        XCTAssertTrue(reservations.untrackForeground(run)?.contains("3845") == true)

        let (fresh, freshGroup) = try spawn(7710)
        defer { fresh.terminate() }
        let kept = reservations.trackForeground(fresh, group: freshGroup, guardedPorts: [47321, 3845])
        XCTAssertTrue(fresh.isRunning)
        XCTAssertNil(reservations.untrackForeground(kept))
    }

    /// A reservation that lands while a confined run is being SPAWNED — announced, no pid yet —
    /// waits for the spawn and returns only once the command is stopped: the caller dials next,
    /// and until 2026-11-08 a run was tracked only once it had a pid, so a reservation in that
    /// window returned past a child it never saw while the child came up under the old profile.
    func testAReservationLandingWhileARunIsBeingSpawned_waitsForTheSpawnAndStopsIt() throws {
        let reservations = LoopbackPortReservations(registry: .shared)
        let run = reservations.beginForeground(guardedPorts: [47321])
        let reserved = expectation(description: "reserve returned")
        let returnedAt = ReturnStamp()
        DispatchQueue.global().async {
            reservations.reserve([3845])
            returnedAt.date = Date()
            reserved.fulfill()
        }
        // The reservation is in flight against a run with no process; now the child appears.
        Thread.sleep(forTimeInterval: 0.2)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["7714"]
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let attachedAt = Date()
        reservations.attach(process, group: CommandProcessGroup(leading: process), to: run)

        wait(for: [reserved], timeout: 3)
        XCTAssertFalse(process.isRunning, "stopped before the reservation returned")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(returnedAt.date), attachedAt, "reserve waited for the spawn")
        XCTAssertTrue(reservations.untrackForeground(run)?.contains("3845") == true, "and the run knows why")
        XCTAssertEqual(reservations._testTrackedForegroundCount, 0)
    }

    /// A run announced and never attached — the spawn failed — holds a reservation for a second
    /// at most, and `untrackForeground` drops it.
    func testAReservationDoesNotWaitForeverForASpawnThatNeverCame() {
        let reservations = LoopbackPortReservations(registry: .shared)
        let run = reservations.beginForeground(guardedPorts: [47321])
        let started = Date()
        reservations.reserve([3845])
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
        XCTAssertTrue(reservations.untrackForeground(run)?.contains("3845") == true)
    }

    /// What a stopped command's leftovers hold is awaited too: the leader exited at once, the
    /// group still has a member, and `awaitExit` returns only once the group is empty.
    func testAwaitExit_waitsForTheWholeGroup_notJustItsLeader() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 7715 & exit 0"]
        try process.run()
        let group = try XCTUnwrap(CommandProcessGroup(leading: process))
        CommandProcessGroup.awaitExit(of: [process], timeout: 5)
        XCTAssertFalse(process.isRunning, "precondition: the leader exited")
        XCTAssertTrue(alive(sleeping: "7715", expectGone: false, within: 2), "precondition: the leftover runs")
        XCTAssertTrue(group.hasMembers)

        let waited = Date()
        CommandProcessGroup.awaitExit(of: [(process: process, group: group)], timeout: 0.3)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(waited), 0.25, "it waited for the group, not the leader")
        XCTAssertTrue(group.hasMembers, "and the group was still there")

        group.signal(SIGKILL)
        let killed = Date()
        CommandProcessGroup.awaitExit(of: [(process: process, group: group)], timeout: 3)
        XCTAssertLessThan(Date().timeIntervalSince(killed), 2, "returns as soon as the group is empty")
        XCTAssertFalse(group.hasMembers)
        XCTAssertFalse(alive(sleeping: "7715"))
    }

    /// The live path: a sandboxed foreground `bash` command running when a port is reserved is
    /// stopped, and its result says NanoTeams stopped it — its exit is not the command's own.
    func testAForegroundBashCommandRunningDuringAReservationIsStopped_live() async throws {
        guard FileManager.default.isExecutableFile(atPath: BashConstants.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec unavailable on this host")
        }
        let reservations = LoopbackPortReservations.shared
        reservations._testForget()
        defer { reservations._testForget() }
        let tool = BashTool(
            workFolderRoot: work, resolver: SandboxPathResolver(workFolderRoot: work), fileManager: .default)
        let context = ToolExecutionContext(workFolderRoot: work, taskID: 7701, runID: 0, roleID: "r")
        let before = reservations._testTrackedForegroundCount
        // A 20-second timeout bounds the run when nothing stops it, so the failure comes in
        // seconds rather than after the default two minutes.
        let running = Task { await tool.handle(context: context, args: ["command": "sleep 7711", "timeout": 20_000]) }
        for _ in 0..<200 where reservations._testTrackedForegroundCount == before {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertGreaterThan(reservations._testTrackedForegroundCount, before, "precondition: it is tracked")
        reservations.reserve([47_612])
        let result = await running.value
        let object = (try? JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8))) as? [String: Any] ?? [:]
        let warnings = (object["meta"] as? [String: Any])?["warnings"] as? [String] ?? []
        XCTAssertTrue(warnings.contains { $0.contains("47612") && $0.contains("NanoTeams stopped") }, "\(result.outputJSON)")
        XCTAssertNotEqual((object["data"] as? [String: Any])?["exit_code"] as? Int, 0)
        XCTAssertEqual(reservations._testTrackedForegroundCount, before, "forgotten once it returned")
    }

    /// The timeout arm of the same envelope: a sandboxed foreground command that runs out of
    /// time is untracked like one that returned, no stop is reported — the clock ended it, not a
    /// reservation — and a planning-phase result still says its writes were blocked.
    func testAConfinedForegroundCommandThatTimesOut_isUntrackedAndReportsThePhase_live() async throws {
        guard FileManager.default.isExecutableFile(atPath: BashConstants.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec unavailable on this host")
        }
        let reservations = LoopbackPortReservations.shared
        let before = reservations._testTrackedForegroundCount
        let tool = BashTool(
            workFolderRoot: work, resolver: SandboxPathResolver(workFolderRoot: work), fileManager: .default)
        let context = ToolExecutionContext(
            workFolderRoot: work, taskID: 7701, runID: 0, roleID: "r", isPlanningPhase: true)
        let result = await tool.handle(context: context, args: ["command": "sleep 7719", "timeout": 500])
        let object = (try? JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8))) as? [String: Any] ?? [:]
        let data = object["data"] as? [String: Any] ?? [:]
        XCTAssertEqual(data["timed_out"] as? Bool, true, result.outputJSON)
        XCTAssertEqual(data["sandboxed"] as? Bool, true, result.outputJSON)
        XCTAssertEqual(data["writes_blocked"] as? Bool, true, "the phase is reported on a timeout too")
        XCTAssertEqual((object["meta"] as? [String: Any])?["warnings"] as? [String] ?? [], [], "nothing stopped it but the clock")
        XCTAssertEqual(reservations._testTrackedForegroundCount, before, "forgotten once it returned")
        XCTAssertFalse(alive(sleeping: "7719"), "the timed-out command is gone")
    }
}

/// A `Date` written on one thread and read after an expectation it fulfilled — the ordering the
/// expectation provides is what makes this safe.
private final class ReturnStamp: @unchecked Sendable {
    var date: Date?
}
