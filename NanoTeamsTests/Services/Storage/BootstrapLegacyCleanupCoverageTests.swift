import XCTest

@testable import NanoTeams

/// Wave 11 — `bootstrapIfNeeded`'s legacy-`project.json` cleanup, in both directions.
///
/// Deleting the old monolithic file is HOUSEKEEPING, not a migration: nothing reads it, so a
/// failure must not stop a work folder from opening. That claim lived only in a comment. The happy
/// path is pinned elsewhere (`InternalLayoutCreationTests.testOpenOrCreateProject_removesLegacyProjectJSON`),
/// but nothing had ever made the removal FAIL, so "non-fatal" was an assertion about code no test
/// had run — and the failure it guards against is the one that matters, because an orphan the app
/// cannot delete would otherwise make the folder permanently unopenable.
///
/// The failure is INJECTED rather than produced with permissions. `removeItem(at:)` is overridable
/// (unlike `replaceItemAt`, which is declared in an extension — CLAUDE.md 2026-08-08 records that
/// trap), and a read-only `internal/` would also break the layout writes below, so the test could
/// not tell "removal refused" from "bootstrap died".
final class BootstrapLegacyCleanupCoverageTests: XCTestCase, @unchecked Sendable {

    /// Refuses to delete the legacy orphan and nothing else, so the rest of bootstrap — the orphan
    /// temp-file sweep, the directory probes, the split-file writes — runs against the real
    /// filesystem and can still be asserted on.
    private final class ProjectJSONRemovalRefusingFileManager: FileManager, @unchecked Sendable {
        nonisolated(unsafe) var refusals: [String] = []

        override func removeItem(at url: URL) throws {
            guard url.lastPathComponent == "project.json" else {
                try super.removeItem(at: url)
                return
            }
            refusals.append(url.path)
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private var tempDir: URL!
    private let realFM = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        MonotonicClock.shared.reset()
        tempDir = realFM.temporaryDirectory
            .appendingPathComponent("bootstrap-legacy-\(UUID().uuidString)", isDirectory: true)
        try realFM.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? realFM.removeItem(at: tempDir) }
        tempDir = nil
        try super.tearDownWithError()
    }

    /// RED: replace the `catch { print(...) }` around `try fileManager.removeItem(at: legacyProjectJSON)`
    /// with `catch { throw error }` (equivalently: drop the do/catch) → `XCTAssertNoThrow` fails and
    /// every split-file assertion fails with it, which is the real damage.
    func testBootstrap_legacyProjectJSONRemovalRefused_isNonFatalAndStillWritesTheLayout() throws {
        let fileManager = ProjectJSONRemovalRefusingFileManager()
        let repository = NTMSRepository(fileManager: fileManager)
        let paths = NTMSPaths(workFolderRoot: tempDir)
        try realFM.createDirectory(at: paths.internalDir, withIntermediateDirectories: true)

        let legacy = paths.internalDir.appendingPathComponent("project.json", isDirectory: false)
        try Data("{}".utf8).write(to: legacy)
        XCTAssertTrue(realFM.fileExists(atPath: legacy.path), "precondition: the orphan exists")

        XCTAssertNoThrow(
            try repository.bootstrapIfNeeded(paths: paths, workFolderRoot: tempDir),
            "a failed cleanup of a file nothing reads must not abort opening the work folder")

        XCTAssertEqual(fileManager.refusals.count, 1,
                       "the removal must actually have been attempted — otherwise this test passes "
                       + "for the wrong reason; refusals: \(fileManager.refusals)")
        XCTAssertTrue(realFM.fileExists(atPath: legacy.path),
                      "the orphan survives; the point is that bootstrap does not die with it")

        for file in [paths.workFolderJSON, paths.settingsJSON, paths.teamsJSON,
                     paths.toolsJSON, paths.tasksIndexJSON] {
            XCTAssertTrue(realFM.fileExists(atPath: file.path),
                          "every split file must still be written: \(file.lastPathComponent)")
        }
    }

    /// The companion direction, so the pair states the whole contract rather than half of it: when
    /// removal WORKS, the orphan is gone. Without this, a mutation that skipped the removal
    /// entirely would leave the failure test above green — it asserts the orphan survives.
    ///
    /// RED: delete the `try fileManager.removeItem(at: legacyProjectJSON)` call → the orphan
    /// survives and this test fails while the one above still passes.
    func testBootstrap_legacyProjectJSONRemovalSucceeds_deletesTheOrphan() throws {
        let repository = NTMSRepository()
        let paths = NTMSPaths(workFolderRoot: tempDir)
        try realFM.createDirectory(at: paths.internalDir, withIntermediateDirectories: true)

        let legacy = paths.internalDir.appendingPathComponent("project.json", isDirectory: false)
        try Data("{}".utf8).write(to: legacy)

        try repository.bootstrapIfNeeded(paths: paths, workFolderRoot: tempDir)

        XCTAssertFalse(realFM.fileExists(atPath: legacy.path),
                       "the legacy monolith must be cleaned up when removal is permitted")
    }
}
