import Foundation

/// What — if anything — to say after a SUCCESSFUL `update_scratchpad`, on each of
/// the two surfaces that can carry it.
///
/// Two rules, and the split between them is the whole point:
///
/// - **The wire** (what the MODEL reads) gets a turn only when the app did
///   something OTHER than what the call implies — the memory write failed, or the
///   standing memory was deliberately left alone. Both correct a false belief the
///   model would otherwise carry into its next pass.
/// - **The feed** (what the SUPERVISOR reads, as a `system: note`) gets a note
///   only when there is a fact the tool card does not already carry. The card
///   already renders `$ update_scratchpad → ok`, so "it worked" is not news.
///
/// A plain confirmation is therefore emitted NOWHERE. The tool's own envelope
/// (`{ok:true, data:{updated:true, content_length:N}}`) already states it, and an
/// app-authored `.user` turn on every scratchpad write — forever, for a manager
/// that wakes on a schedule — buys nothing and costs a turn.
///
/// The retired turn was doing two jobs, and only one of them was real:
///
/// - **Confirmation** ("Plan updated") — already in the tool envelope, so it was
///   never worth a turn to anybody.
/// - **Direction** ("Continue with the next step") — genuinely load-bearing for
///   the planning role, which `implementationSeedTurn` puts on a per-step
///   scratchpad cadence. Removing it without replacement would have left that
///   role's newest instruction pointing at work it had just finished.
///
/// So the direction did not disappear: it moved into `implementationSeedTurn`,
/// which now states the loop rather than "step 1" and therefore stays true after
/// every write. One durable sentence replaces one turn per step.
///
/// (An earlier version of this comment claimed the planning role "never received"
/// the directive because the boundary discarded it. That is false and worth
/// recording: the boundary REMOVES the brief, so every post-boundary write had
/// `isMidPlanning == false` and got the generic wording, which nothing then
/// sliced. The planning role was the directive's heaviest consumer, not its
/// exception.)
///
/// `nonisolated` because the app target defaults types to `@MainActor`; everything
/// here is value-in/value-out.
nonisolated enum ScratchpadNotePolicy {

    /// What became of the Autovisor's standing memory on this write.
    ///
    /// The manager's scratchpad IS its memory: `processScratchpadResult` writes it
    /// through to `settings.autovisorMemory`, which is the only state that survives
    /// a fresh run. The tool handler runs detached and knows nothing about that
    /// write, so its envelope cannot report this — which is why these three states
    /// are worth distinguishing at all.
    enum MemoryOutcome: Equatable {
        /// Written through to folder settings.
        case persisted
        /// The settings write failed. `processScratchpadResult` has ALREADY told
        /// the model and the Supervisor via a `.runtimeWarning`.
        case writeFailed
        /// Blank content: the step's scratchpad was cleared, but the standing
        /// memory was deliberately left untouched (a stray empty call must not
        /// destroy the manager's only cross-run state — see
        /// `ToolResultSideEffectsCornerTests`). The model asked for something the
        /// app declined to do, so it has to be told.
        case clearedWithoutPersisting
    }

    /// Who wrote the scratchpad. The associated value makes the illegal
    /// combinations unrepresentable — a memory outcome belongs to the manager and
    /// to nobody else.
    ///
    /// `autovisorMemory` and `planningPhase` are mutually exclusive by
    /// construction: `PlanningPhasePolicy.isEligible` carries `!isAutovisor`, so
    /// the manager can never be mid-planning. The call site still classifies the
    /// manager FIRST — role identity is the stronger fact, and the planning
    /// wording would promise a boundary that structurally cannot fire for it.
    enum Writer: Equatable {
        case planningPhase
        case autovisorMemory(MemoryOutcome)
        case ordinaryRole
    }

    // MARK: - Surfaces

    /// The `system: note` for the activity feed. `nil` = emit nothing.
    ///
    /// Second person is deliberate: the feed renders the ROLE's conversation, so
    /// the note reads as the app addressing that role, which is how the
    /// Supervisor reads every other notice in the same column.
    static func note(for writer: Writer) -> String? {
        switch writer {
        case .planningPhase:
            // Explains why the next bubble looks like a brand-new conversation.
            return "Planning notes recorded. The implementation phase starts on your next turn, "
                + "in a fresh conversation seeded with these notes."

        case .autovisorMemory(.persisted):
            // The write-through is the one fact the tool card cannot carry.
            return "Memory recorded — it will be in your prompt next pass."

        case .autovisorMemory(.writeFailed):
            // The `.runtimeWarning` already said it, on both surfaces. A second
            // note here is the "two adjacent turns with opposite readings" defect
            // this file exists to remove, not a reassurance.
            return nil

        case .autovisorMemory(.clearedWithoutPersisting):
            return Self.memoryUnchanged

        case .ordinaryRole:
            // The tool card already says `→ ok`. Nothing to add.
            return nil
        }
    }

    /// The turn that must reach the MODEL. `nil` = emit nothing.
    ///
    /// Non-nil for exactly one case: the app declined to clear the standing memory.
    /// Without it the manager believes it wiped its memory, then meets the old text
    /// in its prompt next pass with nothing anywhere explaining why. (The write
    /// FAILURE reaches the model too, but through the `.runtimeWarning` that
    /// `processScratchpadResult` emits directly — it carries the retry instruction
    /// this function has no business duplicating.)
    static func wireMessage(for writer: Writer) -> String? {
        switch writer {
        case .autovisorMemory(.clearedWithoutPersisting):
            return Self.memoryUnchanged
        case .planningPhase, .ordinaryRole,
             .autovisorMemory(.persisted), .autovisorMemory(.writeFailed):
            return nil
        }
    }

    /// One text, both surfaces: the model must act on it and the Supervisor must
    /// see the same thing the model was told.
    private static let memoryUnchanged =
        "Scratchpad cleared, but your standing memory is unchanged — a blank update never "
        + "overwrites it. Send the new state to replace it."
}
