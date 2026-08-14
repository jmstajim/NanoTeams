import XCTest

@testable import NanoTeams

/// Coverage wave 1 — `NTMSRepository.loadOrRecoverFile`, the recovery ladder that stands between
/// a corrupt `teams.json` and a work folder that will not open.
///
/// All three rungs were uncovered. That is worth more than its 15 lines: this function decides
/// whether a damaged file is *preserved* for forensics or *destroyed*, and the difference is one
/// `moveItem` that nothing had ever made fail. The last rung — back-up refused, so overwrite in
/// place — is the only one that loses user data, and it was reachable by no test.
///
/// The refusal is injected rather than simulated with permissions: `moveItem` IS overridable
/// (unlike `replaceItemAt`, which is declared in an extension — CLAUDE.md records that trap), and
/// a read-only parent directory would break the subsequent `store.write` too, so the test could
/// not tell the fallback from a hard failure.
final class LoadOrRecoverFileCoverageTests: XCTestCase, @unchecked Sendable {

    private struct Model: Codable, Equatable { var value: Int }

    /// Refuses to move anything, so the back-up rung fails and the overwrite rung runs.
    private final class MoveRefusingFileManager: FileManager, @unchecked Sendable {
        nonisolated(unsafe) var moveAttempts: [String] = []
        override func moveItem(at srcURL: URL, to dstURL: URL) throws {
            moveAttempts.append(srcURL.lastPathComponent)
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try super.tearDownWithError()
    }

    private func url(_ name: String) -> URL { tempDir.appendingPathComponent(name) }

    private func backups() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
            .filter { $0.contains(".corrupt-") && $0.hasSuffix(".bak") }
    }

    // MARK: - Rung 1: the file is missing

    /// The expected first-run case, and deliberately silent. The default must be WRITTEN, not
    /// just returned, or every subsequent open re-derives it and a later partial write can
    /// produce a file that never had a complete shape.
    ///
    /// RED: return `defaultValue()` without the `store.write` → the file-exists assertion fails.
    func testMissingFile_writesTheDefaultAndReturnsIt() throws {
        let repository = NTMSRepository()
        let target = url("settings.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))

        let loaded: Model = try repository.loadOrRecoverFile(at: target, default: Model(value: 42))

        XCTAssertEqual(loaded, Model(value: 42))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path),
                      "the default must be persisted, not merely returned — otherwise the file "
                      + "stays absent and each open re-derives it")
        let reread: Model = try repository.loadOrRecoverFile(at: target, default: Model(value: -1))
        XCTAssertEqual(reread, Model(value: 42), "the second open must read what the first wrote")
        XCTAssertTrue(try backups().isEmpty, "a missing file is not a corrupt one — no .bak")
    }

    // MARK: - Rung 2: the file is corrupt and can be preserved

    /// RED: delete the `try fileManager.moveItem(at: url, to: backupURL)` call → the backup
    /// assertion fails, and a user's damaged teams.json is destroyed instead of preserved.
    func testCorruptFile_isPreservedAsABackupAndResetToDefaults() throws {
        let repository = NTMSRepository()
        let target = url("teams.json")
        try Data("{ this is not json".utf8).write(to: target)

        let loaded: Model = try repository.loadOrRecoverFile(at: target, default: Model(value: 7))

        XCTAssertEqual(loaded, Model(value: 7), "recovery resets to defaults")
        let found = try backups()
        XCTAssertEqual(found.count, 1, "the damaged file must survive for forensics: \(found)")
        XCTAssertTrue(found[0].hasPrefix("teams.json.corrupt-"),
                      "the backup must name the file it came from: \(found[0])")

        let preserved = try Data(contentsOf: tempDir.appendingPathComponent(found[0]))
        XCTAssertEqual(String(decoding: preserved, as: UTF8.self), "{ this is not json",
                       "the backup must be the ORIGINAL bytes — a re-encoded or truncated copy is "
                       + "useless for recovering what the user lost")

        let reread: Model = try repository.loadOrRecoverFile(at: target, default: Model(value: -1))
        XCTAssertEqual(reread, Model(value: 7), "the reset defaults are now the file's content")
    }

    /// The `:` → `-` substitution in the timestamp is not cosmetic: a colon in a filename is
    /// legal on APFS but breaks on any FAT/exFAT volume a user might copy a work folder to, and
    /// it is the character an ISO-8601 stamp is full of.
    ///
    /// RED: drop the `replacingOccurrences(of: ":", with: "-")` → this fails.
    func testCorruptBackupNameCarriesNoColons() throws {
        let repository = NTMSRepository()
        let target = url("workfolder.json")
        try Data("nope".utf8).write(to: target)
        _ = try repository.loadOrRecoverFile(at: target, default: Model(value: 1)) as Model

        let found = try backups()
        XCTAssertEqual(found.count, 1)
        XCTAssertFalse(found[0].contains(":"),
                       "a colon is legal on APFS and breaks on exFAT — a work folder copied to a "
                       + "USB stick must keep its forensic backup: \(found[0])")
    }

    // MARK: - Rung 3: the file is corrupt AND cannot be preserved

    /// The only rung that destroys data, and the one nothing could reach.
    ///
    /// The contract it implements is a real trade: an un-backupable corrupt file must not block
    /// the work folder from opening, so it is overwritten. What must hold is that the attempt was
    /// made first, and that the caller still gets a usable value rather than a throw.
    ///
    /// RED: change the inner `try? fileManager.removeItem(at: url)` to a `throw`, or drop the
    /// `store.write` after it → this fails.
    func testCorruptFile_whenBackupIsRefused_overwritesInPlaceAndStillReturnsDefaults() throws {
        let refusing = MoveRefusingFileManager()
        let repository = NTMSRepository(fileManager: refusing)
        let target = url("teams.json")
        try Data("{ corrupt".utf8).write(to: target)

        let loaded: Model = try repository.loadOrRecoverFile(at: target, default: Model(value: 99))

        XCTAssertEqual(refusing.moveAttempts, ["teams.json"],
                       "the back-up must be ATTEMPTED before the file is overwritten — losing the "
                       + "original without trying is the failure this rung exists to bound")
        XCTAssertEqual(loaded, Model(value: 99),
                       "an un-backupable corrupt file must not stop the work folder from opening")
        XCTAssertTrue(try backups().isEmpty, "the move was refused, so no backup exists")

        let reread: Model = try repository.loadOrRecoverFile(at: target, default: Model(value: -1))
        XCTAssertEqual(reread, Model(value: 99),
                       "the defaults must have replaced the corrupt bytes on disk, or the next "
                       + "open repeats the whole recovery")
    }

    // MARK: - The composite: cross-file invariants after recovery

    /// An empty `teams` array is a broken invariant, not a valid state: a zero-team work folder
    /// makes every role an orphan and the app has nothing to run. It is reachable two ways — a
    /// corrupt-then-defaulted file whose defaults were themselves empty, or a migration bug — and
    /// both had no test.
    ///
    /// RED: delete the `if teamsFile.teams.isEmpty { … }` block → the re-bootstrap assertion
    /// fails, and the folder opens with no teams at all.
    func testEmptyTeamsArray_isReBootstrappedToDefaultsAndPersisted() throws {
        let repository = NTMSRepository()
        let root = tempDir!
        let paths = try repository.preparePaths(at: root)

        // A structurally valid teams.json that carries the broken invariant.
        try JSONCoderFactory.makePersistenceEncoder()
            .encode(TeamsFile(schemaVersion: 1, teams: []))
            .write(to: paths.teamsJSON)

        let (state, _, teamsFile) = try repository.loadOrRecoverFiles(paths: paths, workFolderRoot: root)

        XCTAssertFalse(teamsFile.teams.isEmpty,
                       "an empty teams array must be re-bootstrapped — a zero-team work folder "
                       + "makes every role an orphan and the app has nothing to execute")
        XCTAssertEqual(teamsFile.teams.count, Team.defaultTeams.count)

        // Persisted, not just returned: otherwise every open repeats the repair.
        let onDisk = try JSONCoderFactory.makeDateDecoder()
            .decode(TeamsFile.self, from: try Data(contentsOf: paths.teamsJSON))
        XCTAssertFalse(onDisk.teams.isEmpty, "the repair must reach disk")

        // …and the cross-file invariant: activeTeamID has to resolve to a real team.
        XCTAssertNotNil(state.activeTeamID,
                        "a folder with teams must have a resolvable active team, or the UI shows "
                        + "teams.first while stored state disagrees")
        XCTAssertTrue(teamsFile.teams.contains { $0.id == state.activeTeamID },
                      "activeTeamID must name a team that exists")
    }

    /// The dangling-ID repair: `teams.json` was recovered while `workfolder.json` still pointed at
    /// a pre-corruption team.
    ///
    /// RED: drop the `if !resolvable` repair → the assertion that the id resolves fails, and the
    /// folder opens pointing at a team that is not there.
    func testDanglingActiveTeamID_isRepairedToTheFirstTeam() throws {
        let repository = NTMSRepository()
        let root = tempDir!
        let paths = try repository.preparePaths(at: root)

        var state = WorkFolderState(id: UUID(), name: "probe")
        state.activeTeamID = NTMSID.from(name: "a team that was lost to corruption")
        try JSONCoderFactory.makePersistenceEncoder().encode(state).write(to: paths.workFolderJSON)

        let (repaired, _, teamsFile) = try repository.loadOrRecoverFiles(paths: paths, workFolderRoot: root)

        XCTAssertNotEqual(repaired.activeTeamID, state.activeTeamID,
                          "a dangling active team must be replaced, not preserved")
        XCTAssertEqual(repaired.activeTeamID, teamsFile.teams.first?.id)

        let onDisk = try JSONCoderFactory.makeDateDecoder()
            .decode(WorkFolderState.self, from: try Data(contentsOf: paths.workFolderJSON))
        XCTAssertEqual(onDisk.activeTeamID, teamsFile.teams.first?.id,
                       "the repair must be persisted or it re-runs on every open")
    }

    // MARK: - Anti-vacuity

    /// Guards the shape all four tests above depend on: that a valid file is read straight
    /// through, touching no recovery rung. Without it, a `loadOrRecoverFile` that always reset to
    /// defaults would satisfy every assertion here.
    func testValidFile_isReadUntouched() throws {
        let repository = NTMSRepository()
        let target = url("settings.json")
        try JSONCoderFactory.makePersistenceEncoder().encode(Model(value: 5)).write(to: target)

        let loaded: Model = try repository.loadOrRecoverFile(at: target, default: Model(value: 999))

        XCTAssertEqual(loaded, Model(value: 5),
                       "a readable file must win over the default, or recovery is unconditional")
        XCTAssertTrue(try backups().isEmpty, "nothing was corrupt, so nothing is backed up")
    }
}
