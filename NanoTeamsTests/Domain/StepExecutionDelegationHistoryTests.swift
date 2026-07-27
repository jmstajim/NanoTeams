import XCTest
@testable import NanoTeams

/// `StepExecution.delegationChildIDs` is the append-only history of every
/// child task this step has delegated to. Distinct from `activeDelegationChildID`
/// (in-flight marker, cleared on terminal outcome) — history persists so the
/// team graph can render completed delegation layers as muted "history" rows
/// beneath the active layer.
final class StepExecutionDelegationHistoryTests: XCTestCase {

    func testInit_defaultsToEmpty() {
        let step = StepExecution(
            id: "role_a",
            role: .softwareEngineer,
            title: "Step"
        )
        XCTAssertEqual(step.delegationChildIDs, [])
    }

    func testInit_explicitHistoryRetained() {
        let step = StepExecution(
            id: "role_a",
            role: .softwareEngineer,
            title: "Step",
            delegationChildIDs: [10, 11, 12]
        )
        XCTAssertEqual(step.delegationChildIDs, [10, 11, 12])
    }

    func testReset_clearsHistory() {
        var step = StepExecution(
            id: "role_a",
            role: .softwareEngineer,
            title: "Step",
            activeDelegationChildID: 12,
            delegationChildIDs: [10, 11, 12]
        )
        step.reset()
        XCTAssertNil(step.activeDelegationChildID)
        XCTAssertEqual(step.delegationChildIDs, [])
    }

    func testCodable_roundTripPreservesHistory() throws {
        let original = StepExecution(
            id: "role_a",
            role: .softwareEngineer,
            title: "Step",
            activeDelegationChildID: 12,
            delegationChildIDs: [10, 11, 12]
        )
        let encoder = JSONCoderFactory.makePersistenceEncoder()
        let decoder = JSONCoderFactory.makeDateDecoder()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(StepExecution.self, from: data)
        XCTAssertEqual(decoded.delegationChildIDs, [10, 11, 12])
        XCTAssertEqual(decoded.activeDelegationChildID, 12)
    }

    /// Legacy `task.json` produced before `delegationChildIDs` was introduced
    /// must decode without error and yield an empty history list — the field
    /// is `decodeIfPresent` with a `[]` default so existing on-disk data
    /// loads unchanged.
    func testCodable_legacyDecodeWithoutHistoryField() throws {
        // Minimal legacy payload — every other field has a `decodeIfPresent`
        // default; the only required keys are `id`, `role`, `title`. No
        // `delegationChildIDs` field is present (simulating a `task.json`
        // written before this field was introduced).
        let legacyJSON = """
        {
          "id": "role_a",
          "role": "softwareEngineer",
          "title": "Step"
        }
        """
        let decoder = JSONCoderFactory.makeDateDecoder()
        let data = Data(legacyJSON.utf8)
        let decoded = try decoder.decode(StepExecution.self, from: data)
        XCTAssertEqual(decoded.delegationChildIDs, [])
        XCTAssertNil(decoded.activeDelegationChildID)
    }

    /// Encoding skips the field when empty, matching the file-size policy on
    /// other optional list fields (e.g. `supervisorAnswerAttachmentPaths`).
    func testCodable_emptyHistoryNotEncoded() throws {
        let step = StepExecution(
            id: "role_a",
            role: .softwareEngineer,
            title: "Step"
        )
        let encoder = JSONCoderFactory.makePersistenceEncoder()
        let data = try encoder.encode(step)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(
            json.contains("delegationChildIDs"),
            "Empty delegationChildIDs should be omitted from JSON to keep task.json small"
        )
    }

    /// Pins the lifecycle contract that `clearDelegationFields` in
    /// `LLMExecutionService+DelegateToTeam.swift` exists to enforce: after a
    /// delegation reaches a terminal outcome, only the in-flight markers
    /// (`activeDelegationChildID`) are cleared. The
    /// append-only history (`delegationChildIDs`) MUST stay intact so the
    /// team graph can render completed delegation layers below the active one.
    /// Without this pin, a future refactor could trivially clear the history
    /// alongside the active marker (they're conceptually neighbors in the
    /// "delegation lifecycle" mental model) and silently break the UI history.
    func testTerminalCleanup_preservesHistoryWhileClearingInFlightMarkers() {
        var step = StepExecution(
            id: "role_a",
            role: .softwareEngineer,
            title: "Step",
            activeDelegationChildID: 42,
            delegationChildIDs: [10, 20, 42]
        )

        // Mirror the exact mutations `clearDelegationFields` performs.
        step.clearActiveDelegation()

        XCTAssertNil(step.activeDelegationChildID,
                     "activeDelegationChildID must clear on terminal outcome (pauseRun checks this to identify mid-delegation steps)")
        XCTAssertEqual(step.delegationChildIDs, [10, 20, 42],
                       "delegationChildIDs MUST be preserved across terminal outcomes — it's the audit trail the team graph renders as completed history layers")
    }

    /// Pins the append-only contract: every time a new delegation lands on a
    /// step, its child ID is appended to `delegationChildIDs` in chronological
    /// order. Mirrors the actual mutation in
    /// `LLMExecutionService+DelegateToTeam.swift:165-171`.
    func testHistoryAppend_chronologicalOrder_idempotentOnDuplicate() {
        var step = StepExecution(
            id: "role_a",
            role: .softwareEngineer,
            title: "Step"
        )

        // First delegation lands. The single mutator enforces
        // `activeChildID ∈ history` — replaces the legacy two-write pattern.
        step.setActiveDelegation(childID: 10)
        // First delegation completes; markers cleared but history kept.
        step.clearActiveDelegation()

        // Second delegation lands.
        step.setActiveDelegation(childID: 20)
        // Re-stamping the same active id (e.g. resume after pause) must NOT
        // duplicate the history entry — the mutator is idempotent.
        step.setActiveDelegation(childID: 20)

        XCTAssertEqual(step.delegationChildIDs, [10, 20],
                       "Chronological order, no duplicates — re-stamping the same active id is idempotent on history")
    }
}
