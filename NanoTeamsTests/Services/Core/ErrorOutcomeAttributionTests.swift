import XCTest

@testable import NanoTeams

/// `lastErrorMessage` is a single-shot slot the error banner CONSUMES (writes nil) on
/// any render. It answers "what should the user see right now" and cannot answer "did
/// the operation I just awaited fail, and why" — the question ten call sites were asking
/// it, in three different spellings:
///
/// * `lastErrorMessage ?? "<generic>"` after an `await` — adopts whatever an UNRELATED
///   operation parked in the slot as this one's reason;
/// * `lastErrorMessage == before` across an `await` — a real failure reads back as the
///   value it started from once a render consumed it, AND a repeated identical error
///   never differs from the snapshot; both report success for a failed operation;
/// * `if lastErrorMessage == nil { lastErrorMessage = "<ours>" }` — a foreign message
///   suppresses a diagnostic that is the only signal a feature is dead.
///
/// The replacement is `NTMSOrchestrator.errorSurfaced(since:)`, keyed on the monotonic
/// `errorSurfaceCount` that nothing clears. This suite pins the two behaviours that are
/// deterministically observable without a render, plus a source scan so the class cannot
/// come back in a fourth spelling.
@MainActor
final class ErrorOutcomeAttributionTests: XCTestCase, @unchecked Sendable {

    private var tempDir: URL!
    private var repo: SelectivelyFailingRepository!
    private var sut: NTMSOrchestrator!

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("error-attribution-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        repo = SelectivelyFailingRepository(wrapping: NTMSRepository())
        sut = TestOrchestrator.make(repository: repo)
    }

    override func tearDown() async throws {
        sut = nil
        repo = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try await super.tearDown()
    }

    // MARK: - The counter itself

    /// The seam every fixed call site now goes through. `nil` means "this operation
    /// surfaced nothing", which is the only reading a caller may treat as success.
    func testErrorSurfaced_reportsOnlyWhatWasSurfacedSinceTheBaseline() {
        sut.lastErrorMessage = "an earlier, unrelated failure"
        let baseline = sut.errorSurfaceCount

        XCTAssertNil(
            sut.errorSurfaced(since: baseline),
            "a message parked BEFORE the baseline is not this operation's outcome")

        sut.lastErrorMessage = nil          // the banner rendering and consuming the slot
        XCTAssertNil(sut.errorSurfaced(since: baseline), "consuming the slot is not a failure")

        sut.lastErrorMessage = "the real one"
        XCTAssertEqual(sut.errorSurfaced(since: baseline), "the real one")
    }

    /// The repeated-identical case, which is the whole reason a counter replaced a
    /// value comparison: the manager retrying the same doomed operation produces the
    /// same string every time, and a snapshot comparison can never see it.
    ///
    /// RED: revert `errorSurfaced(since:)` to `lastErrorMessage != <snapshot value>`
    /// → the second assertion fails, because the two messages are equal.
    func testErrorSurfaced_seesARepeatOfTheSameMessage() {
        sut.lastErrorMessage = "Disk full."
        let baseline = sut.errorSurfaceCount
        sut.lastErrorMessage = "Disk full."

        XCTAssertNotEqual(sut.errorSurfaceCount, baseline)
        XCTAssertEqual(
            sut.errorSurfaced(since: baseline), "Disk full.",
            "a second identical failure is a second failure")
    }

    // MARK: - persistAutovisorMemory

    /// The manager's memory is its only cross-run state, so a `false` here is the one
    /// signal that it silently forgot. With the write refused AND the slot already
    /// holding the very message the refusal produces — the manager writing its memory
    /// on every pass against a disk that is still full — a value comparison saw no
    /// change and reported that the memory had landed.
    ///
    /// RED: restore `let before = lastErrorMessage` / `return lastErrorMessage == before`
    /// → this returns `true` for a write that was refused.
    func testPersistMemory_repeatedIdenticalFailure_isNotReportedAsSuccess() async {
        await sut.openWorkFolder(tempDir)
        repo.failUpdateSettings = true

        // First attempt: establishes both the refusal and the message it produces.
        let first = await sut.persistAutovisorMemory("pass 1")
        XCTAssertFalse(first, "precondition: a refused settings write reports failure")
        guard let refusalMessage = sut.lastSurfacedError else {
            return XCTFail("precondition: the refusal must surface a message")
        }

        // Re-park the identical message, exactly as an unrendered banner would leave it.
        sut.lastErrorMessage = refusalMessage

        let second = await sut.persistAutovisorMemory("pass 2")

        XCTAssertFalse(
            second,
            "the second refusal is still a refusal — the manager must not be told its "
                + "memory landed just because the failure repeated verbatim")
    }

    /// The other direction, already pinned elsewhere and re-pinned here so the fix above
    /// cannot be "return false whenever anything is in the slot": a banner from BEFORE
    /// the write is not this write's failure.
    func testPersistMemory_foreignBanner_isNotAttributedToTheWrite() async {
        await sut.openWorkFolder(tempDir)
        sut.lastErrorMessage = "an earlier, unrelated failure"

        let ok = await sut.persistAutovisorMemory("a memory that does persist")

        XCTAssertTrue(ok, "a pre-existing banner is not this write's outcome")
        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorMemory,
                       "a memory that does persist")
    }

    // MARK: - Descendant loading must not fabricate a failure

    /// `ensureDelegationDescendantsLoaded` restores a baseline banner after its loop so a
    /// per-iteration overwrite doesn't leak. Unconditionally, that assignment re-fires
    /// `lastErrorMessage`'s `didSet` on every CLEAN run — bumping the counter that now
    /// means "something failed" and re-showing a banner a render had already consumed.
    ///
    /// RED: drop the `errorSurfaceCount != baselineCount` guard around the restore
    /// → the counter moves on a run in which nothing failed.
    func testDescendantLoad_cleanRun_doesNotFabricateASurfacedError() async {
        await sut.openWorkFolder(tempDir)
        guard let parentID = await sut.createTask(title: "Parent", supervisorTask: "brief") else {
            return XCTFail("could not create the parent task")
        }
        sut.lastErrorMessage = "an earlier, unrelated failure"
        let baseline = sut.errorSurfaceCount

        await sut.ensureDelegationDescendantsLoaded(of: parentID)

        XCTAssertEqual(
            sut.errorSurfaceCount, baseline,
            "a load that failed at nothing must not register as a surfaced error")
    }

    // MARK: - The class cannot come back

    /// Source scan. Reading the banner slot to DECIDE an outcome is the defect; the two
    /// spellings that do it are a `??` fallback and an equality comparison. Writing to
    /// the slot, and reading it to render, both stay legal.
    ///
    /// Scoped to the orchestrator's slot: `DictationService.lastErrorMessage` is a
    /// different property that no banner consumes.
    ///
    /// RED: re-introduce `lastErrorMessage ?? "…"` at any call site → this fails
    /// naming the file and line.
    func testNoProductionCodeReadsTheBannerSlotToDecideAnOutcome() throws {
        let root = try Self.repoRoot()
        var offenders: [String] = []

        for url in Self.swiftFiles(under: root.appendingPathComponent("NanoTeams")) {
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                guard Self.readsTheSlotForAnOutcome(Self.strippingComment(line)) else { continue }
                offenders.append("\(rel):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "`lastErrorMessage` is consumed by the banner, so it cannot answer "
                + "\"did that fail, and why\". Use `errorSurfaced(since:)`.\n"
                + offenders.joined(separator: "\n"))
    }

    /// Anti-vacuity: the scanner recognises each spelling it exists to catch, and leaves
    /// the legal ones alone.
    func testTheScannerRecognisesEverySpellingItBans() {
        for banned in [
            #"return .failure(lastErrorMessage ?? "Failed.")"#,
            #"let detail = store.lastErrorMessage ?? "Failed.""#,
            "return lastErrorMessage == before",
            "guard lastErrorMessage == errorBaseline else { return }",
            "if store.lastErrorMessage != priorError {",
            "if before != lastErrorMessage {",
        ] {
            XCTAssertTrue(Self.readsTheSlotForAnOutcome(banned), banned)
        }

        for legal in [
            #"lastErrorMessage = "Autovisor could not start.""#,
            "store.lastErrorMessage = nil",
            "if dictation.lastErrorMessage != nil { return Colors.error }",
            "let baselineBanner = lastErrorMessage",
            "guard let lastErrorMessage else { return }",
        ] {
            XCTAssertFalse(Self.readsTheSlotForAnOutcome(legal), legal)
        }
    }

    // MARK: - Scanner

    /// True when `code` reads the orchestrator's banner slot in one of the two shapes
    /// that mean "decide an outcome from it".
    private static func readsTheSlotForAnOutcome(_ code: String) -> Bool {
        let slot = "lastErrorMessage"
        guard code.contains(slot) else { return false }
        if code.contains("dictation.\(slot)") { return false }

        // `<slot> ??`, `<slot> ==`, `<slot> !=`
        for op in ["??", "==", "!="] where code.contains("\(slot) \(op)") { return true }
        // `== <slot>`, `!= <slot>` (with or without a receiver)
        for op in ["==", "!="] {
            if code.contains("\(op) \(slot)") || code.contains("\(op) self.\(slot)")
                || code.contains("\(op) store.\(slot)") { return true }
        }
        return false
    }

    /// Everything before the first `//`. Doc comments in this codebase quote the very
    /// spellings the scan bans (this file included), so a scan that skipped this step
    /// would flag its own prose.
    private static func strippingComment(_ line: String) -> String {
        guard let r = line.range(of: "//") else { return line }
        return String(line[line.startIndex..<r.lowerBound])
    }

    private static func swiftFiles(under dir: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted {
            $0.path < $1.path
        }
    }

    /// The repo root, derived from this file's own path. Anchored on a BUILD source —
    /// the public mirror ships build sources only (CLAUDE.md 2026-07-27).
    private static func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let marker = dir.appendingPathComponent("NanoTeams/Services/Core/NTMSOrchestrator.swift")
            if FileManager.default.fileExists(atPath: marker.path) { return dir }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("repo root not resolvable from \(#filePath)")
    }
}
