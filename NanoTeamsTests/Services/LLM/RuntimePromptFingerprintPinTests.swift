import XCTest

@testable import NanoTeams

/// The composed texts' version, pinned the way `BundledContentFingerprintPinTests` pins
/// the bundled one. A wording change to a nudge, the Harmony preamble, an error-note
/// direction or a one-shot prompt moves `RuntimePromptFingerprint.current`; this test
/// fails until the new value is recorded here — which is the moment to re-measure the
/// live effect (REC.10) and to note the change, instead of shipping it under provenance
/// that says nothing moved.
@MainActor
final class RuntimePromptFingerprintPinTests: XCTestCase {

    // 2026-09-07 — first recording, on the tree that introduced the registry (bundle 1.9.10).
    // 1.9.11 — bumped without moving it: the release changed no composed text (the one
    // production diff since `746b904e` is an indent in `HarmonySentinelNormalizer.swift`).
    private static let expectedFingerprint = "d0835b762dbebb64"

    func testRuntimePromptText_hasNotChangedWithoutRecordingIt() {
        let actual = RuntimePromptFingerprint.current
        XCTAssertEqual(
            actual, Self.expectedFingerprint,
            """
            A runtime-composed prompt text changed (a nudge, the Harmony preamble, an \
            error-note direction, a one-shot prompt — see RuntimePromptRegistry).
            
            1. Re-measure what it changes live (REC.10) and note it in the commit.
            2. Set `expectedFingerprint` in this test to: \(actual)
            """
        )
    }

    func testFingerprint_isStableWithinAProcess() {
        XCTAssertEqual(RuntimePromptFingerprint.current, RuntimePromptFingerprint.current)
        XCTAssertEqual(RuntimePromptFingerprint.compute(RuntimePromptRegistry.entries), RuntimePromptFingerprint.current)
    }

    func testFingerprint_ignoresRegistryOrder() {
        XCTAssertEqual(
            RuntimePromptFingerprint.compute(RuntimePromptRegistry.entries.reversed()),
            RuntimePromptFingerprint.current)
    }

    /// RED by construction: one entry's rendering gains one byte → a different value.
    func testFingerprint_movesWhenOneEntryMoves() throws {
        var entries = RuntimePromptRegistry.entries
        let first = try XCTUnwrap(entries.first)
        entries[0] = RuntimePromptRegistry.Entry(name: first.name) { first.render() + "x" }
        XCTAssertNotEqual(RuntimePromptFingerprint.compute(entries), RuntimePromptFingerprint.current)
    }

    func testEntryNames_areUnique_andEveryEntryRendersSomething() {
        let names = RuntimePromptRegistry.entries.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "duplicate entry names: \(names)")
        XCTAssertGreaterThanOrEqual(names.count, 60, "anti-vacuum: 65 entries on 2026-09-07")
        // Two entries are empty BY DESIGN and stay registered so a future non-empty value is
        // versioned: the fresh-install `## Global guidance` (the one-tool rule moved into the
        // tool body, 2026-09-07) and the escalation clause for a refusal nobody can answer.
        let emptyByDesign: Set<String> = ["AppDefaults.globalContext", "LLMExecutionService.escalationClause/approvalUnavailable"]
        for entry in RuntimePromptRegistry.entries where !emptyByDesign.contains(entry.name) {
            XCTAssertFalse(entry.render().isEmpty, "\(entry.name) renders nothing — a sample that misses its text is not versioned")
        }
        for name in emptyByDesign {
            XCTAssertTrue(RuntimePromptRegistry.entries.contains { $0.name == name }, "\(name) left the registry — drop it from `emptyByDesign`")
        }
    }

    /// `forRun` is where the app hands a logger to a run, and it primes the value the
    /// logger seam reads from a stream task.
    func testForRun_primesTheValueTheSeamReads() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rt-\(UUID().uuidString).jsonl")
        _ = NetworkLogger.forRun(logURL: url)
        XCTAssertEqual(RuntimePromptFingerprint.primed, RuntimePromptFingerprint.current)
    }

    /// The app builds run loggers only through `forRun`. A direct `NetworkLogger(logURL:)`
    /// in the app target would write `unprimed` into its provenance.
    func testTheAppBuildsRunLoggersOnlyThroughForRun() throws {
        let root = Self.repoRoot.appendingPathComponent("NanoTeams")
        var offenders: [String] = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift", url.lastPathComponent != "NetworkLogger.swift" else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            if source.contains("NetworkLogger(logURL:") { offenders.append(url.lastPathComponent) }
        }
        XCTAssertEqual(offenders, [], "build run loggers through `NetworkLogger.forRun`: \(offenders)")
    }

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // LLM
        .deletingLastPathComponent()  // Services
        .deletingLastPathComponent()  // NanoTeamsTests
        .deletingLastPathComponent()  // repo root
}
