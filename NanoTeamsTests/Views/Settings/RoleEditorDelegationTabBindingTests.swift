import XCTest
import SwiftUI
@testable import NanoTeams

/// Pins the propagation contract of the team-whitelist checkbox `Binding<Bool>`
/// constructed by `RoleEditorDelegationTab.bindingForTeam`.
///
/// Motivation: even after `RoleEditorMutations.applyEdit` was wired up (which
/// reads from `editorState.selectedDelegationTeamIDs` and writes the role
/// correctly), the user reported that unchecking/checking a team in the
/// whitelist still didn't persist after Save + reopen. Since the pure helper
/// is regression-tested, the next suspect is the UI binding layer between
/// the Toggle widget and `@State editorState`. These tests reproduce the
/// exact closure pattern used in the production view's `bindingForTeam`
/// with a plain mutable backing, so a propagation failure surfaces here
/// rather than only in the running app.
final class RoleEditorDelegationTabBindingTests: XCTestCase {

    /// Class-wrapped value-typed state so a `Binding<RoleEditorState>` built
    /// over `get: { holder.value } / set: { holder.value = $0 }` behaves
    /// exactly like SwiftUI's `@State`: the binding closures reference a
    /// single source of truth instead of a captured value copy.
    /// `@unchecked Sendable` because SwiftUI's `Binding.init(get:set:)` takes
    /// `@escaping @Sendable` closures. Every test in this file is synchronous and
    /// single-threaded — the holder models `@State`'s single source of truth,
    /// which is the property under test.
    private final class StateHolder: @unchecked Sendable {
        var value: RoleEditorState = RoleEditorState()
    }

    private func makeStateBinding(_ holder: StateHolder) -> Binding<RoleEditorState> {
        Binding(get: { holder.value }, set: { holder.value = $0 })
    }

    /// Verbatim reproduction of `RoleEditorDelegationTab.bindingForTeam(_:)`
    /// — chained mutating-method calls through the state binding's
    /// `wrappedValue`. If the production view's pattern silently drops
    /// writes, this test catches it.
    private func bindingForTeam_replica(
        state: Binding<RoleEditorState>,
        id: NTMSID
    ) -> Binding<Bool> {
        Binding(
            get: { state.wrappedValue.selectedDelegationTeamIDs.contains(id) },
            set: { isOn in
                if isOn {
                    state.wrappedValue.selectedDelegationTeamIDs.insert(id)
                } else {
                    state.wrappedValue.selectedDelegationTeamIDs.remove(id)
                }
            }
        )
    }

    // MARK: - Tests

    func testTeamWhitelistBinding_uncheck_removesIDFromSelectedSet() {
        let holder = StateHolder()
        holder.value.selectedDelegationTeamIDs = ["team-A", "team-B"]
        let stateBinding = makeStateBinding(holder)
        let teamBinding = bindingForTeam_replica(state: stateBinding, id: "team-B")

        XCTAssertTrue(teamBinding.wrappedValue, "Pre-condition: checkbox starts checked.")
        teamBinding.wrappedValue = false

        XCTAssertEqual(
            holder.value.selectedDelegationTeamIDs, ["team-A"],
            "Setting Binding<Bool> to false must remove the id from the underlying Set."
        )
    }

    func testTeamWhitelistBinding_check_insertsIDIntoSelectedSet() {
        let holder = StateHolder()
        holder.value.selectedDelegationTeamIDs = ["team-A"]
        let stateBinding = makeStateBinding(holder)
        let teamBinding = bindingForTeam_replica(state: stateBinding, id: "team-B")

        XCTAssertFalse(teamBinding.wrappedValue, "Pre-condition: checkbox starts unchecked.")
        teamBinding.wrappedValue = true

        XCTAssertEqual(
            holder.value.selectedDelegationTeamIDs, ["team-A", "team-B"],
            "Setting Binding<Bool> to true must insert the id into the underlying Set."
        )
    }

    /// Multi-step churn: the propagation contract must hold across repeated
    /// flips on the SAME binding instance. If `bindingForTeam` returned a
    /// `Binding<Bool>` whose set-closure captured a stale `editorState`
    /// snapshot at construction time, the second flip would no-op.
    func testTeamWhitelistBinding_multipleFlips_finalStateMatchesLastWrite() {
        let holder = StateHolder()
        holder.value.selectedDelegationTeamIDs = ["team-A", "team-B"]
        let stateBinding = makeStateBinding(holder)
        let teamBinding = bindingForTeam_replica(state: stateBinding, id: "team-B")

        teamBinding.wrappedValue = false  // uncheck
        teamBinding.wrappedValue = true   // re-check
        teamBinding.wrappedValue = false  // uncheck again

        XCTAssertEqual(
            holder.value.selectedDelegationTeamIDs, ["team-A"],
            "Final state must reflect the last set call, not the first."
        )
    }

    /// The Binding's `get` must always read the current state, never a
    /// snapshot from construction time. Constructed once → set elsewhere →
    /// re-read.
    func testTeamWhitelistBinding_getReadsCurrentState_notSnapshot() {
        let holder = StateHolder()
        holder.value.selectedDelegationTeamIDs = []
        let stateBinding = makeStateBinding(holder)
        let teamBinding = bindingForTeam_replica(state: stateBinding, id: "team-A")

        XCTAssertFalse(teamBinding.wrappedValue, "Initially empty → false.")

        // Mutate state from outside the binding (simulating another code path
        // writing to editorState).
        holder.value.selectedDelegationTeamIDs.insert("team-A")

        XCTAssertTrue(
            teamBinding.wrappedValue,
            "Binding<Bool>.get must reflect current state, not the value at construction time."
        )
    }
}
