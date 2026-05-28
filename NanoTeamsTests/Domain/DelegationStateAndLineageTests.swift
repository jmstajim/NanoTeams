import XCTest
@testable import NanoTeams

/// Tests for the I7 / I8 structural refactors:
///
/// - **I7**: `StepExecution`'s five flat delegation fields aggregated into
///   `DelegationState` + `AncillaryQuery` with invariant-enforcing mutators.
/// - **I8**: `NTMSTask`'s three flat parentage fields aggregated into the
///   `TaskLineage` enum so `(parentTaskID == nil) ↔ (parentRoleID == nil) ↔
///   (depth == 0)` is unrepresentable to violate, and depth is clamped to
///   `[0, maxDelegationDepth]`.
///
/// Each test pins one structural invariant. The tests are heavy on Codable
/// round-trips because backwards compatibility with `task.json` files
/// written by pre-refactor builds is the load-bearing constraint — break
/// the legacy decode path and existing user data unloads silently.
final class DelegationStateAndLineageTests: XCTestCase {

    // MARK: - I7: DelegationState invariant tests

    func testDelegationState_init_appendsActiveChildToHistory_whenMissing() {
        // Caller passes `activeChildID = 7` but doesn't put 7 in history.
        // Pre-refactor this was a legal-but-broken combination (the legacy
        // write site relied on a manual `if !contains { append }` pattern
        // that any caller could forget). Post-refactor the type fixes it.
        let state = DelegationState(session: nil, activeChildID: 7, history: [])
        XCTAssertEqual(state.activeChildID, 7)
        XCTAssertEqual(state.history, [7],
                       "DelegationState.init MUST auto-append activeChildID to history when missing — that's the invariant the refactor enforces structurally.")
    }

    func testDelegationState_init_idempotentOnDuplicate() {
        // If the caller correctly includes the active id in history,
        // init must NOT duplicate it.
        let state = DelegationState(session: nil, activeChildID: 7, history: [3, 7])
        XCTAssertEqual(state.history, [3, 7],
                       "DelegationState init must be idempotent on activeChildID already in history.")
    }

    func testDelegationState_beginActive_appendsAndIsIdempotent() {
        var state = DelegationState()
        state.beginActive(childID: 10)
        state.beginActive(childID: 10)  // re-stamping the same id
        state.beginActive(childID: 20)  // new delegation
        state.beginActive(childID: 20)  // re-stamping again
        XCTAssertEqual(state.history, [10, 20])
        XCTAssertEqual(state.activeChildID, 20)
    }

    func testDelegationState_clearActive_preservesHistory() {
        // The whole point of `delegationChildIDs` (now `history`): it's an
        // append-only audit trail. `clearActive()` is for terminal cleanup
        // — must clear `activeChildID` + `session` only, never `history`.
        var state = DelegationState(session: "resp-X", activeChildID: 5, history: [3, 5])
        state.clearActive()
        XCTAssertNil(state.activeChildID)
        XCTAssertNil(state.session)
        XCTAssertEqual(state.history, [3, 5],
                       "clearActive must preserve `history` — it's the audit trail the team graph renders as completed delegation layers.")
    }

    func testDelegationState_isEmpty_trueOnDefault_falseOnAnyField() {
        XCTAssertTrue(DelegationState().isEmpty)
        XCTAssertFalse(DelegationState(session: "x").isEmpty)
        XCTAssertFalse(DelegationState(activeChildID: 1).isEmpty)
        XCTAssertFalse(DelegationState(history: [1]).isEmpty)
    }

    // MARK: - I7: StepExecution Codable round-trip + back-compat

    func testStepExecution_codable_roundTrip_newShape() throws {
        // Round-trip a step with an active delegation. Encode → Decode →
        // verify state equality. Pin: the new bundled shape survives
        // serialization without losing the cross-field invariant.
        var step = StepExecution(id: "r", role: .softwareEngineer, title: "x")
        step.setActiveDelegation(childID: 42)
        step.setActiveDelegation(childID: 17)  // history grows; active=17
        step.setDelegationSession("resp-abc")
        step.setAncillaryQuestion("Need info")

        let encoder = JSONCoderFactory.makePersistenceEncoder()
        let decoder = JSONCoderFactory.makeDateDecoder()
        let data = try encoder.encode(step)
        let decoded = try decoder.decode(StepExecution.self, from: data)

        XCTAssertEqual(decoded.delegationSession, "resp-abc")
        XCTAssertEqual(decoded.activeDelegationChildID, 17)
        XCTAssertEqual(decoded.delegationChildIDs, [42, 17])
        XCTAssertEqual(decoded.ancillaryQuestion, "Need info")
        XCTAssertNil(decoded.ancillaryAnswer)
    }

    func testStepExecution_codable_decodes_legacyFlatShape() throws {
        // Most important back-compat test: a `task.json` written by a
        // build before this refactor uses five flat keys
        // (`delegationSession`, `activeDelegationChildID`,
        // `delegationChildIDs`, `ancillaryQuestion`, `ancillaryAnswer`).
        // The new decoder MUST find them and rebuild `DelegationState` /
        // `AncillaryQuery` correctly. Without this the user's existing
        // tasks unload silently after upgrade.
        //
        // Round-trip approach: encode a real step, strip the new bundled
        // `delegation` / `ancillary` blocks, inject the five legacy flat
        // keys. More robust than hand-building JSON — guarantees we don't
        // miss required Codable fields the test author forgot.
        let seedStep = StepExecution(id: "role_a", role: .softwareEngineer, title: "Step Title")
        let encoded = try JSONCoderFactory.makePersistenceEncoder().encode(seedStep)
        var dict = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        dict.removeValue(forKey: "delegation")
        dict.removeValue(forKey: "ancillary")
        dict["delegationSession"] = "resp-legacy"
        dict["activeDelegationChildID"] = 42
        dict["delegationChildIDs"] = [10, 20, 42]
        dict["ancillaryQuestion"] = "Need exec input"
        dict["ancillaryAnswer"] = "Approved"
        let data = try JSONSerialization.data(withJSONObject: dict)

        let decoder = JSONCoderFactory.makeDateDecoder()
        let decoded = try decoder.decode(StepExecution.self, from: data)

        XCTAssertEqual(decoded.delegationSession, "resp-legacy",
                       "Legacy `delegationSession` key must round-trip into DelegationState.session")
        XCTAssertEqual(decoded.activeDelegationChildID, 42,
                       "Legacy `activeDelegationChildID` key must round-trip into DelegationState.activeChildID")
        XCTAssertEqual(decoded.delegationChildIDs, [10, 20, 42],
                       "Legacy `delegationChildIDs` key must round-trip into DelegationState.history")
        XCTAssertEqual(decoded.ancillaryQuestion, "Need exec input",
                       "Legacy `ancillaryQuestion` key must round-trip into AncillaryQuery.question")
        XCTAssertEqual(decoded.ancillaryAnswer, "Approved",
                       "Legacy `ancillaryAnswer` key must round-trip into AncillaryQuery.answer")
    }

    func testStepExecution_codable_omits_emptyDelegationAndAncillary() throws {
        // Non-delegating roles (the vast majority of steps) should NOT
        // bloat `task.json` with empty delegation/ancillary blocks.
        // Pin: encoder skips both fields when their bundles are empty.
        let step = StepExecution(id: "r", role: .softwareEngineer, title: "x")

        let encoder = JSONCoderFactory.makePersistenceEncoder()
        let data = try encoder.encode(step)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertNil(json["delegation"],
                     "Empty DelegationState must NOT be encoded — keeps task.json compact for non-delegating roles.")
        XCTAssertNil(json["ancillary"],
                     "Empty AncillaryQuery must NOT be encoded.")
    }

    // MARK: - I8: TaskLineage invariant tests

    func testTaskLineage_from_rootWhenParentMissing() {
        // (nil, nil, 0) → root
        XCTAssertEqual(TaskLineage.from(parentTaskID: nil, parentRoleID: nil, depth: 0), .root)
    }

    func testTaskLineage_from_rootWhenEitherParentFieldMissing() {
        // The escalation path needs BOTH parentTaskID AND parentRoleID
        // (looks up parent step via `step.id == parentRoleID`). Either
        // alone is incoherent — normalize to `.root` rather than crashing
        // downstream. Mirrors the documented invariant.
        XCTAssertEqual(TaskLineage.from(parentTaskID: 5, parentRoleID: nil, depth: 1), .root)
        XCTAssertEqual(TaskLineage.from(parentTaskID: nil, parentRoleID: "r", depth: 1), .root)
    }

    func testTaskLineage_from_clampsDepthInDelegated() {
        // depth=99 → clamped to maxDelegationDepth (3 by default).
        let lineage = TaskLineage.from(parentTaskID: 1, parentRoleID: "r", depth: 99)
        guard case let .delegated(parent, role, depth) = lineage else {
            return XCTFail("Expected .delegated, got \(lineage)")
        }
        XCTAssertEqual(parent, 1)
        XCTAssertEqual(role, "r")
        XCTAssertEqual(depth, DelegationConstants.maxDelegationDepth,
                       "Depth in `.delegated` must clamp to maxDelegationDepth — depth>cap is unrepresentable.")
    }

    func testTaskLineage_from_clampsDepthBelowOne() {
        // depth=0 in `.delegated` makes no sense (root is depth 0). Clamp to 1.
        let lineage = TaskLineage.from(parentTaskID: 1, parentRoleID: "r", depth: 0)
        guard case let .delegated(_, _, depth) = lineage else {
            return XCTFail("Expected .delegated even with depth=0 if both parent fields set")
        }
        XCTAssertEqual(depth, 1,
                       "A delegated task with depth=0 is incoherent — clamp to depth=1 (the minimum legal child depth).")
    }

    func testTaskLineage_normalized_repairsDirectlyConstructed() {
        // Defense against hand-edited task.json shipping `lineage:
        // {"delegated":{"parentTaskID":1,"parentRoleID":"r","depth":99}}`
        // — `normalized()` re-applies the depth clamp post-decode.
        let badLineage = TaskLineage.delegated(parentTaskID: 1, parentRoleID: "r", depth: 99)
        let fixed = badLineage.normalized()
        XCTAssertEqual(fixed.depth, DelegationConstants.maxDelegationDepth)
    }

    // MARK: - I8: NTMSTask back-compat read accessors

    func testNTMSTask_lineageRoot_exposesNilParentage() {
        let task = NTMSTask(id: 1, title: "t", supervisorTask: "x")
        XCTAssertEqual(task.lineage, .root)
        XCTAssertNil(task.parentTaskID)
        XCTAssertNil(task.parentRoleID)
        XCTAssertEqual(task.delegationDepth, 0)
    }

    func testNTMSTask_lineageDelegated_exposesParentageFields() {
        let task = NTMSTask(
            id: 5,
            title: "child",
            supervisorTask: "x",
            parentTaskID: 1,
            parentRoleID: "coding_agent",
            delegationDepth: 2
        )
        XCTAssertEqual(task.parentTaskID, 1)
        XCTAssertEqual(task.parentRoleID, "coding_agent")
        XCTAssertEqual(task.delegationDepth, 2)
    }

    func testNTMSTask_init_normalizesIncoherentInput_toRoot() {
        // Caller passes parentTaskID without parentRoleID — the init's
        // factory normalizes to `.root` rather than constructing a half-set
        // delegated lineage. Pre-refactor this was a legal storage state.
        let task = NTMSTask(
            id: 5,
            title: "incoherent",
            supervisorTask: "x",
            parentTaskID: 1,
            parentRoleID: nil,  // missing — should force `.root`
            delegationDepth: 2  // also stripped
        )
        XCTAssertEqual(task.lineage, .root,
                       "Half-set parentage (parentTaskID without parentRoleID) must normalize to .root — neither escalation nor path-walking work without both.")
        XCTAssertEqual(task.delegationDepth, 0,
                       "Depth must be 0 for a normalized-to-root lineage.")
    }

    func testNTMSTask_init_clampsHighDepth() {
        // delegationDepth=10 with both parent fields set → clamped to max.
        let task = NTMSTask(
            id: 5,
            title: "deep",
            supervisorTask: "x",
            parentTaskID: 1,
            parentRoleID: "r",
            delegationDepth: 10
        )
        XCTAssertEqual(task.delegationDepth, DelegationConstants.maxDelegationDepth,
                       "Depth must clamp to maxDelegationDepth — depth>cap is unrepresentable post-refactor.")
    }

    // MARK: - I8: NTMSTask Codable round-trip + back-compat

    func testNTMSTask_codable_roundTrip_newShape() throws {
        let task = NTMSTask(
            id: 5,
            title: "child",
            supervisorTask: "x",
            parentTaskID: 1,
            parentRoleID: "coding_agent",
            delegationDepth: 2
        )

        let encoder = JSONCoderFactory.makePersistenceEncoder()
        let decoder = JSONCoderFactory.makeDateDecoder()
        let data = try encoder.encode(task)
        let decoded = try decoder.decode(NTMSTask.self, from: data)

        XCTAssertEqual(decoded.lineage, task.lineage)
        XCTAssertEqual(decoded.parentTaskID, 1)
        XCTAssertEqual(decoded.parentRoleID, "coding_agent")
        XCTAssertEqual(decoded.delegationDepth, 2)
    }

    func testNTMSTask_codable_decodes_legacyFlatShape() throws {
        // The most critical back-compat test for I8. A `task.json` written
        // by a pre-refactor build uses three flat keys at the top level:
        // `parentTaskID`, `parentRoleID`, `delegationDepth`. The new
        // decoder MUST detect the absence of `lineage` and fall back to
        // those keys. Otherwise existing user data fails to decode.
        // Round-trip approach: encode a real task, strip the new `lineage`
        // field, inject the three legacy flat keys. Guarantees we don't
        // miss required fields by hand.
        let task = NTMSTask(
            id: 42,
            title: "child",
            supervisorTask: "x",
            parentTaskID: 1,
            parentRoleID: "coding_agent",
            delegationDepth: 2
        )
        let encoded = try JSONCoderFactory.makePersistenceEncoder().encode(task)
        var dict = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        dict.removeValue(forKey: "lineage")
        dict["parentTaskID"] = 1
        dict["parentRoleID"] = "coding_agent"
        dict["delegationDepth"] = 2
        let data = try JSONSerialization.data(withJSONObject: dict)

        let decoder = JSONCoderFactory.makeDateDecoder()
        let decoded = try decoder.decode(NTMSTask.self, from: data)

        XCTAssertEqual(decoded.parentTaskID, 1)
        XCTAssertEqual(decoded.parentRoleID, "coding_agent")
        XCTAssertEqual(decoded.delegationDepth, 2)
        guard case let .delegated(_, _, depth) = decoded.lineage else {
            return XCTFail("Legacy decode must produce .delegated; got \(decoded.lineage)")
        }
        XCTAssertEqual(depth, 2)
    }

    func testNTMSTask_codable_legacyDecode_clampsHighDepth() throws {
        // Defense: a legacy file with `delegationDepth: 99` must be clamped
        // on load (the factory in the legacy-fallback branch runs
        // `from(...)` which clamps).
        // Round-trip approach: encode a fresh task, strip new bundle, inject
        // legacy flat keys with depth=99.
        let task = NTMSTask(id: 1, title: "t", supervisorTask: "x")  // root
        let encoded = try JSONCoderFactory.makePersistenceEncoder().encode(task)
        var dict = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        dict.removeValue(forKey: "lineage")
        dict["parentTaskID"] = 5
        dict["parentRoleID"] = "r"
        dict["delegationDepth"] = 99
        let data = try JSONSerialization.data(withJSONObject: dict)
        let decoder = JSONCoderFactory.makeDateDecoder()
        let decoded = try decoder.decode(NTMSTask.self, from: data)
        XCTAssertEqual(decoded.delegationDepth, DelegationConstants.maxDelegationDepth,
                       "Legacy decode must clamp depth like the new init does.")
    }

    func testNTMSTask_codable_omits_lineageBlockWhenRoot() throws {
        // Top-level tasks (the common case) should NOT bloat task.json with
        // a lineage block — encoder skips it when `.root`.
        let task = NTMSTask(id: 1, title: "root", supervisorTask: "x")
        let encoder = JSONCoderFactory.makePersistenceEncoder()
        let data = try encoder.encode(task)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(json["lineage"],
                     "Root tasks must NOT have a lineage key — keeps task.json concise.")
        XCTAssertNil(json["parentTaskID"],
                     "Root tasks must NOT have parentTaskID at top level — legacy keys are no longer emitted.")
    }
}
