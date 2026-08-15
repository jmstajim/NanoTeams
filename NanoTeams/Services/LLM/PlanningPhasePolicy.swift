import Foundation

/// Pure decisions for a role step's optional **planning phase**: the opening
/// stretch where the role may read the work folder, and which it ends by
/// recording what it found with `update_scratchpad`. The implementation phase
/// then starts on a FRESH wire conversation seeded with exactly those notes.
///
/// An earlier one-shot design of this phase swapped the `.system` message for a
/// dedicated planning prompt and narrowed the tool array to
/// `update_scratchpad`. Two problems with that shape:
///
/// 1. **It broke the prompt-prefix cache.** The tool catalog is rendered INTO
///    the system prompt (`NativeLMStudioClient.buildToolSchemaSection`, the
///    SSOT for both providers), so swapping the prompt changed the very first
///    bytes of every request and forced a full re-prefill at the phase
///    boundary. Both providers are stateless now — a byte-stable prefix is the
///    only speed lever there is.
/// 2. **It could not survive reading.** With only `update_scratchpad` offered,
///    a plan was made blind to the code it planned against.
///
/// The new shape keeps the system prompt untouched in BOTH phases, puts the
/// brief on the wire as a trailing `.user` turn, and enforces the phase at the
/// runtime authorization layer (`allowedToolNames`) — the two-layer contract
/// this codebase already uses for hallucinated tools.
///
/// **State is derived from the wire array plus the step snapshot, never stored.**
/// `StepExecutionState` is in-memory and rebuilt on every entry, so a stored
/// flag would disagree with a replayed `wireTranscript` after a pause or a
/// Supervisor round-trip. Deriving makes re-entry idempotent for free: the
/// brief is appended only when the wire does not already carry it, and the
/// boundary can only fire while the brief is still there — and it removes it.
///
/// `nonisolated` is required (the app target defaults types to `@MainActor`);
/// everything here is value-in/value-out so it composes from any context,
/// tests included. The @MainActor I/O lives in
/// `LLMExecutionService+PlanningPhase`.
nonisolated enum PlanningPhasePolicy {

    // MARK: - Markers
    //
    // The brief and the seed turn are identified by their headers rather than by
    // a flag, so detection works identically on a live array and on one replayed
    // from `wireTranscript`.

    static let briefMarker = "## Planning phase"
    static let seedMarker = "## Plan from your notes"
    /// Rides inside `planningClosedTurn`. Makes the close TERMINAL and idempotent, on the same
    /// derived-from-the-wire principle as the two above — see `isMidPlanning`.
    static let closedMarker = "## Planning phase closed"

    /// Pre-rename spellings, matched on READ only and never written.
    ///
    /// The phase was briefly called "research" (1.7.3–1.7.5). A step suspended mid-phase under
    /// one of those builds has the old header inside its persisted `wireTranscript`, and phase
    /// state is derived from the wire — so without these the matchers read "phase not started"
    /// on resume, `decide` returns `.enterPlanning`, and a SECOND brief is appended. The boundary
    /// would then slice at the new brief, leaving the whole exploration transcript in the
    /// implementation wire that this phase exists to keep it out of. Nothing goes red; the
    /// failure is silent and only at runtime.
    ///
    /// `seedMarker` needs no counterpart: it is written and never matched.
    private static let legacyBriefMarker = "## Research phase"
    private static let legacyClosedMarker = "## Research phase closed"

    // MARK: - Eligibility

    /// Whether this step should be in the planning phase at all.
    ///
    /// `hasNoRecentCalls` — which the old `isFirstIteration` ANDed in — is
    /// deliberately gone. It meant "no tool has executed yet", which was a fine
    /// proxy while the phase was a single `update_scratchpad` call, and is
    /// exactly wrong for a phase whose whole point is to read things first: the
    /// model's first `read_file` would have ejected it on iteration 2.
    /// `scratchpadIsNil` is the correct within-step signal.
    ///
    /// The two re-entry guards keep their original job. Both matter for the
    /// same reason: entering the phase writes the display record, and a step
    /// resuming after a Supervisor answer or a revision must not be treated as
    /// fresh.
    ///
    /// `supervisorAnswerIsNil` deliberately reads the ANSWER, not
    /// `supervisorAnswerPendingDelivery`. The question here is "has this step ever been
    /// through a Supervisor round-trip", and a delivered answer still means yes — a sweep
    /// that swapped this for the delivery flag would re-open the planning phase on a step
    /// resuming mid-work and hand it back its opening brief.
    static func isEligible(
        scratchpadIsNil: Bool,
        revisionCommentIsNil: Bool,
        supervisorAnswerIsNil: Bool,
        usesPlanningPhase: Bool,
        hasScratchpadTool: Bool,
        isAutovisor: Bool
    ) -> Bool {
        usesPlanningPhase
            && hasScratchpadTool
            && !isAutovisor
            && scratchpadIsNil
            && revisionCommentIsNil
            && supervisorAnswerIsNil
    }

    /// Whether the step's display record should be seeded on this iteration.
    /// Only a genuinely fresh step with nothing persisted yet — a re-entering
    /// one already has its conversation on disk, and `saveLLMConversation`
    /// REPLACES the array wholesale.
    static func isFreshStepSave(
        scratchpadIsNil: Bool,
        revisionCommentIsNil: Bool,
        supervisorAnswerIsNil: Bool,
        hasPriorConversation: Bool
    ) -> Bool {
        scratchpadIsNil && revisionCommentIsNil && supervisorAnswerIsNil && !hasPriorConversation
    }

    // MARK: - Wire inspection

    /// Index of the planning brief, or `nil`. The FIRST occurrence: a wire that
    /// somehow carries two can then only ever shrink at the boundary.
    ///
    /// Accepts the legacy header too, so a conversation replayed from a pre-rename
    /// `wireTranscript` is still recognised as mid-phase.
    static func briefIndex(in messages: [ChatMessage]) -> Int? {
        messages.firstIndex { message in
            guard message.role == .user, let content = message.content else { return false }
            return content.contains(briefMarker) || content.contains(legacyBriefMarker)
        }
    }

    static func wireCarriesBrief(_ messages: [ChatMessage]) -> Bool {
        briefIndex(in: messages) != nil
    }

    static func wireCarriesClosedMarker(_ messages: [ChatMessage]) -> Bool {
        messages.contains { message in
            guard message.role == .user, let content = message.content else { return false }
            return content.contains(closedMarker) || content.contains(legacyClosedMarker)
        }
    }

    /// **The single predicate for "this step is still in the planning phase."**
    ///
    /// Not `wireCarriesBrief`. `.closeWithoutRebuild` retires the brief's INSTRUCTION by
    /// appending a closing turn, but deliberately leaves the brief itself on the wire — removing
    /// it would be a mid-array delete, and the whole point of that branch is not to rebuild. So
    /// the brief stays true forever after a close, and anything keyed on it alone gets three
    /// things wrong:
    ///
    ///  1. `decide` keeps returning `.closeWithoutRebuild`, re-appending an identical closing
    ///     turn on every iteration — unbounded prompt growth from a duplicated message.
    ///  2. If the model later records a plan (the prose fallback in `handleNoToolCalls` will do
    ///     it for them), `decide` reaches `.crossBoundary` and the slice drops everything after
    ///     the brief — including the revision-feedback turn that `.closeWithoutRebuild` existed
    ///     to protect. The branch was a one-iteration reprieve, not a fix.
    ///  3. The queued-Supervisor gate and the `update_scratchpad` acknowledgement both read the
    ///     phase state; keyed on the brief they would defer messages forever and promise a fresh
    ///     conversation that will never arrive.
    ///
    /// Derived from the wire, never stored, so it survives a replay from `wireTranscript`
    /// unchanged.
    static func isMidPlanning(_ messages: [ChatMessage]) -> Bool {
        wireCarriesBrief(messages) && !wireCarriesClosedMarker(messages)
    }

    /// Human-originated turns that the boundary is about to DISCARD, so the caller can put them
    /// back on the Supervisor queue instead of losing them.
    ///
    /// A queued Supervisor message is delivered immediately, mid-planning included — steering the
    /// exploration is exactly what it is for. But it is neither the task statement nor the
    /// scratchpad, so it does not survive the boundary, and `consumeQueuedSupervisorMessage` has
    /// already popped it. Returning it here is what makes immediate delivery safe.
    ///
    /// Identified by `MessageSourceContext.supervisorMessagePrefix`, the marker the consumption
    /// pipeline already puts on the wire — derived from the wire like every other phase signal,
    /// so it survives a replay from `wireTranscript`. The prefix is stripped: the caller re-queues
    /// the user's own text, and the pipeline re-applies attribution on redelivery.
    ///
    /// A predecessor `durableTurnInsertionIndex` tried to solve this by INSERTING such turns ahead
    /// of the brief. It had zero production callers and its documented invariant was never
    /// implemented — and it was the wrong shape anyway: an insert ahead of the tail is the single
    /// most expensive mutation available. LM Studio joins the whole conversation into ONE `input`
    /// string, so the prefix diverges at the insertion offset; Ollama merges consecutive user-side
    /// turns, so inserting inside an earlier run rewrites a message that already has an assistant
    /// turn after it — the precise case that makes the merge unsafe. Append-and-requeue keeps
    /// every mutation at `count` (pinned by `PromptPrefixWireParityTests` and
    /// `ConversationAppendInvariantTests`).
    static func discardedSupervisorMessages(in wire: [ChatMessage]) -> [String] {
        guard let index = briefIndex(in: wire) else { return [] }
        let prefix = MessageSourceContext.supervisorMessagePrefix
        return wire[index...].compactMap { message in
            guard message.role == .user, let content = message.content,
                  content.hasPrefix(prefix)
            else { return nil }
            return String(content.dropFirst(prefix.count))
        }
    }

    // MARK: - Decision

    enum Decision: Equatable {
        /// Append the brief; authorize the planning toolset.
        case enterPlanning
        /// Brief already on the wire, plan not yet recorded.
        case continuePlanning
        /// The plan is in. Rebuild the wire and authorize everything.
        case crossBoundary
        /// A revision arrived mid-planning with no plan recorded. Rebuilding
        /// would drop the turn the engine just appended, so only retire the
        /// brief's instruction.
        case closeWithoutRebuild
        /// Ordinary operation — no phase, or already past it.
        case execution
    }

    /// Exhaustive over the four inputs. Note `isEligible ⟹ scratchpadIsNil`,
    /// so the `(true, _, _, false)` rows are unreachable by construction.
    ///
    /// `wireCarriesClosedMarker` dominates everything below eligibility: once the phase has been
    /// closed it is closed for good, regardless of the brief still sitting on the wire. That is
    /// what makes `.closeWithoutRebuild` fire exactly once and what makes a later
    /// `.crossBoundary` — which would slice away the turn the close was protecting —
    /// unreachable. See `isMidPlanning`.
    static func decide(
        isEligible: Bool,
        wireCarriesBrief: Bool,
        scratchpadIsNil: Bool,
        wireCarriesClosedMarker: Bool = false
    ) -> Decision {
        if isEligible {
            return wireCarriesBrief ? .continuePlanning : .enterPlanning
        }
        guard wireCarriesBrief, !wireCarriesClosedMarker else { return .execution }
        return scratchpadIsNil ? .closeWithoutRebuild : .crossBoundary
    }

    // MARK: - Authorization

    /// What may execute this iteration, and what the PHASE (as opposed to a
    /// work-folder precondition) is holding back.
    struct Authorization: Equatable {
        let allowed: Set<String>
        /// Tools the role has, that this iteration refuses. Empty outside the
        /// planning phase.
        let withheldByPhase: Set<String>
        /// Whether this iteration IS the planning phase. Threaded down to the tool layer
        /// (`ToolExecutionContext.isPlanningPhase`) so `BashTool` can narrow its sandbox per
        /// call, and to the bash gate so the judge is told the confinement actually in force.
        ///
        /// Carried EXPLICITLY, never inferred from `withheldByPhase.isEmpty`. A role whose whole
        /// toolset already sits inside the planning set — file+git reads, the Xcode runners,
        /// `bash`, `update_scratchpad`, i.e. an ordinary "investigator" configuration — withholds
        /// nothing, so that inference reads "not planning" and hands exactly that role an
        /// UNNARROWED bash for the entire phase. It fails precisely where the guarantee matters.
        /// `allowed.isEmpty` fails the same way from the other side.
        let isPlanningPhase: Bool

        static func unrestricted(_ tools: [ToolSchema]) -> Authorization {
            Authorization(
                allowed: Set(tools.map(\.name)), withheldByPhase: [], isPlanningPhase: false)
        }
    }

    /// Everything whose worst case the boundary can absorb, plus the phase's exit channel:
    /// read-only file+git, vision, the Xcode runners, and — when `bashAdmitted` — `bash`.
    ///
    /// **The criterion, as two properties.** A tool belongs iff
    ///
    ///  1. **it cannot put a turn on the wire that the boundary destroys unrecoverably**, and
    ///  2. **it cannot mutate work-folder source** — either because it structurally does not
    ///     write, or because the KERNEL is stopping it for the duration of the phase.
    ///
    /// Those properties, not the enumeration, are what make the boundary safe by construction.
    /// Judge a new candidate by them, never by category name.
    ///
    /// **Property 1 used to read "cannot SUSPEND the step". That was a proxy, and the wrong
    /// one** — what breaks the boundary is a STATE TRANSITION, not a suspension.
    /// `ask_supervisor` is the specimen: it parks the step at `.needsSupervisorInput`, the answer
    /// returns as a HUMAN turn after the brief, and `isEligible`'s `supervisorAnswerIsNil` guard
    /// then makes the step ineligible — so the next `decide` returns `.closeWithoutRebuild` and
    /// the exploration transcript this phase exists to discard is KEPT instead. `bash`'s human
    /// approval hold (`awaitBashApproval`) blocks just as long and does none of that: it appends
    /// nothing to `conversationMessages`, parks nothing, writes no step field, and a Pause
    /// resolves it `.deny`, which lands as an ordinary tool-error envelope in the same batch.
    /// Every input `decide` reads is byte-identical across the hold, so re-entry is
    /// `.continuePlanning` either way — the hold is a wall-clock cost, not a phase event.
    /// Engine-authored turns are fine for the reason that admitted the Xcode runners: a failed
    /// build appends one `ToolErrorNotePolicy.direction` `.user` turn, the same shape as a failed
    /// `read_file`. The turns the slice must not eat are HUMAN ones — that is what
    /// `discardedSupervisorMessages` exists for.
    ///
    /// **Property 2 is why `bash` is here, and why it is CONDITIONAL.** `bash` cannot be argued
    /// safe by inspecting the command: `BashConstants.readOnlyPrograms` is a 60-name allowlist
    /// that omits `find`, `git` and `python` while admitting `command` (so `command rm -rf x`
    /// reads as read-only) and `yq` (which has an in-place `-i`). Fine as a basis for skipping a
    /// review prompt; hopeless as a boundary invariant. The enforcement is the SANDBOX: while
    /// the phase is live `BashTool` rebuilds its Seatbelt profile from the user's own
    /// `BashSandboxPermissions` with every write scope forced off (`withWritesDisabled()`), so
    /// the write clause carries only dev-node literals and `(deny default)` refuses every real
    /// filesystem write. Reads are untouched — the phase exists to read. A kernel guarantee, not
    /// a guess about a program's name.
    ///
    /// **`bashAdmitted` is the caller's two-term test, and both terms are about the phase.**
    /// (a) `BashPolicy.sandboxEnabled` — no sandbox, no property 2, so nothing to advertise.
    /// (b) `BashExecutionMode.allowsUnattendedCommands` — under `.manual` every command routes
    /// to a human above the read-only bypass, turning a fast fact-gathering stretch into a
    /// per-command approval queue (and, with no human present, into a wall of denials).
    /// Both leave `plan_required` TRUE: after the boundary the same command runs under the
    /// user's own settings. That is the admission test for anything folded in here — **only a
    /// condition the BOUNDARY ITSELF resolves may narrow this set**, because `plan_required`
    /// promises exactly that. `BashPolicy.mode == .off` fails that test (recording a plan does
    /// not re-enable a disabled tool), which is why it is NOT expressed here as a withholding
    /// but by `ToolUnavailabilityReason.bashDisabled`, whose contract is "stop", not "retry".
    ///
    /// **`bash_output` is deliberately absent.** Its only producer is `bash` with
    /// `run_in_background: true`, which the handler refuses during the phase — a detached
    /// process keeps the profile it was launched with forever, so one started here would carry
    /// the write-blocked sandbox across the boundary and past it, unfixable. What would be left
    /// for `bash_output` to address are ids from other steps of the same task (the registry is
    /// task-scoped), where `action: "stop"` is an irreversible side effect whose only record
    /// dies at the boundary — property 1's spirit and property 2's letter.
    ///
    /// Intersected with the tools actually PASSED IN — which arrive already
    /// filtered by work-folder preconditions — so `withheldByPhase` means
    /// exactly "the phase withheld it" and never "a precondition stripped it".
    /// That is what lets the rejection envelope be honest without ordering hacks,
    /// and it keeps the brief from advertising `git_log` in a folder with no git.
    /// It is also why a folder with no selected Xcode scheme still answers
    /// `.xcodeSchemeNotSelected` rather than `plan_required`: step 3.1 of
    /// `resolveToolSchemasCore` already removed the runners, so they reach neither
    /// `allowed` nor `withheldByPhase`.
    static func planningToolNames(in tools: [ToolSchema], bashAdmitted: Bool) -> Set<String> {
        var planningTools = ToolHandlerRegistry.readOnlyTools
            .union(ToolHandlerRegistry.visionTools)
            .union(ToolHandlerRegistry.xcodeTools)
            .union([ToolNames.updateScratchpad])
        if bashAdmitted { planningTools.insert(ToolNames.bash) }
        return Set(tools.map(\.name)).intersection(planningTools)
    }

    static func authorization(
        for decision: Decision, tools: [ToolSchema], bashAdmitted: Bool
    ) -> Authorization {
        switch decision {
        case .enterPlanning, .continuePlanning:
            let all = Set(tools.map(\.name))
            let allowed = planningToolNames(in: tools, bashAdmitted: bashAdmitted)
            return Authorization(
                allowed: allowed, withheldByPhase: all.subtracting(allowed), isPlanningPhase: true)
        case .crossBoundary, .closeWithoutRebuild, .execution:
            return .unrestricted(tools)
        }
    }

    static func hasScratchpadTool(in tools: [ToolSchema]) -> Bool {
        tools.contains { $0.name == ToolNames.updateScratchpad }
    }

    // MARK: - Wire composition

    /// The implementation phase's wire: everything BEFORE the brief, plus the
    /// seed turn.
    ///
    /// A slice, never a fresh `PromptBuilder.buildChatMessages`. Re-rendering
    /// would read live task state that has moved since the step started —
    /// sibling step statuses, artifacts produced after t0, and for the Autovisor
    /// the system prompt itself — producing different bytes and so a guaranteed
    /// prefix miss, which is the exact cost this whole phase exists to avoid.
    /// Slicing the array that already went over the wire is byte-exact by
    /// construction and cannot drift.
    static func implementationWire(
        from wire: [ChatMessage],
        seedTurn: String
    ) -> [ChatMessage] {
        guard let index = briefIndex(in: wire) else { return wire }
        return Array(wire[..<index]) + [ChatMessage(role: .user, content: seedTurn)]
    }

    // MARK: - Prompt text

    /// The planning brief, appended as a trailing `.user` turn on the WIRE only.
    ///
    /// It lists the tools that actually run this phase, because the system
    /// prompt still advertises the FULL catalog: with the swap gone, nothing
    /// else tells the model what is live, and advertise-then-reject burns turns
    /// on denials. The list is the honest catalog for the phase.
    ///
    /// Sorted for byte determinism (the prefix cache keys on exact bytes).
    static func planningBrief(
        exploreToolNames: [String],
        expectedArtifacts: [String]
    ) -> String {
        var block = briefMarker + "\n"
        block += "Ground your plan in the current state of the work folder.\n"

        let explore = exploreToolNames
            .filter { $0 != ToolNames.updateScratchpad }
            .sorted()
        if !explore.isEmpty {
            block += "These tools run right now: \(explore.joined(separator: ", ")).\n"
        }
        // Annotated on its OWN line rather than as a parenthetical inside the comma list. The
        // list is sorted for byte determinism and reads to a 7–32B model as a set of NAMES; a
        // parenthetical inside it is the shape those models copy into their arguments. Keyed on
        // membership, so a role without `bash` gets a brief byte-identical to the one it got
        // before this line existed. The claim holds under EVERY permission configuration
        // because `withWritesDisabled()` clears the work-folder grant unconditionally; temp is
        // deliberately not mentioned, which would both over-promise and invite scratch files.
        if explore.contains(ToolNames.bash) {
            block += "bash runs read-only in this phase: the sandbox blocks it from writing to "
                + "the work folder until your plan is recorded. Use it to look, not to change.\n"
        }

        block += "\nRecord what you find by calling update_scratchpad with two sections:\n"
        block += "1. Findings — the files, symbols and constraints your plan depends on, "
            + "each with its path.\n"
        block += "2. Plan — a numbered list of the concrete steps you will take.\n"

        if !expectedArtifacts.isEmpty {
            let quoted = expectedArtifacts.map { "\"\($0)\"" }.joined(separator: ", ")
            block += "\nYour plan must end with producing: \(quoted).\n"
        }

        block += "\nYour remaining tools unlock the moment those notes are recorded. "
        block += "That update_scratchpad call ends this phase and starts the implementation "
        block += "phase in a fresh conversation seeded with exactly these notes — write them "
        block += "so they stand alone."
        return block
    }

    /// First turn of the implementation phase's fresh wire.
    ///
    /// Carries the notes verbatim because they are the ONLY thing that survives
    /// the boundary: `step.scratchpad` is never injected by `PromptBuilder`, so
    /// without this turn the model would wake with no record of its own reading.
    static func implementationSeedTurn(notes: String, expectedArtifacts: [String]) -> String {
        var block = seedMarker + "\n"
        block += notes.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        // SELF-RENEWING on purpose: it must still be actionable after the role marks a step
        // complete, because nothing else speaks after a scratchpad write. "Execute step 1" was
        // true exactly once — every later write left the newest instruction on the wire pointing
        // at work already done, and the gap was covered by a per-write "Continue with the next
        // step." turn appended to EVERY role's conversation. One durable sentence here replaces
        // N of those.
        block += "Implementation phase — your full toolset is available now. Work the plan one "
        block += "step at a time: execute the first step that is not yet struck through, then "
        block += "call update_scratchpad to mark it complete with ~~strikethrough~~. Repeat "
        block += "until every step is struck through."
        if !expectedArtifacts.isEmpty {
            let quoted = expectedArtifacts.map { "\"\($0)\"" }.joined(separator: ", ")
            block += "\nSubmit via create_artifact when ready: \(quoted)."
        }
        return block
    }

    /// Retires the brief's instruction when a revision arrives mid-planning.
    ///
    /// Carries `closedMarker` so the close is TERMINAL: `decide` reads it back off the wire and
    /// never re-enters the phase, which makes this append idempotent and keeps a later boundary
    /// from slicing away the very turn this branch was protecting.
    static let planningClosedTurn =
        closedMarker + " — your full toolset is available now. "
        + "Act on the message above."

    // The acknowledgement for a successful `update_scratchpad` used to live here,
    // choosing between a planning wording and a generic one. It moved to
    // `ScratchpadNotePolicy`: the phase is only one of three writers, and the
    // wording is now display-only for ALL of them — a property that file makes
    // structural rather than incidental.
}
