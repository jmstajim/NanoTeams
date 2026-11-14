import XCTest
@testable import NanoTeams

/// `Run.snapshotFailures` on disk (N2, N3 of the F6 acceptance, 2026-11-12).
final class RunSnapshotFailureTests: XCTestCase {

    private func decode(_ json: String) throws -> Run {
        try JSONCoderFactory.makeDateDecoder().decode(Run.self, from: Data(json.utf8))
    }

    func testRoundTrip_keepsEveryField() throws {
        var run = Run(id: 0, createdAt: Date(timeIntervalSince1970: 1_799_971_200), round: 2)
        run.snapshotFailures = [
            RunSnapshotFailure(round: 1, phase: .start, reason: .completedLate,
                               recordedAt: Date(timeIntervalSince1970: 1_799_971_201)),
            RunSnapshotFailure(round: 2, phase: .review, reason: .failed, detail: "Snapshot add failed: x",
                               recordedAt: Date(timeIntervalSince1970: 1_799_971_202)),
        ]
        let data = try JSONCoderFactory.makePersistenceEncoder().encode(run)
        let back = try JSONCoderFactory.makeDateDecoder().decode(Run.self, from: data)
        XCTAssertEqual(back.snapshotFailures, run.snapshotFailures)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"completed_late\""), "reasons are snake_case on disk")
    }

    func testNoFailures_writeNoKey() throws {
        let data = try JSONCoderFactory.makePersistenceEncoder().encode(Run(id: 0, round: 1))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("snapshotFailures"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("snapshotUnavailableReason"))
    }

    /// The run-wide reason of the unreleased F1/F2 builds was written only by a run's start: it
    /// reads as round 1's start. A reason those builds never wrote reads as `failed`.
    func testLegacyRunWideReason_readsAsRoundOnesStart() throws {
        let timedOut = try decode(#"{"id":0,"createdAt":"2026-01-01T00:00:00Z","snapshotUnavailableReason":"timed_out"}"#)
        XCTAssertEqual(timedOut.snapshotFailures.map(\.round), [1])
        XCTAssertEqual(timedOut.snapshotFailures.map(\.phase), [.start])
        XCTAssertEqual(timedOut.snapshotFailures.map(\.reason), [.timedOut])
        XCTAssertEqual(timedOut.snapshotFailures.first?.recordedAt, timedOut.createdAt)

        let other = try decode(#"{"id":0,"createdAt":"2026-01-01T00:00:00Z","snapshotUnavailableReason":"untracked_files_too_large"}"#)
        XCTAssertEqual(other.snapshotFailures.map(\.reason), [.failed])
    }

    func testNewKeyWinsOverTheLegacyOne() throws {
        let run = try decode(#"""
        {"id":0,"createdAt":"2026-01-01T00:00:00Z","snapshotUnavailableReason":"timed_out",
         "snapshotFailures":[{"round":3,"phase":"close","reason":"failed","recordedAt":"2026-01-01T00:00:01Z"}]}
        """#)
        XCTAssertEqual(run.snapshotFailures.map(\.round), [3])
        XCTAssertEqual(run.snapshotFailures.map(\.phase), [.close])
    }

    func testEndPhases_areEveryPhaseButStart() {
        XCTAssertEqual(TaskSnapshotPhase.endPhases, [.review, .failure, .restart, .revision, .stop, .close])
        XCTAssertFalse(TaskSnapshotPhase.start.endsRound)
        XCTAssertTrue(TaskSnapshotPhase.endPhases.allSatisfy(\.endsRound))
    }
}
