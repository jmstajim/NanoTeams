import Darwin
import XCTest

@testable import NanoTeams

/// A headless run on a folder another NanoTeams process holds (D-M18 C1: one process per
/// folder) — most often the developer's own app, with the same folder open.
///
/// Until 2026-11-12 the run returned `.error`, the receipt still said `ran` (written before
/// the run), and `run_headless.sh` printed "Headless run failed (exit code: 65)": the refusal
/// was printed only on the test host's stdout, which never reaches the wrapper (CLAUDE.md,
/// Headless Testing, fact 2). The runner now reports `.folderInUse`, and the receipt turns
/// into `failed` with the refusal, which the wrapper prints under "DID NOT RUN".
@MainActor
final class HeadlessRunnerFolderInUseTests: XCTestCase {

    private var workFolder: URL!
    private var runner: HeadlessRunner!
    /// The other process's descriptor: a raw `flock` on the folder's lock file, the way another
    /// NanoTeams holds it (`WorkFolderSecondProcessTests.holdAsAnotherProcess`).
    private var otherProcessFD: Int32 = -1

    override func setUp() async throws {
        try await super.setUp()
        workFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("headless-folder-in-use-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        runner = nil
        if otherProcessFD >= 0 { close(otherProcessFD) }
        otherProcessFD = -1
        if let workFolder { try? FileManager.default.removeItem(at: workFolder) }
        workFolder = nil
        try await super.tearDown()
    }

    private func holdAsAnotherProcess(pid: Int32) throws {
        let paths = NTMSPaths(workFolderRoot: workFolder)
        try FileManager.default.createDirectory(at: paths.internalDir, withIntermediateDirectories: true)
        otherProcessFD = open(paths.instanceLockFile.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(otherProcessFD, 0)
        XCTAssertEqual(flock(otherProcessFD, LOCK_EX | LOCK_NB), 0)
        let record = Data(#"{"pid":\#(pid),"since":"2026-11-12T01:00:00Z"}"#.utf8)
        _ = record.withUnsafeBytes { pwrite(otherProcessFD, $0.baseAddress, record.count, 0) }
    }

    private func makeRunner() throws -> HeadlessRunner {
        let json = """
        {"projectPath": "\(workFolder.path)", "taskTitle": "Held",
         "supervisorTask": "Never starts.", "teamTemplate": "codingAssistant",
         "timeoutSeconds": 1, "maxLLMRetries": 0}
        """
        let config = try JSONCoderFactory.makeWireDecoder().decode(HeadlessConfig.self, from: Data(json.utf8))
        return HeadlessRunner(config: config) { configuration in
            TestOrchestrator.make(configuration: configuration)
        }
    }

    /// RED on the code before 2026-11-12: the outcome was `.error`, and `afterRun` did not exist —
    /// the receipt stayed `ran`.
    func testAFolderHeldByAnotherProcess_isReportedAsNotRun_withTheHoldersPID() async throws {
        try holdAsAnotherProcess(pid: 4243)
        runner = try makeRunner()

        let result = await runner.run()

        XCTAssertEqual(result.outcome, .folderInUse)
        XCTAssertNil(result.taskID, "no task was created")
        let refusal = try XCTUnwrap(result.errors.first)
        XCTAssertTrue(refusal.contains("already open in another NanoTeams process (PID 4243)"), refusal)

        let receipt = try XCTUnwrap(HeadlessConfigLocator.Receipt.afterRun(result, configPath: "/c.json"))
        XCTAssertEqual(receipt.status, .failed, "a run that never started is not `ran`")
        XCTAssertEqual(receipt.configPath, "/c.json")
        XCTAssertTrue(receipt.detail.contains("did not start"), receipt.detail)
        XCTAssertTrue(receipt.detail.contains("PID 4243"), receipt.detail)
        XCTAssertTrue(receipt.detail.contains("Close the folder in the NanoTeams app"), receipt.detail)

        // The folder was not touched: only the other process's lock file is in `internal/`.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: NTMSPaths(workFolderRoot: workFolder).internalDir.path), ["instance.lock"])
    }

    /// Every other outcome keeps the `ran` written before the run — the policy names the
    /// refusal only, and a failed or timed-out run is still a run.
    func testEveryOtherOutcome_keepsTheRanReceipt() {
        for outcome in [HeadlessResult.Outcome.success, .timeout, .failed, .error] {
            let result = HeadlessResult(outcome: outcome, duration: 0, roleResults: [], artifacts: [],
                                        errors: ["openWorkFolder failed: something else"])
            XCTAssertNil(HeadlessConfigLocator.Receipt.afterRun(result, configPath: "/c.json"),
                         "\(outcome.rawValue) is a run")
        }
    }

    /// A refusal with no message (no banner text survived) still says what happened.
    func testARefusalWithoutAMessage_stillNamesTheCause() throws {
        let result = HeadlessResult(outcome: .folderInUse, duration: 0, roleResults: [], artifacts: [], errors: [])
        let receipt = try XCTUnwrap(HeadlessConfigLocator.Receipt.afterRun(result, configPath: "/c.json"))
        XCTAssertEqual(receipt.status, .failed)
        XCTAssertTrue(receipt.detail.contains("open in another NanoTeams process"), receipt.detail)
    }

    /// The same folder, free: the open is NOT refused (anti-vacuum for the PID test — the
    /// outcome is decided by the other holder, not by the fixture).
    func testTheSameFolderUnheld_isNotReportedAsInUse() async throws {
        runner = try makeRunner()
        let result = await runner.run()
        XCTAssertNotEqual(result.outcome, .folderInUse, result.errors.joined(separator: "; "))
        XCTAssertNil(HeadlessConfigLocator.Receipt.afterRun(result, configPath: "/c.json"))
    }
}
