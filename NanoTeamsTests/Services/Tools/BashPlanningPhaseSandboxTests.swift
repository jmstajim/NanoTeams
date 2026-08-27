import XCTest

@testable import NanoTeams

/// The feature's central claim, measured against the real `sandbox-exec`: during a role's
/// planning phase `bash` may READ whatever the user's own grants allow and may WRITE nothing.
///
/// Everything else about this change is arrangement — which set holds `bash`, which flag reaches
/// which layer. This suite is the only place that proves the guarantee actually holds, and it
/// proves it the only way a kernel guarantee can be proved: by running a command and looking at
/// the filesystem afterwards. A profile-TEXT assertion would pass whether or not the flag ever
/// reached `BashTool`.
///
/// Live, like its neighbours in `SeatbeltSandboxTests`, and skipped the same way when the binary
/// is unavailable — a vacuous green here would be worse than no test.
final class BashPlanningPhaseSandboxTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard FileManager.default.isExecutableFile(atPath: BashConstants.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec unavailable on this host")
        }
        // Deliberately under NSTemporaryDirectory(): with `tempWrite` cleared alongside
        // `workFolderWrite` the guarantee no longer depends on where the work folder lives,
        // and `testPlanning_workFolderUnderTemp_isStillWriteBlocked` below pins exactly that.
        workDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nanoteams-planning-sandbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
        super.tearDown()
    }

    /// The user's DEFAULT grants — work + temp writable. The narrowing has to come from the
    /// phase, not from a fixture that was already locked down.
    private func makeTool() -> BashTool {
        BashTool(
            workFolderRoot: workDir,
            resolver: SandboxPathResolver(workFolderRoot: workDir),
            fileManager: .default,
            sandboxEnabled: true,
            sandboxPermissions: BashSandboxPermissions(),
            allowUnsandboxedFallback: false)
    }

    private func context(isPlanningPhase: Bool) -> ToolExecutionContext {
        ToolExecutionContext(workFolderRoot: workDir, taskID: 1, runID: 0, roleID: "r",
                             isPlanningPhase: isPlanningPhase)
    }

    private func data(_ json: String) -> [String: Any]? {
        guard let d = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return nil }
        return obj["data"] as? [String: Any]
    }

    /// Reading is the entire point of the phase. If the narrowing broke reads, the feature would
    /// be worse than the prohibition it replaces.
    ///
    /// RED: clear a read scope in `withWritesDisabled()` → `cat` cannot read and the exit-code
    /// assertion fails.
    func testPlanning_readSucceeds() async throws {
        let note = workDir.appendingPathComponent("note.txt")
        try "findings".write(to: note, atomically: true, encoding: .utf8)

        let r = await makeTool().handle(
            context: context(isPlanningPhase: true), args: ["command": "cat note.txt"])

        XCTAssertFalse(r.isError, r.outputJSON)
        XCTAssertEqual(data(r.outputJSON)?["exit_code"] as? Int, 0, r.outputJSON)
        XCTAssertTrue((data(r.outputJSON)?["stdout"] as? String ?? "").contains("findings"))
    }

    /// **This one test is the feature.** The command runs; the kernel refuses the write; the
    /// file does not exist afterwards.
    ///
    /// Asserting on the FILESYSTEM rather than on the exit code is deliberate: a wrong exit code
    /// is a diagnosis, but only the absent file proves nothing was mutated.
    ///
    /// RED: use `sandboxPermissions` instead of `effectivePermissions` in `BashTool.handle` →
    /// the file appears and the fileExists assertion fails.
    func testPlanning_writeIsDeniedByTheKernel() async {
        let target = workDir.appendingPathComponent("out.txt")
        let r = await makeTool().handle(
            context: context(isPlanningPhase: true), args: ["command": "echo x > out.txt"])

        XCTAssertNotEqual(data(r.outputJSON)?["exit_code"] as? Int, 0,
                          "the shell must report the refusal: \(r.outputJSON)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path),
                       "a write survived the planning-phase sandbox")
        XCTAssertEqual(data(r.outputJSON)?["writes_blocked"] as? Bool, true)
    }

    /// Closes the loop between the retry-contract heuristic and what the kernel ACTUALLY says.
    /// `planningWriteDenialMeta` matches on `operation not permitted`, and the only evidence
    /// that string is the right one is a real denial producing it — measured here rather than
    /// asserted from a hand-written stderr, which would pin the heuristic against itself.
    /// (Measured 2026-08-15, zsh: `zsh:1: operation not permitted: <path>`. The match is
    /// case-folded, so a `strerror`-capitalised variant from another shell still hits.)
    ///
    /// RED: change the needle in `planningWriteDenialMeta` to anything else → no warning reaches
    /// the envelope.
    func testPlanning_writeDenial_carriesTheRetryContractForARealKernelRefusal() async {
        let r = await makeTool().handle(
            context: context(isPlanningPhase: true), args: ["command": "echo x > out.txt"])

        guard let d = r.outputJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let meta = obj["meta"] as? [String: Any]
        else { return XCTFail("no meta in \(r.outputJSON)") }

        XCTAssertTrue((meta["warnings"] as? [String] ?? []).contains { $0.contains("update_scratchpad") },
                      "a real sandbox refusal must teach the retry contract: \(r.outputJSON)")
    }

    /// Control: the narrowing is scoped to the phase. Without this, applying it unconditionally
    /// would look identical in the test above while silently breaking every implementation-phase
    /// bash command in the product.
    ///
    /// RED: apply the narrowing unconditionally → the implementation-phase write is refused too
    /// and both assertions fail.
    func testImplementation_theSameWriteSucceeds() async {
        let target = workDir.appendingPathComponent("out.txt")
        let r = await makeTool().handle(
            context: context(isPlanningPhase: false), args: ["command": "echo x > out.txt"])

        XCTAssertEqual(data(r.outputJSON)?["exit_code"] as? Int, 0, r.outputJSON)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    /// `tempWrite` is cleared with the rest, so the guarantee does not depend on the work folder
    /// living outside a granted temp path. The whole fixture is under `$TMPDIR`, so a narrowing
    /// that kept temp writable would let this write through while every other test here stayed
    /// green.
    ///
    /// RED: restore `narrowed.tempWrite = true` in `withWritesDisabled()` → the write succeeds
    /// and the file exists.
    func testPlanning_workFolderUnderTemp_isStillWriteBlocked() async {
        let target = workDir.appendingPathComponent("under-tmp.txt")
        _ = await makeTool().handle(
            context: context(isPlanningPhase: true),
            args: ["command": "echo x > under-tmp.txt"])

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path),
                       "the temp grant covered a work folder under $TMPDIR")
    }

    /// `/dev/null` and friends stay writable, which is what keeps the idioms a reading command
    /// actually uses — `2>/dev/null`, pipes — working inside the phase.
    ///
    /// RED: drop the dev-node literals from the write clause → the redirect fails and the
    /// exit-code assertion does not hold.
    func testPlanning_devNullRedirectStillWorks() async throws {
        try "findings".write(to: workDir.appendingPathComponent("note.txt"),
                             atomically: true, encoding: .utf8)
        let r = await makeTool().handle(
            context: context(isPlanningPhase: true),
            args: ["command": "cat note.txt 2>/dev/null"])

        XCTAssertEqual(data(r.outputJSON)?["exit_code"] as? Int, 0, r.outputJSON)
    }
}
