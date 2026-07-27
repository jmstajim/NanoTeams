import XCTest

@testable import NanoTeams

/// Structural invariant over `NTMSOrchestrator+ChatModelLifecycle`: **the
/// residency subsystem constructs a real client in exactly one place, and never
/// defaults an ownership ledger to the process-global one.**
///
/// The production half of the guarantee whose test half is
/// `OrchestratorTestConstructionPinTests`. Routing every test through
/// `TestOrchestrator.make` is not enough on its own: before
/// `resolvedChatLifecycleClient`, each entry point did its own
/// `client ?? LLMClientRouter()`, so even a fully-stubbed orchestrator reached
/// the network through any residency call made WITHOUT an explicit client — and
/// production makes exactly those calls (`ModelResidencyHooks`,
/// `LLMSettingsSheetView`). Funnelling the fallback through one computed
/// property is what makes `nil` mean "this orchestrator's client".
///
/// Pinned structurally because the property is about the SET of entry points:
/// a fifth one added tomorrow with its own `?? LLMClientRouter()` reopens the
/// hole, and no behavioural test can observe a method that does not exist yet.
/// `ResidencyTriggerTests.testReconcileAndReportResidency_withNoExplicitClient_usesTheInjectedOne`
/// covers the behaviour for the entry points that DO exist.
final class ChatModelLifecycleClientResolutionPinTests: XCTestCase {

    private func lifecycleLines() throws -> [String] {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Core
            .deletingLastPathComponent()  // Services
            .deletingLastPathComponent()  // NanoTeamsTests
            .deletingLastPathComponent()  // repo root
        let source = repoRoot
            .appendingPathComponent("NanoTeams/Services/Core")
            .appendingPathComponent("NTMSOrchestrator+ChatModelLifecycle.swift")
        return try String(contentsOf: source, encoding: .utf8).components(separatedBy: "\n")
    }

    func testRealRouterIsConstructedExactlyOnce_insideTheResolutionSeam() throws {
        let lines = try lifecycleLines()
        let hits = lines.enumerated().filter { $0.element.contains("LLMClientRouter()") }

        XCTAssertEqual(
            hits.count, 1,
            "line(s) \(hits.map { $0.offset + 1 }) construct an LLMClientRouter. Residency "
                + "must build a real client in exactly ONE place — `resolvedChatLifecycleClient` "
                + "— or an entry point called without an explicit client silently bypasses the "
                + "injected stub and hits the developer's LM Studio.")

        guard let hit = hits.first else { return }
        // The single hit must live inside the seam: walk back to the nearest
        // declaration and check it is the one we mean.
        let declaration = lines[..<hit.offset].reversed().first {
            $0.contains("var ") || $0.contains("func ")
        }
        XCTAssertEqual(
            declaration?.contains("resolvedChatLifecycleClient"), true,
            "The router construction moved out of `resolvedChatLifecycleClient` (nearest "
                + "declaration: \(declaration ?? "none")). Keep it in the seam.")
    }

    func testNoEntryPointDefaultsToTheProcessGlobalEnsurer() throws {
        let lines = try lifecycleLines()
        let hits = lines.enumerated()
            .filter { $0.element.contains("ChatModelEnsurer = .shared") }
            .map { $0.offset + 1 }

        XCTAssertTrue(
            hits.isEmpty,
            "line(s) \(hits) default an ensurer to `.shared`. Use "
                + "`ensurer: ChatModelEnsurer? = nil` and `resolvedEnsurer(_:)` — a global "
                + "ledger lets a test adopt, then unload, a model the developer hand-loaded.")
    }

    /// Anti-vacuity: a refactor that moves the entry points elsewhere would make
    /// both assertions above pass over an empty file.
    func testThePinIsNotVacuous() throws {
        let lines = try lifecycleLines()

        let optionalClients = lines.filter { $0.contains("client: (any LLMClient)? = nil") }.count
        XCTAssertGreaterThanOrEqual(
            optionalClients, 4,
            "Expected at least 4 residency entry points taking an optional client "
                + "(reconcile, adopt, switch, reconcileAndReport). Fewer means they moved and "
                + "this pin no longer sees them — re-point it rather than deleting it.")

        let optionalEnsurers = lines.filter { $0.contains("ensurer: ChatModelEnsurer? = nil") }.count
        XCTAssertGreaterThanOrEqual(
            optionalEnsurers, 4,
            "Expected at least 4 entry points taking an optional ensurer")

        XCTAssertTrue(
            lines.contains { $0.contains("resolvedChatLifecycleClient") },
            "The seam itself must exist in this file")
    }
}
