import XCTest

@testable import NanoTeams

/// Pins `openWorkFolder` across its off-main read (CLAUDE.md #38).
///
/// Since 2026-09-15 the folder is read off the main actor — the read held the main thread for
/// 165 ms at launch — so an open has a suspension between "folder B was asked for" and "B's
/// snapshot is applied". Two things must hold across it:
/// - the process never names one folder's URL beside another folder's snapshot: the URL is
///   committed with the outcome, after the read;
/// - two opens can overlap (the user picks A, then B before A's read returns), and only the
///   LATEST may apply its snapshot, report its error or run the rest of the open.
///
/// `SelectivelyFailingRepository.openDelays` makes a read finish after a later open's whole run,
/// which is the order a real slow disk produces; its `openStarts` says a read is under way.
@MainActor
final class WorkFolderOpenSupersessionTests: XCTestCase {

    private var repository: SelectivelyFailingRepository!
    private var sut: NTMSOrchestrator!
    private var folderA: URL!
    private var folderB: URL!

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
        await sut?.drainRunStartLaunches()
        sut?.stopAllEngines()
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
    private func startOpen(of folder: URL) async throws -> Task<Void, Never> {
        let earlierStarts = repository.openStarts.count
        let open = Task { await sut.openWorkFolder(folder) }
        for _ in 0..<400 {
            if repository.openStarts.dropFirst(earlierStarts).contains(folder.path) { return open }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("the open of \(folder.lastPathComponent) never reached its read")
        return open
    }

    /// Starts an open of `slow` that is still reading when an open of `fast` runs to completion.
    private func overlapSlowOpen(of slow: URL, byOpenOf fast: URL) async throws {
        repository.openDelays[slow.path] = 0.4
        let slowOpen = try await startOpen(of: slow)
        await sut.openWorkFolder(fast)
        await slowOpen.value
    }

    /// RED: assign `workFolderURL` before the read again → while B is read, the process names B
    /// beside A's snapshot, and a write through the URL in that window lands A's state in B.
    func testWhileAFolderIsRead_theProcessStillDescribesThePreviousFolder() async throws {
        await sut.openWorkFolder(folderA)
        let folderAID = sut.snapshot?.projection.id
        XCTAssertNotNil(folderAID, "anti-vacuum: A never opened, so nothing below compares folders")

        repository.openDelays[folderB.path] = 0.3
        let openB = try await startOpen(of: folderB)
        XCTAssertEqual(sut.workFolderURL, folderA, "the URL named B before B's snapshot existed")
        XCTAssertEqual(sut.snapshot?.projection.id, folderAID)
        await openB.value

        XCTAssertEqual(sut.workFolderURL, folderB)
        XCTAssertNotEqual(sut.snapshot?.projection.id, folderAID, "anti-vacuum: B's open never applied")
    }

    /// RED: delete the guard after the read → A's snapshot, carrying A's task, lands after B's
    /// open finished, and the process shows folder B's URL with folder A's tasks.
    func testAnOpenSupersededDuringItsRead_appliesNothing() async throws {
        await sut.openWorkFolder(folderA)
        let seeded = await sut.createTask(title: "only in A", supervisorTask: "x")
        XCTAssertNotNil(seeded, "anti-vacuum: A must hold a task, or both snapshots look alike")
        await sut.openWorkFolder(folderB)
        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.count, 0, "precondition: B is empty")

        try await overlapSlowOpen(of: folderA, byOpenOf: folderB)

        XCTAssertEqual(sut.workFolderURL, folderB)
        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.count, 0,
                       "the superseded open of A applied its snapshot over B's")
        XCTAssertNil(sut.lastErrorMessage)
    }

    /// RED: delete the guard in `catch` → A's refusal is reported against B, and
    /// `discardWorkFolderState()` wipes the snapshot B just opened.
    func testASupersededOpenThatFails_reportsNothing_andDiscardsNothing() async throws {
        repository.openFailurePaths = [folderA.path]

        try await overlapSlowOpen(of: folderA, byOpenOf: folderB)

        XCTAssertEqual(sut.workFolderURL, folderB)
        XCTAssertNotNil(sut.snapshot, "the superseded failure discarded the newer open's snapshot")
        XCTAssertNil(sut.lastErrorMessage, "a superseded open must not report its error")
    }

    /// The latest open still reports its OWN failure — the guard only silences older ones — and
    /// still commits its URL, which `closeProject` / `resetAllData` read.
    func testTheLatestOpenThatFails_stillReports_andCommitsItsURL() async throws {
        repository.openFailurePaths = [folderB.path]
        await sut.openWorkFolder(folderB)
        XCTAssertNotNil(sut.lastErrorMessage)
        XCTAssertNil(sut.snapshot)
        XCTAssertEqual(sut.workFolderURL, folderB)
    }
}
