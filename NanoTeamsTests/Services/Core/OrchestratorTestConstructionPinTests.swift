import XCTest

@testable import NanoTeams

/// Structural invariant over the whole test target: **`NTMSOrchestrator` is
/// constructed in exactly one place, `TestOrchestrator.make`.**
///
/// A source-level pin (house pattern: `StepLifecyclePersistPairingTests`)
/// because the property is "no suite was forgotten", and that is a property of
/// the SET of construction sites — no behavioural test can observe a site that
/// does not exist yet.
///
/// Not hypothetical. Four seams on `NTMSOrchestrator.init` are optional and
/// each one's `nil` resolves outward: a real `LMStudioEmbeddingClient`, a real
/// `LLMClientRouter` (twice), and the process-global `ChatModelEnsurer.shared`.
/// A forgotten argument compiles, so 93 sites across 37 files had accumulated
/// one — `openWorkFolder` alone then issues two 5-second `GET /api/v0/models`
/// per call, and an adopted instance can later be UNLOADED out from under a
/// model the developer hand-loaded in the LM Studio UI. The failure is silent
/// in both directions: slow when a server is up, invisible when it is not.
///
/// The allowlist is deliberately NOT a list of filenames. It is one hard-coded
/// path plus whatever carries an explicit, justified marker, so adding a second
/// production-intent driver means writing down WHY next to the code rather than
/// editing this test.
final class OrchestratorTestConstructionPinTests: XCTestCase {

    /// The single legal construction site.
    private static let factoryPath = "NanoTeamsTests/Support/TestOrchestratorFactory.swift"

    /// Escape hatch for production-intent drivers (today: the headless runner,
    /// which is SUPPOSED to reach the configured server). Must be followed by
    /// rationale text on the same line — a bare marker is not an exemption.
    private static let marker = "NTMS-ALLOW-REAL-LLM-CLIENT:"

    /// Lines above a construction site that may carry the marker. A rationale
    /// worth writing runs to several lines, and the marker belongs on the FIRST
    /// of them where a reader meets it.
    private static let markerLookbackLines = 6

    /// Assembled at runtime so this file's own assertions and messages — which
    /// necessarily spell the construction out — are not themselves flagged.
    private static var constructionNeedle: String { "NTMSOrchestrator" + "(" }

    /// Everything before `//`, so prose that legitimately NAMES the construction
    /// (this pin's doc comment, the factory's) is not mistaken for one. Quotes
    /// are respected: a `//` inside a string literal is code, not a comment.
    private static func strippingLineComments(_ line: String) -> String {
        var out = ""
        var inString = false
        var previous: Character?
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"", previous != "\\" { inString.toggle() }
            if !inString, character == "/", previous == "/" {
                return String(out.dropLast())
            }
            out.append(character)
            previous = character
            index = line.index(after: index)
        }
        return out
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Core
            .deletingLastPathComponent()  // Services
            .deletingLastPathComponent()  // NanoTeamsTests
            .deletingLastPathComponent()  // repo root
    }

    private struct Site {
        let relativePath: String
        let line: Int
        let exempt: Bool
    }

    /// Every `NTMSOrchestrator(` under `NanoTeamsTests/`, with the scanned-file
    /// count so vacuity can be asserted separately.
    private func scan() throws -> (sites: [Site], filesScanned: Int) {
        let testsRoot = repoRoot.appendingPathComponent("NanoTeamsTests")
        var sites: [Site] = []
        var filesScanned = 0

        let enumerator = FileManager.default.enumerator(
            at: testsRoot, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            filesScanned += 1
            let relativePath = "NanoTeamsTests/"
                + url.path.replacingOccurrences(of: testsRoot.path + "/", with: "")
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")

            for (index, line) in lines.enumerated()
            where Self.strippingLineComments(line).contains(Self.constructionNeedle) {
                // The marker lives in a comment by definition, so it is matched
                // against the RAW lines.
                let window = lines[max(0, index - Self.markerLookbackLines)...index]
                let exempt = window.contains { candidate in
                    guard let range = candidate.range(of: Self.marker) else { return false }
                    return !candidate[range.upperBound...]
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                sites.append(Site(relativePath: relativePath, line: index + 1, exempt: exempt))
            }
        }
        return (sites, filesScanned)
    }

    // MARK: - The invariant

    func testNoTestConstructsAnOrchestratorOutsideTheFactory() throws {
        let (sites, _) = try scan()
        let illegal = sites.filter { $0.relativePath != Self.factoryPath && !$0.exempt }

        XCTAssertTrue(
            illegal.isEmpty,
            "\(illegal.map { "\($0.relativePath):\($0.line)" }.joined(separator: ", ")) "
                + "construct NTMSOrchestrator directly. Use `TestOrchestrator.make(...)` — a "
                + "forgotten `chatLifecycleClient` / `searchEmbeddingClient` / "
                + "`chatModelEnsurer` argument compiles fine and silently sends the test at "
                + "the developer's LM Studio. If this really is a production-intent driver, "
                + "add a `\(Self.marker) <why>` comment on or just above the line.")
    }

    /// The factory must itself pass every seam. Without this the pin could be
    /// satisfied by a factory that forgot one — one leak instead of 93, but
    /// still a leak, and now centralized where nobody looks.
    func testTheFactoryStubsEverySeam() throws {
        let code = try String(
            contentsOf: repoRoot.appendingPathComponent(Self.factoryPath), encoding: .utf8)
            .components(separatedBy: "\n")
            .map(Self.strippingLineComments)
            .joined(separator: "\n")

        for seam in ["embeddingLifecycle:", "searchEmbeddingClient:",
                     "chatLifecycleClient:", "chatModelEnsurer:"] {
            XCTAssertTrue(code.contains(seam),
                          "TestOrchestrator.make must pass \(seam) — it is one of the four "
                              + "`nil`-resolves-to-the-network seams on the orchestrator's init")
        }
        XCTAssertEqual(
            code.components(separatedBy: Self.constructionNeedle).count - 1, 1,
            "The factory must hold exactly one construction site")
        XCTAssertFalse(
            code.contains("ChatModelEnsurer" + ".shared"),
            "The factory must build a FRESH ledger — a global one lets one suite's adoption "
                + "become another suite's unload")
    }

    // MARK: - Anti-vacuity
    //
    // A broken `#filePath`→repoRoot derivation would scan zero files and pass
    // green, which is exactly the failure mode a source-scanning pin invites.

    func testThePinIsNotVacuous() throws {
        let (sites, filesScanned) = try scan()

        XCTAssertGreaterThanOrEqual(
            filesScanned, 500,
            "Expected to scan the whole test target (~650 files). Far fewer means the root "
                + "derivation broke and this pin is checking nothing.")
        XCTAssertGreaterThanOrEqual(
            sites.count, 2,
            "Expected at least the factory's own call plus one marked exemption. Zero means "
                + "the construction spelling changed and the scan no longer matches it.")
        XCTAssertTrue(
            sites.contains { $0.relativePath == Self.factoryPath },
            "\(Self.factoryPath) must exist and construct the orchestrator — a rename must "
                + "fail here rather than silently widening the pin to the whole target")
    }

    /// A CEILING, not a floor: the escape hatch stays available, but it cannot
    /// quietly become the norm.
    func testExemptionsDoNotProliferate() throws {
        let (sites, _) = try scan()
        let exempt = sites.filter(\.exempt)
        XCTAssertLessThanOrEqual(
            exempt.count, 3,
            "\(exempt.map { "\($0.relativePath):\($0.line)" }.joined(separator: ", ")) — more "
                + "production-intent drivers than expected. Each one talks to a real server "
                + "during the test suite; confirm that is intended before raising this bound.")
    }
}
