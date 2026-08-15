import XCTest
@testable import NanoTeams

/// Pins the latch that keeps the bundled-update report readable after the open.
///
/// `WorkFolderContext.bundledUpdate` is populated ONLY by
/// `openOrCreateWorkFolder`. `assembleContext` — the path every
/// `mutateWorkFolder` takes — rebuilds the context without it, so the snapshot's
/// copy is destroyed by the first unrelated edit (renaming a team, toggling a
/// setting, anything).
///
/// Without the orchestrator-side latch, the durable "Prompt Updates Blocked" row
/// in Work Folder settings would vanish the moment the user touched anything —
/// for a condition that is permanent until they repair a file. This suite exists
/// so that stays impossible rather than remembered.
@MainActor
final class BundledUpdateReportLatchTests: XCTestCase {

    var sut: NTMSOrchestrator!
    var tempDir: URL!
    var root: URL!
    private let fm = FileManager.default
    private var paths: NTMSPaths { NTMSPaths(workFolderRoot: root) }

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        root = tempDir.appendingPathComponent("proj", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        sut = TestOrchestrator.make()
    }

    override func tearDown() async throws {
        if let tempDir { try? fm.removeItem(at: tempDir) }
        sut = nil
        tempDir = nil
        root = nil
        try await super.tearDown()
    }

    /// Seeds an unreadable `task.json` (a directory at that path throws a
    /// CocoaError, not a DecodingError) so the scan fails closed, and rewinds the
    /// watermark so a reconcile actually runs.
    private func seedUnreadableTaskAndRewind() throws {
        let store = AtomicJSONStore()
        try fm.createDirectory(
            at: paths.taskJSON(taskID: 0), withIntermediateDirectories: true
        )
        try store.write(
            TasksIndex(
                schemaVersion: 1,
                tasks: [TaskSummary(id: 0, title: "Unreadable", status: .running)],
                nextTaskID: 1
            ),
            to: paths.tasksIndexJSON
        )
        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        state.lastAppliedAppVersion = ""
        state.activeTaskID = nil
        try store.write(state, to: paths.workFolderJSON)
    }

    func testScanFailure_survivesAnUnrelatedMutateWorkFolder() async throws {
        await sut.openWorkFolder(root)
        try seedUnreadableTaskAndRewind()
        await sut.openWorkFolder(root)

        XCTAssertNotNil(sut.snapshot?.bundledUpdate, "the open populates the snapshot")
        XCTAssertNotNil(sut.bundledUpdateReport?.durableMessage)

        // Any unrelated edit routes through `assembleContext`.
        await sut.mutateWorkFolder { projection in
            projection.settings.context = "touched"
        }

        XCTAssertNil(
            sut.snapshot?.bundledUpdate,
            "documents the loss: assembleContext rebuilds the context without this field"
        )
        XCTAssertNotNil(
            sut.bundledUpdateReport?.durableMessage,
            "the latch must survive — the block is permanent until the user repairs the file"
        )
    }

    func testReport_isClearedWhenSwitchingFolders() async throws {
        await sut.openWorkFolder(root)
        try seedUnreadableTaskAndRewind()
        await sut.openWorkFolder(root)
        XCTAssertNotNil(sut.bundledUpdateReport?.scanFailure)

        let other = tempDir.appendingPathComponent("other", isDirectory: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        await sut.openWorkFolder(other)

        XCTAssertNil(
            sut.bundledUpdateReport?.scanFailure,
            "a healthy folder must not inherit the previous folder's blocked state"
        )
    }

    /// A healthy folder produces no report at all, so no banner and no row.
    func testHealthyOpen_producesNoReport() async throws {
        await sut.openWorkFolder(root)
        XCTAssertNil(sut.bundledUpdateReport?.bannerMessage)
        XCTAssertNil(sut.bundledUpdateReport?.durableMessage)
    }

    /// The severity split: a blocked folder is an error, not a neutral notice.
    func testScanFailure_routesToTheErrorBanner() async throws {
        await sut.openWorkFolder(root)
        try seedUnreadableTaskAndRewind()
        sut.lastErrorMessage = nil
        sut.lastInfoMessage = nil

        await sut.openWorkFolder(root)

        XCTAssertNotNil(sut.lastErrorMessage, "a blocked folder needs error styling")
        XCTAssertTrue(sut.lastErrorMessage?.contains("#0") ?? false, sut.lastErrorMessage ?? "nil")
    }
}
