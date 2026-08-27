import Foundation

#if DEBUG
/// Wall-clock attribution for ONE task submit — from the Send click to the moment
/// the chat is told to open, and past it for the warm-up that used to sit in front
/// of that moment.
///
/// Exists because "the chat opens slowly" is a claim about DURATION, and this tree
/// had no way to measure one: every existing probe (`TimelineRebuildProbe`,
/// `StreamQueryProbe`, `TasksIndexWorkProbe`, …) counts WORK, which is the right
/// default for a regression pin but cannot answer "which of six awaited steps was
/// the 1–3 seconds". `Ratchet/WallClockPerformancePinTests` bans `measure {` in the
/// test targets for that reason; it scans `NanoTeamsTests/` and `Ratchet/` only, and
/// this is deliberately an APP-side diagnostic, not a pin — nothing asserts on it.
///
/// `ContinuousClock`, never `MonotonicClock`: the latter is an ORDERING source
/// (`max(Date(), last + 1ms)` under a process-wide lock), so neighbouring reads
/// fabricate the delta — the same reason `ToolRuntime` measures `durationMS` this way.
///
/// Off unless `NANOTEAMS_SUBMIT_TIMING=1`, and DEBUG-only, so the shipping build
/// carries neither the timing nor the file write. Appends one line per submit to
/// `/tmp/nt_submit_timing.log`:
///
///     submit total=1840ms | createTask=61 attachments=8 run=44 NAVIGATE@113 | scans=1698 engine=29
///
/// `NAVIGATE@N` is the number the user actually feels: milliseconds from the click
/// to the chat being told to open. Everything after the `|` happens behind the
/// already-visible chat.
nonisolated enum SubmitLatencyProbe {

    /// Read once: `ProcessInfo.environment` is a dictionary build on every access.
    ///
    /// A `var`, not a `let`, so tests can drive the probe: the whole type is `#if DEBUG`, so
    /// there is no shipping surface to protect, and the alternative — an env-derived `let`
    /// plus a test-override optional plus a computed reader — is three members of ceremony
    /// around a diagnostic.
    nonisolated(unsafe) static var isEnabled =
        ProcessInfo.processInfo.environment["NANOTEAMS_SUBMIT_TIMING"] == "1"

    /// Where the line lands. A `var` for the same reason: a test must not append to the
    /// developer's own log, and reading the file back is the only way to assert what the
    /// formatter actually wrote.
    nonisolated(unsafe) static var logURL = URL(fileURLWithPath: "/tmp/nt_submit_timing.log")

    private struct Session {
        let start: ContinuousClock.Instant
        var last: ContinuousClock.Instant
        var segments: [String] = []
        var navigateAt: Int?
        /// How many segments had been recorded when navigation happened — the split
        /// between "the user is waiting for this" and "this runs behind the open chat".
        var navigateIndex: Int?
        /// The engine has been started and the line is NOT finished: the measurement
        /// runs on to the first `beginStreaming`, which is where the user stops seeing
        /// silence. Set by `markAwaitingStream`, cleared by `markStream`.
        var awaitingStream = false
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var session: Session?

    /// Starts a submit measurement. A second `begin` before `end` replaces the
    /// first: two overlapping submits are not a case worth reconstructing, and
    /// silently interleaving their marks would be worse than dropping one.
    static func begin() {
        guard isEnabled else { return }
        let now = ContinuousClock.now
        lock.withLock { session = Session(start: now, last: now) }
    }

    /// Records the elapsed time since the previous mark under `name`.
    static func mark(_ name: String) {
        guard isEnabled else { return }
        let now = ContinuousClock.now
        lock.withLock {
            guard var current = session else { return }
            current.segments.append("\(name)=\(Self.ms(from: current.last, to: now))")
            current.last = now
            session = current
        }
    }

    /// Stamps the moment the chat was told to open, as an offset from the click.
    /// Separate from `mark` because it is an ABSOLUTE position in the submit, not
    /// a segment — it is the one number the user experiences — and because it also
    /// splits the segment list into before/after the open.
    static func markNavigation() {
        guard isEnabled else { return }
        let now = ContinuousClock.now
        lock.withLock {
            guard var current = session else { return }
            current.navigateAt = Self.ms(from: current.start, to: now)
            current.navigateIndex = current.segments.count
            current.last = now
            session = current
        }
    }

    /// Records the elapsed time under `name` and holds the line open for the first
    /// stream frame.
    ///
    /// The launch's own `defer` fires the moment `engine.start()` returns — which is
    /// before the run loop has picked a role, let alone sent a request — so a line ended
    /// there stops exactly where the remaining silence begins. That silence (prompt
    /// assembly, up to `beginStreaming`) is the one stretch this wave did NOT cover with
    /// an indicator, on the grounds that it is short; grounds are not a measurement
    /// (CLAUDE.md #84), and this is how it gets one.
    ///
    /// A submit that starts an engine which never streams writes NO line. That is the
    /// honest outcome rather than a gap to paper over: the missing line says the run
    /// never reached a prompt, which is a finding.
    static func markAwaitingStream(_ name: String) {
        guard isEnabled else { return }
        mark(name)
        lock.withLock { session?.awaitingStream = true }
    }

    /// The submit's first `beginStreaming`: records the gap since the engine started and
    /// closes the line. Every later stream frame in the same submit is a no-op — the
    /// question is when the silence ENDED, and it ends once.
    static func markStream() {
        guard isEnabled else { return }
        let shouldClose = lock.withLock {
            guard var current = session, current.awaitingStream else { return false }
            current.awaitingStream = false
            session = current
            return true
        }
        guard shouldClose else { return }
        mark("stream")
        end()
    }

    /// Closes the measurement and appends one line. Safe to call when no session
    /// is open (a submit that bailed before `begin`), and a NO-OP while the line is
    /// held open for the first stream frame — see `markAwaitingStream`.
    static func end() {
        guard isEnabled else { return }
        let now = ContinuousClock.now
        let finished: Session? = lock.withLock {
            guard session?.awaitingStream != true else { return nil }
            let current = session
            session = nil
            return current
        }
        guard let finished else { return }

        var line = "submit total=\(ms(from: finished.start, to: now))ms"
        if let navigateAt = finished.navigateAt {
            let split = finished.navigateIndex ?? finished.segments.count
            let before = finished.segments.prefix(split)
            let after = finished.segments.dropFirst(split)
            line += " | \(before.joined(separator: " ")) NAVIGATE@\(navigateAt)"
            if !after.isEmpty { line += " | \(after.joined(separator: " "))" }
        } else if !finished.segments.isEmpty {
            line += " | \(finished.segments.joined(separator: " "))"
        }
        append(line)
    }

    private static func ms(from: ContinuousClock.Instant, to: ContinuousClock.Instant) -> Int {
        let duration = to - from
        let (seconds, attoseconds) = duration.components
        return Int(seconds * 1000 + attoseconds / 1_000_000_000_000_000)
    }

    private static func append(_ line: String) {
        let url = logURL
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
#endif
