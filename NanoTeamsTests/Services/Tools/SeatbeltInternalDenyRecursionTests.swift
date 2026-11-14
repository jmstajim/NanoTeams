import XCTest

@testable import NanoTeams

/// What the F1 deny of `.nanoteams/internal` costs an ordinary recursive command run from the work
/// folder's root (F6 S8, 2026-11-12, recorded in DEBTS D-M17).
///
/// The profile denies `file-read*` on `(subpath <work>/.nanoteams/internal)`, and a subpath covers
/// the directory node itself: `stat` and `opendir` of `internal` are refused, so a walk that reaches
/// it reports an error and exits non-zero, even when everything else it was asked for succeeded.
/// This class MEASURES that, live, and pins the measurement — the DEBTS entry quotes these exit
/// codes, and a profile change that moves one turns the class red so the entry is re-measured.
final class SeatbeltInternalDenyRecursionTests: XCTestCase {

    private var work: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard FileManager.default.isExecutableFile(atPath: BashConstants.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec unavailable on this host")
        }
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("nt-sbrecursion-\(UUID().uuidString)", isDirectory: true)
        let internalDir = work.appendingPathComponent(".nanoteams/internal", isDirectory: true)
        try FileManager.default.createDirectory(at: internalDir, withIntermediateDirectories: true)
        try "SECRET needle".write(to: internalDir.appendingPathComponent("teams.json"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: work.appendingPathComponent("src", isDirectory: true), withIntermediateDirectories: true)
        try "let needle = 1".write(to: work.appendingPathComponent("src/a.swift"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        if let work { try? FileManager.default.removeItem(at: work) }
        work = nil
        try super.tearDownWithError()
    }

    /// Runs `command` from the work folder's root under the role profile and returns its output
    /// with the exit status on the last line (`EXIT=<n>`).
    private func runSandboxed(_ command: String) throws -> (output: String, exit: Int) {
        let profile = SeatbeltSandbox.profile(
            workFolderRoot: work, permissions: BashSandboxPermissions(), guardedLoopbackPorts: [])
        let (exe, args) = SeatbeltSandbox.wrap(
            profile: profile, shell: "/bin/zsh", command: "\(command) 2>&1; echo EXIT=$?")
        let out = try ProcessRunner.run(executable: exe, arguments: args, currentDirectory: work, timeout: 30).stdout
        let exitLine = out.split(separator: "\n").last(where: { $0.hasPrefix("EXIT=") }) ?? "EXIT=-1"
        return (out, Int(exitLine.dropFirst("EXIT=".count)) ?? -1)
    }

    /// `find .` lists the whole tree but `internal` itself, and exits 1.
    func testFindFromTheRoot_exitsOne_andStillListsTheRest() throws {
        let (out, exit) = try runSandboxed("find .")
        XCTAssertEqual(exit, 1, out)
        XCTAssertTrue(out.contains("./src/a.swift"), out)
        XCTAssertTrue(out.contains("Operation not permitted"), out)
        XCTAssertFalse(out.contains("teams.json"), out)
    }

    /// `grep -rn` finds the match outside `internal` and still exits 2 — the code grep keeps for
    /// "an error occurred", which outranks "a line matched".
    func testRecursiveGrepFromTheRoot_exitsTwo_evenWithAMatch() throws {
        let (out, exit) = try runSandboxed("grep -rn needle .")
        XCTAssertEqual(exit, 2, out)
        XCTAssertTrue(out.contains("./src/a.swift:1:let needle = 1"), out)
        XCTAssertFalse(out.contains("SECRET"), out)
    }

    /// `du` and `cp -R` of the root fail the same way; `cp` copies everything else.
    func testDuAndCopyOfTheRoot_exitOne() throws {
        let du = try runSandboxed("du -sh .")
        XCTAssertEqual(du.exit, 1, du.output)
        // Into a directory inside the work folder (the profile lets the role write there): the copy
        // of `.nanoteams` carries everything but `internal`, and `cp` exits 1.
        let cp = try runSandboxed("mkdir -p out && cp -R .nanoteams out/")
        XCTAssertEqual(cp.exit, 1, cp.output)
        XCTAssertTrue(cp.output.contains("Operation not permitted"), cp.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.appendingPathComponent("out/.nanoteams").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: work.appendingPathComponent("out/.nanoteams/internal/teams.json").path))
    }

    /// The same commands scoped to a directory that does not contain `.nanoteams` exit 0 — the
    /// non-zero codes above come from `internal`, not from the fixture.
    func testTheSameCommandsBelowTheRoot_exitZero() throws {
        XCTAssertEqual(try runSandboxed("find src").exit, 0)
        XCTAssertEqual(try runSandboxed("grep -rn needle src").exit, 0)
        XCTAssertEqual(try runSandboxed("du -sh src").exit, 0)
    }

    /// The way around that `BashTool.sandboxDenialWarnings` gives the role (D-M19 S8): leaving
    /// `.nanoteams` out of the walk exits 0 and still finds what is outside it.
    func testTheAdvisedExclusions_exitZero_andStillFindTheRest() throws {
        let grep = try runSandboxed("grep -rn --exclude-dir=.nanoteams needle .")
        XCTAssertEqual(grep.exit, 0, grep.output)
        XCTAssertTrue(grep.output.contains("./src/a.swift:1:let needle = 1"), grep.output)
        let find = try runSandboxed("find . -path ./.nanoteams -prune -o -print")
        XCTAssertEqual(find.exit, 0, find.output)
        XCTAssertTrue(find.output.contains("./src/a.swift"), find.output)
    }

    /// What the role actually reads after `find .` / `grep -r` from the root: the warning that
    /// names `internal` and the way around it — not the generic one about write scopes and ports,
    /// which sends a model looking for a permission it lacks (D-M19 S8).
    func testRealStderrFromTheRoot_getsTheInternalWarning_notTheGenericOne() throws {
        for command in ["find .", "grep -rn needle .", "du -sh ."] {
            let (out, exit) = try runSandboxed(command)
            let warnings = BashTool.sandboxDenialWarnings(
                ranSandboxed: true, isPlanningPhase: false, exitCode: Int32(exit), stderr: out,
                guardedPorts: [47321])
            XCTAssertEqual(warnings, [BashTool.internalDenialWarning], "\(command): \(out)")
        }
    }

    /// Listing `.nanoteams` names `internal` but cannot describe it.
    func testListingDotNanoteams_reportsInternalAsNotPermitted() throws {
        let (out, exit) = try runSandboxed("ls -la .nanoteams")
        XCTAssertEqual(exit, 1, out)
        XCTAssertTrue(out.contains("internal"), out)
        XCTAssertTrue(out.contains("Operation not permitted"), out)
    }
}
