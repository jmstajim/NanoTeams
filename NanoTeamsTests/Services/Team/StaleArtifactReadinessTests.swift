import XCTest
@testable import NanoTeams

/// Readiness is not "my inputs exist and I am idle" — an artifact can exist and be STALE.
///
/// The reachable shape (open question Q-12, closed 2026-09-11): a checker holds
/// `request_changes`, its request is approved, and `holdDownstreamForRevision` marks the
/// requester `.revisionRequested` WITHOUT cancelling it — so its step plays out and must end
/// in an artifact. The amendment target restarts immediately (all its upstream are `.done`),
/// and on the next pass `producedArtifacts` carries both the target's new output and the
/// requester's stale one. A consumer of the stale artifact was then ready, and started in
/// parallel with the requester's own re-run: its report is written against a document that is
/// already being replaced, and nobody reads the second one.
///
/// `startableRevisionRoleIDs` had forbidden exactly this for a REVISION role since it was
/// written. The rule is now applied from one place to both gates.
@MainActor
final class StaleArtifactReadinessTests: XCTestCase {

    private var engine: TeamEngine!

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        engine = TeamEngine()
    }

    override func tearDown() async throws {
        engine.stop()
        engine = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures — a three-link chain: maker → checker → consumer

    private func role(_ id: String, requires: [String], produces: [String]) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id, name: id, prompt: "p", toolIDs: [ToolNames.createArtifact],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: requires, producesArtifacts: produces))
    }

    private var roles: [TeamRoleDefinition] {
        [
            TeamRoleDefinition(
                id: "supervisor", name: "Supervisor", prompt: "", toolIDs: [],
                usePlanningPhase: false,
                dependencies: RoleDependencies(producesArtifacts: ["Supervisor Task"]),
                systemRoleID: "supervisor"),
            role("maker", requires: ["Supervisor Task"], produces: ["Notes"]),
            role("checker", requires: ["Notes"], produces: ["Review"]),
            role("consumer", requires: ["Notes", "Review"], produces: ["Report"]),
        ]
    }

    private let produced: Set<String> = ["Supervisor Task", "Notes", "Review"]

    // MARK: - The defect

    /// The checker's request was approved: it is `.revisionRequested`, its step finished and
    /// left a Review that the re-run will replace. The consumer must NOT start on it.
    ///
    /// RED: drop the `hasBlockingUpstream` filter from `findReadyRoles` → "consumer" appears
    /// here and runs against the document being replaced.
    func testConsumerDoesNotStartOnAnArtifactItsUpstreamIsAboutToReplace() {
        let ready = engine.findReadyRoles(
            roles: roles,
            producedArtifacts: produced,
            roleStatuses: ["maker": .done, "checker": .revisionRequested])

        XCTAssertFalse(ready.contains("consumer"),
                       "the Review in hand is the pre-amendment one; got \(ready)")
    }

    /// The same rule covers a still-`.working` upstream, which is the other half of
    /// `startableRevisionRoleIDs`' blocking set — the two gates now share one list.
    func testConsumerDoesNotStartWhileAnUpstreamIsStillWorking() {
        let ready = engine.findReadyRoles(
            roles: roles,
            producedArtifacts: produced,
            roleStatuses: ["maker": .done, "checker": .working])
        XCTAssertFalse(ready.contains("consumer"), String(describing: ready))
    }

    /// No deadlock, and no over-blocking: once the upstream lands the consumer is ready with
    /// the FRESH artifact. This is the assertion that makes the two above meaningful.
    func testConsumerBecomesReadyOnceTheUpstreamIsDone() {
        let ready = engine.findReadyRoles(
            roles: roles,
            producedArtifacts: produced,
            roleStatuses: ["maker": .done, "checker": .done])
        XCTAssertTrue(ready.contains("consumer"), String(describing: ready))
    }

    /// A role with no blocked upstream is untouched — the filter must not become a
    /// whole-run freeze whenever anything anywhere is revising.
    func testAnIndependentRoleIsUnaffected() {
        var roster = roles
        roster.append(role("independent", requires: ["Supervisor Task"], produces: ["Aside"]))
        let ready = engine.findReadyRoles(
            roles: roster,
            producedArtifacts: produced,
            roleStatuses: ["maker": .done, "checker": .revisionRequested])
        XCTAssertTrue(ready.contains("independent"), String(describing: ready))
    }

    // MARK: - The requester keeps working, so it must stop building

    /// `holdDownstreamForRevision` deliberately does not cancel the requester: it marks it
    /// `.revisionRequested` and lets its step finish. The TARGET, meanwhile, restarts at once
    /// and begins rewriting the tree. A verifier that calls `run_xcodetests` to round off the
    /// report it is about to have replaced therefore builds a half-rewritten tree — red for
    /// nobody's defect, "does not compile" in a discarded report, and the engineer's own
    /// build queued behind a pointless one.
    ///
    /// Only the runners go. The role must still be able to finish and submit its artifact,
    /// which is what releases the cascade.
    func testSupersededStep_losesTheRunnersAndKeepsEverythingElse() {
        let schemas = [
            ToolSchema(name: ToolNames.runXcodebuild, description: "d", parameters: JSONSchema(type: "object")),
            ToolSchema(name: ToolNames.runXcodetests, description: "d", parameters: JSONSchema(type: "object")),
            ToolSchema(name: ToolNames.readFile, description: "d", parameters: JSONSchema(type: "object")),
            ToolSchema(name: ToolNames.createArtifact, description: "d", parameters: JSONSchema(type: "object")),
        ]

        let stripped = LLMExecutionService.supersededRunnerStrip(schemas, workSuperseded: true)
        XCTAssertEqual(Set(stripped.map(\.name)), [ToolNames.readFile, ToolNames.createArtifact],
                       "the runners go; the ability to finish the step must not")

        XCTAssertEqual(
            LLMExecutionService.supersededRunnerStrip(schemas, workSuperseded: false).count,
            schemas.count,
            "an ordinary step keeps its runners")
    }

    /// ONE predicate feeds both enforcement points — the entry-time strip and the executor's
    /// per-iteration withhold (`SupersededRunnersWithheldTests`) — so they cannot disagree
    /// about which role is superseded.
    func testIsWorkSuperseded_readsTheRunsStatus() {
        let run = Run(id: 0, steps: [], roleStatuses: ["checker": .revisionRequested, "maker": .working])
        XCTAssertTrue(LLMExecutionService.isWorkSuperseded(run: run, roleID: "checker"))
        XCTAssertFalse(LLMExecutionService.isWorkSuperseded(run: run, roleID: "maker"))
        XCTAssertFalse(LLMExecutionService.isWorkSuperseded(run: run, roleID: "nobody"),
                       "an unknown role is not superseded — the strip never fires by accident")
        XCTAssertEqual(LLMExecutionService.supersededRunners,
                       [ToolNames.runXcodebuild, ToolNames.runXcodetests])
    }

    /// Both gates read ONE list of blocking statuses, so they cannot drift into disagreeing
    /// about what "stale" means.
    func testBothReadinessGatesShareOneBlockingSet() {
        XCTAssertEqual(
            Set(TeamEngine.revisionBlockingStatuses), Set([.revisionRequested, .working]))
        let startable = TeamEngine.startableRevisionRoleIDs(
            roleStatuses: ["checker": .revisionRequested, "maker": .working], roles: roles)
        XCTAssertFalse(startable.contains("checker"),
                       "a revision role waits for its upstream for the same reason a fresh one does")
    }
}
