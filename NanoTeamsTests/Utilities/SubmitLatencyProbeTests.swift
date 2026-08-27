import XCTest

@testable import NanoTeams

/// The submit probe is the only thing in this tree that can answer "how long from the Send
/// click to the chat opening" — a question about DURATION, which every other probe here
/// (they count WORK) is structurally unable to answer. So its output has to be right, and
/// "right" means the formatter, not the clock: these tests assert the SHAPE of the line and
/// the position of `NAVIGATE@`, never a millisecond value.
///
/// `isEnabled` and `logURL` are `#if DEBUG` vars for exactly this: without redirecting the
/// log a test would append to the developer's own `/tmp/nt_submit_timing.log`, and without
/// forcing `isEnabled` every method is a `guard … else { return }` no-op in a test process
/// (the environment variable is unset), so the file would be measured as uncovered while
/// looking tested.
final class SubmitLatencyProbeTests: XCTestCase {

    private var logURL: URL!
    private var savedEnabled: Bool!
    private var savedURL: URL!

    override func setUp() {
        super.setUp()
        savedEnabled = SubmitLatencyProbe.isEnabled
        savedURL = SubmitLatencyProbe.logURL
        logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("submit-timing-\(UUID().uuidString).log", isDirectory: false)
        SubmitLatencyProbe.logURL = logURL
        SubmitLatencyProbe.isEnabled = true
        // Any session a previous test left open would be closed by this test's `end()` and
        // its segments would appear in this test's line. `markStream()` first, because
        // `end()` is deliberately a no-op on a session held open for its stream frame —
        // so without it exactly the leftovers this line exists to drop would survive.
        SubmitLatencyProbe.markStream()
        SubmitLatencyProbe.end()
        try? FileManager.default.removeItem(at: logURL)
    }

    override func tearDown() {
        SubmitLatencyProbe.isEnabled = savedEnabled
        SubmitLatencyProbe.logURL = savedURL
        if let logURL { try? FileManager.default.removeItem(at: logURL) }
        logURL = nil
        super.tearDown()
    }

    private func lines() -> [String] {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    // MARK: - The line

    /// The shape the whole probe exists to produce: segments before the open, `NAVIGATE@N`
    /// as an ABSOLUTE offset from the click, and the warm-up after a second `|` so it reads
    /// as "this happened behind the already-visible chat".
    ///
    /// RED: drop `current.navigateIndex = current.segments.count` from `markNavigation` →
    /// the split falls back to `segments.count` AT END, so every segment lands before the
    /// marker and `scans`/`engine` appear on the user's side of it.
    func testLine_splitsSegmentsAtTheNavigationMarker() {
        SubmitLatencyProbe.begin()
        SubmitLatencyProbe.mark("createTask")
        SubmitLatencyProbe.mark("attachments")
        SubmitLatencyProbe.mark("run")
        SubmitLatencyProbe.markNavigation()
        SubmitLatencyProbe.mark("scans")
        SubmitLatencyProbe.mark("engine")
        SubmitLatencyProbe.end()

        let text = lines().first ?? ""
        XCTAssertTrue(text.hasPrefix("submit total="), "got: \(text)")

        let halves = text.components(separatedBy: " | ")
        XCTAssertEqual(halves.count, 3, "total | before-open + NAVIGATE | after-open; got: \(text)")

        XCTAssertTrue(halves[1].contains("createTask="), "got: \(text)")
        XCTAssertTrue(halves[1].contains("attachments="), "got: \(text)")
        XCTAssertTrue(halves[1].contains("run="), "got: \(text)")
        // `NAVIGATE@` carries an ABSOLUTE offset from the click, so it is a bare number and
        // it terminates the user-facing half — anything after it belongs behind the open chat.
        let aroundMarker = halves[1].components(separatedBy: "NAVIGATE@")
        XCTAssertEqual(aroundMarker.count, 2, "exactly one navigation marker; got: \(text)")
        XCTAssertFalse(aroundMarker[1].isEmpty, "the marker must carry its offset; got: \(text)")
        XCTAssertTrue(
            aroundMarker[1].allSatisfy(\.isNumber),
            "the offset is a bare millisecond count, not a segment; got: \(text)")

        XCTAssertTrue(halves[2].contains("scans="), "the warm-up belongs after the open; got: \(text)")
        XCTAssertTrue(halves[2].contains("engine="), "got: \(text)")
        XCTAssertFalse(halves[1].contains("scans="), "got: \(text)")
    }

    /// A submit that never reached the navigation post — the create failed, so the chat was
    /// never told to open. The segments must still be written, or the failing case is the
    /// one with no diagnostics.
    ///
    /// RED: change the `else if !finished.segments.isEmpty` arm in `end()` to write nothing →
    /// the line loses its segments and only `total=` survives.
    func testNoNavigation_stillWritesTheSegments() {
        SubmitLatencyProbe.begin()
        SubmitLatencyProbe.mark("createTask")
        SubmitLatencyProbe.end()

        let text = lines().first ?? ""
        XCTAssertTrue(text.contains("createTask="), "got: \(text)")
        XCTAssertFalse(text.contains("NAVIGATE@"), "got: \(text)")
    }

    /// RED: change `append` to `data.write(to:)` unconditionally → the second submit
    /// truncates the first and only one line is left.
    func testTwoSubmits_appendRatherThanTruncate() {
        for name in ["first", "second"] {
            SubmitLatencyProbe.begin()
            SubmitLatencyProbe.mark(name)
            SubmitLatencyProbe.end()
        }

        let all = lines()
        XCTAssertEqual(all.count, 2, "got: \(all)")
        XCTAssertTrue(all[0].contains("first="), "got: \(all)")
        XCTAssertTrue(all[1].contains("second="), "got: \(all)")
    }

    // MARK: - Corner cases

    /// The shipping default. Every entry point is guarded, so an unset environment variable
    /// must cost nothing at all — including the file.
    ///
    /// RED: delete the `guard isEnabled else { return }` from `end()` → the disabled run
    /// still writes a line, and the developer's log fills up on a build that never opted in.
    func testDisabled_writesNothing() {
        SubmitLatencyProbe.isEnabled = false

        SubmitLatencyProbe.begin()
        SubmitLatencyProbe.mark("createTask")
        SubmitLatencyProbe.markNavigation()
        SubmitLatencyProbe.end()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: logURL.path),
            "a probe nobody switched on must not create its log")
    }

    /// A submit that bailed before `begin` — `QuickCaptureController.createTask` returns on
    /// its no-store guard before the probe is ever started, and the next submit's `end` must
    /// not fabricate a line out of an empty session.
    ///
    /// RED: replace `guard let finished else { return }` in `end()` with a default Session →
    /// a line is written for a submit that never happened.
    func testEndWithoutBegin_writesNothing() {
        SubmitLatencyProbe.end()

        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path))
    }

    /// RED: change `mark`'s `guard var current = session else { return }` to create a session →
    /// a stray mark starts a measurement whose `start` is that mark, and the next `begin`
    /// is no longer the click.
    func testMarkBeforeBegin_isDropped() {
        SubmitLatencyProbe.mark("stray")
        SubmitLatencyProbe.begin()
        SubmitLatencyProbe.mark("real")
        SubmitLatencyProbe.end()

        let text = lines().first ?? ""
        XCTAssertTrue(text.contains("real="), "got: \(text)")
        XCTAssertFalse(text.contains("stray="), "got: \(text)")
    }

    /// Two overlapping submits are not a case worth reconstructing, so the second `begin`
    /// replaces the first rather than interleaving marks from both into one line.
    ///
    /// RED: make `begin` no-op when a session is already open → the abandoned submit's
    /// segments ride along in the next submit's line.
    func testSecondBegin_replacesTheAbandonedSession() {
        SubmitLatencyProbe.begin()
        SubmitLatencyProbe.mark("abandoned")
        SubmitLatencyProbe.begin()
        SubmitLatencyProbe.mark("kept")
        SubmitLatencyProbe.end()

        let all = lines()
        XCTAssertEqual(all.count, 1, "the abandoned submit must not produce its own line; got: \(all)")
        XCTAssertTrue(all[0].contains("kept="), "got: \(all)")
        XCTAssertFalse(all[0].contains("abandoned="), "got: \(all)")
    }

    /// RED: leave `session` set in `end()` → the second `end` writes the first submit's
    /// segments a second time.
    func testEndIsIdempotent() {
        SubmitLatencyProbe.begin()
        SubmitLatencyProbe.mark("createTask")
        SubmitLatencyProbe.end()
        SubmitLatencyProbe.end()

        XCTAssertEqual(lines().count, 1, "got: \(lines())")
    }

    /// `markNavigation` without a session is the shape a submit takes when the panel was
    /// dismissed mid-flight. RED: drop its `guard var current = session` → a crash or a
    /// fabricated session, depending on the replacement.
    func testMarkNavigationWithoutBegin_writesNothing() {
        SubmitLatencyProbe.markNavigation()
        SubmitLatencyProbe.end()

        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path))
    }
    // MARK: - The window past `engine.start()`

    /// The line runs on to the FIRST stream frame, because that is where the user stops
    /// seeing silence. `engine.start()` only spawns the run loop, so a line closed there
    /// stops exactly where the remaining wait begins.
    ///
    /// RED: make `markAwaitingStream` a plain `mark` → the launch's own `end()` closes the
    /// line at `engine`, and `stream` never appears.
    func testMarkStream_closesTheLineAfterTheEngineSegment() {
        SubmitLatencyProbe.begin()
        SubmitLatencyProbe.mark("run")
        SubmitLatencyProbe.markNavigation()
        SubmitLatencyProbe.markAwaitingStream("engine")

        // What the launch's `defer` does the moment `engine.start()` returns.
        SubmitLatencyProbe.end()
        XCTAssertEqual(lines(), [],
                       "`end()` must not close a line that is still waiting for its stream "
                           + "frame — that is the whole point of holding it open")

        SubmitLatencyProbe.markStream()

        let line = lines().first ?? ""
        XCTAssertTrue(line.contains("engine="), "line was: \(line)")
        XCTAssertTrue(line.contains("stream="),
                      "the segment between engine.start() and the first `Processing…` is the "
                          + "one stretch this wave left without an indicator: \(line)")
        XCTAssertLessThan(line.range(of: "engine=")!.lowerBound,
                          line.range(of: "stream=")!.lowerBound,
                          "`stream` measures the gap AFTER `engine`, so it must follow it")
    }

    /// Once. Every later frame of the same submit is a no-op — the question is when the
    /// silence ended, and it ends once.
    ///
    /// RED: drop `current.awaitingStream = false` from `markStream` → the second call
    /// closes a second (empty) line and the count assertion fails.
    func testMarkStream_isANoOpAfterTheFirstFrame() {
        SubmitLatencyProbe.begin()
        SubmitLatencyProbe.markAwaitingStream("engine")
        SubmitLatencyProbe.markStream()
        SubmitLatencyProbe.markStream()
        SubmitLatencyProbe.markStream()

        XCTAssertEqual(lines().count, 1, "one submit, one line")
    }

    /// A submit whose launch never reached the engine — refused, aborted by Pause, or
    /// handed to team generation — still writes its line at the `defer`. The hold is
    /// claimed by `markAwaitingStream` alone, so a launch that never called it is closed
    /// normally.
    func testEnd_stillClosesALaunchThatNeverStartedAnEngine() {
        SubmitLatencyProbe.begin()
        SubmitLatencyProbe.mark("run")
        SubmitLatencyProbe.markNavigation()
        SubmitLatencyProbe.end()

        XCTAssertEqual(lines().count, 1,
                       "Nothing held this line open, so the `defer` must close it — an "
                           + "aborted start would otherwise vanish from the log entirely")
        XCTAssertFalse(lines()[0].contains("stream="))
    }

    /// A stream frame outside any submit — every ordinary mid-run turn — must cost nothing
    /// and write nothing.
    ///
    /// RED: drop the `guard var current = session` half of `markStream`'s check → it marks
    /// and ends against no session, and the "no line" assertion fails.
    func testMarkStream_withNoSubmitInFlight_writesNothing() {
        SubmitLatencyProbe.markStream()
        XCTAssertEqual(lines(), [],
                       "a turn in the middle of a run is not a submit measurement")
    }

    /// …and one during a submit that has not yet reached the engine is equally a no-op:
    /// the hold is what makes a frame the CLOSING one, not the frame itself.
    func testMarkStream_beforeTheEngineSegment_doesNotCloseTheLine() {
        SubmitLatencyProbe.begin()
        SubmitLatencyProbe.mark("run")

        SubmitLatencyProbe.markStream()
        XCTAssertEqual(lines(), [], "nothing has claimed the hold, so nothing may close it")

        SubmitLatencyProbe.end()
        XCTAssertEqual(lines().count, 1)
        XCTAssertFalse(lines()[0].contains("stream="),
                       "the early frame must not have recorded a segment either")
    }

    /// Disabled is disabled: neither new entry point may touch the session or the disk.
    func testDisabled_neitherNewEntryPointDoesAnything() {
        SubmitLatencyProbe.begin()
        SubmitLatencyProbe.isEnabled = false
        SubmitLatencyProbe.markAwaitingStream("engine")
        SubmitLatencyProbe.markStream()
        SubmitLatencyProbe.isEnabled = true

        SubmitLatencyProbe.end()
        let line = lines().first ?? ""
        XCTAssertFalse(line.contains("engine="),
                       "a disabled `markAwaitingStream` must not have recorded a segment")
        XCTAssertFalse(line.contains("stream="))
        XCTAssertEqual(lines().count, 1,
                       "Anti-vacuum: the session was still open, so `end()` proves the "
                           + "disabled calls left it usable rather than destroyed")
    }

}
