import Foundation

// MARK: - Message Source Context

/// Context indicating how an injected message was produced.
///
/// `CaseIterable` is load-bearing for presentation policies that classify a
/// SUBSET of contexts (today: `SystemNoticePresentation`, which collapses the
/// system-authored ones into a one-line feed row). Their truth-table tests
/// iterate `allCases`, so a context added later is automatically asserted to
/// fall on the default side rather than being silently missed by a
/// hand-maintained list.
nonisolated enum MessageSourceContext: String, Codable, CaseIterable {
    case consultation
    case meeting
    case changeRequest
    case supervisorAnswer
    /// Unsolicited Supervisor message injected mid-iteration from the queued-chat
    /// pipeline (see `NTMSOrchestrator.consumeQueuedSupervisorMessage`). Distinct
    /// from `.supervisorAnswer` — those are paired with `ask_supervisor` tool calls
    /// and rendered separately by `ActivityFeedBuilder`.
    case supervisorMessage
    /// Question that arrived from a delegated child team's `ask_supervisor` call
    /// while this role's `delegate_to_team` handler was awaiting completion. The
    /// question is appended to this role's `step.llmConversation` for activity-feed
    /// visibility; the actual answering happens in
    /// `DelegatedSupervisorAnswerService`, which seeds a one-shot side exchange
    /// from that same conversation.
    case delegatedQuestion
    /// Question that bubbled up the delegation chain (a delegated team's role asked
    /// `ask_supervisor`, the immediate parent role couldn't answer and itself called
    /// `ask_supervisor`, escalating to its own supervisor). Tagged so the activity
    /// feed of each ancestor can show the escalation chain.
    case delegationEscalation
    /// Transient retry-status note written while a recoverable LLM error keeps
    /// retrying (server unreachable, 5xx, …). Rendered as a red error bubble in the
    /// activity feed and collapsed in place across attempts (see
    /// `TaskMutationService.appendOrReplaceRetryNotice`). Display-only — never sent
    /// to the model.
    case serverError
    /// Correction appended after an in-stream thinking loop broke the stream and the
    /// looping generation was discarded (`LoopRecoveryPolicy.retryWithNudge`).
    /// Unlike `.serverError` this one IS sent — it is the entire recovery, since a
    /// stateless resend without it is byte-identical to the request that looped. The
    /// context exists so the turn survives the activity feed's `.user`-with-no-context
    /// filter; without it the only record of a loop break would be a `cancelled` row
    /// in `network_log.json`, which is off by default in Release.
    case loopCorrection
    /// A retry nudge the runtime appended after a turn produced no usable tool call —
    /// the drift reminder, the repetition warning, the malformed-envelope retry, the
    /// missing-artifacts reminder, the planning-phase plan note, the generic
    /// "you replied with text" nudge. Like `.loopCorrection` these ARE sent; the context
    /// exists so they survive the activity feed's `.user`-with-no-context filter.
    ///
    /// Without it the user watches a role emit the same reply N times with nothing on
    /// screen explaining why it is being asked again — which is exactly how the wedged
    /// Autovisor pass presented: identical bubbles, no visible cause. A nudge is the
    /// app talking to the model on the user's behalf, so it belongs on the record.
    ///
    /// Deliberately NOT `.loopCorrection`: that one means "the stream looped and was
    /// discarded", and labelling a tokens-only retry with it would be a new lie.
    ///
    /// **NOT carried by the recovery steering appended after a tool call FAILED**
    /// (`ToolErrorNotePolicy`), which it briefly was. Same act — the runtime telling the
    /// model its attempt did not land — but a different answer to the question above,
    /// because that steering comments on ONE event the feed already draws: the failed
    /// call's own card. Every arm that still emits is a constant keyed on the error code —
    /// one sentence per CODE, spent per INCIDENT — so the row said the same thing under
    /// every red arrow. That is also why the card stopped rendering the reason inline: the
    /// full envelope opens on tap instead, and neither surface pays for a constant twice.
    /// The turn is persisted unattributed, behind a `feed-invisible-by-design:` note at its
    /// call site.
    ///
    /// So the discriminator for this context is ORIGIN, not "is the runtime speaking":
    /// does the turn comment on something already on screen? The nudges above follow a
    /// BARE assistant turn and the loop warning spans SEVERAL cards — nothing else records
    /// either, which is what makes their rows the whole point.
    case retryNudge
    /// The runtime's acknowledgement of a tool call that SUCCEEDED — today the
    /// `update_scratchpad` note, composed by `ScratchpadNotePolicy`.
    ///
    /// **Display-only, and no longer emitted on every write.** It used to ship on the wire too,
    /// carrying a "continue with the next step" directive; both halves are gone. The note now
    /// appears only when there is a fact the tool card's `→ ok` cannot carry — the Autovisor's
    /// memory write-through, or the planning phase's fresh-conversation boundary. The one
    /// remaining model-facing turn on that path (the manager's blank write, which does NOT clear
    /// standing memory) is appended to the wire untagged, so a turn carrying THIS context was
    /// never sent.
    ///
    /// Deliberately NOT `.retryNudge`: nothing went wrong, and mislabelling it "retry" would be
    /// the same kind of new lie that keeps `.loopCorrection` off the nudges. Its own doc comment
    /// has claimed since it was written that it "exists so the activity feed reads coherently";
    /// without a context it never reached the feed at all.
    case toolAcknowledgement
    /// A failure in the APP'S OWN work that the model has to know about, raised while servicing
    /// a call the model made — today the Autovisor's memory-write-to-disk failure.
    ///
    /// Not `.serverError`: that one is display-only and rewritten in place across retry
    /// attempts, whereas this warning really is sent. It is the one runtime-authored context
    /// that renders RED, because the remedy (a full disk, a permissions problem) belongs to the
    /// human reading the feed, not to the model reading the turn.
    case runtimeWarning
    /// The app's own notice that folder state moved WHILE the Autovisor manager was
    /// mid-review — composed by `NTMSOrchestrator.composeAutovisorEventNotice` and injected
    /// into the live pass through the queued-message pipeline.
    ///
    /// Split off from `.supervisorMessage`, which it used to borrow, and the split is the
    /// whole point: that context means a Supervisor SPOKE (a human steering the run, or the
    /// automated Supervisor's own `message_task`), and wearing it made the app's bookkeeping
    /// render as a crowned Supervisor bubble the human never typed. Both still ride the same
    /// queue — `QueuedChatMessage.Kind` is what the drain reads to tell them apart.
    ///
    /// The one system-authored context that is `carriesUnsolicitedInformation` — see there
    /// for why it does not self-immunize the way `.toolAcknowledgement` does.
    ///
    /// Sent to the model UNMARKED, like every other system notice: no `Supervisor:` badge, no
    /// delimiters. What identifies it on a flattened wire is its own opening line, which is
    /// why that line is a shared constant (``autovisorEventNoticeHeader``) rather than a
    /// literal at the compose site.
    case autovisorEvent
    /// Text description of a screenshot, produced by the Vision model for a main model that
    /// cannot see images (`+ComputerUse`'s describe-then-tell path).
    ///
    /// Ordinary CONTENT rather than a system notice — it is the only record of what the model
    /// was actually shown, so it renders as a normal bubble instead of a one-line row.
    case screenDescription

    /// Did this turn PUSH information at the model that no tool call of its own asked for?
    ///
    /// The loop detectors treat such a turn as an INFORMATION BOUNDARY: a repeat the model
    /// returns to after being told something is a reaction, a repeat with nothing between is
    /// a loop. The in-step half marks it on the next tracked call
    /// (`ToolCallTracker.TrackedCall.informationEpoch`); the committed half folds its
    /// timestamp into the tool-call scan's cutoff (`LoopScanner.scanCommitted`). Without it,
    /// the prescribed reaction to being told a task changed — re-checking it — read as
    /// "identical arguments N times and the state isn't changing" one turn after the model
    /// was told the state changed.
    ///
    /// **The discriminator is UNSOLICITED, not "the world moved".** Two contexts qualify, and
    /// both arrive through the queued-message pipeline: `.supervisorMessage` — a queued
    /// Supervisor turn (human steering, `message_task`) or a parent role's `forward_to_team`
    /// injected into a child — and `.autovisorEvent`, the app's mid-review notice that folder
    /// state moved while the manager was reviewing. Nobody in the conversation asked for
    /// either.
    ///
    /// `.autovisorEvent` is the one SYSTEM-authored context on this side, and it does not
    /// self-immunize the way the others would: the app composes it from folder state on a
    /// cadence the manager does not control, so a manager spinning on `task_status` cannot
    /// manufacture a boundary by spinning. That is exactly the property the paragraph below
    /// demands of anything counted here, and exactly what `.toolAcknowledgement` and
    /// `.runtimeWarning` lack — each of those is stamped strictly after the call that
    /// produced it.
    ///
    /// Every other content-bearing context is the ANSWER TO A TOOL CALL THE MODEL MADE, and
    /// `commitCollaborationOutcome` / `recordAutoSupervisorAnswer` append it to the same
    /// step's conversation stamped strictly AFTER that call. Counting those would be
    /// self-immunizing: a model spinning on `ask_teammate` with identical arguments produces
    /// a fresh `.consultation` boundary with every repeat, the committed scan then drops
    /// every call before the newest one, and the trailing run is pinned at 1 — i.e. the
    /// detector could never fire again for `ask_teammate`, `request_team_meeting`,
    /// `request_changes` or an auto-answered `ask_supervisor`. Their own tool call already
    /// sits in the sequence; when the repeat is some OTHER tool it breaks the run there, and
    /// when the repeat IS that tool there is nothing to excuse.
    ///
    /// `.delegatedQuestion` / `.delegationEscalation` are excluded for the same reason from
    /// the other side: they are stamped into the PARENT's conversation by a delegated CHILD,
    /// at a cadence the parent does not control, and would mask a parent looping on
    /// `delegate_to_team`.
    ///
    /// **`.retryNudge` on the `false` side is load-bearing**: the repetition warning is
    /// persisted with exactly that context, so calling it unsolicited information would let
    /// the detector reset itself with its own warning — it would fire once and then never
    /// again for as long as the model kept looping.
    ///
    /// `.toolAcknowledgement` / `.runtimeWarning` / `.screenDescription` are `false` for the
    /// self-immunizing reason above: each is stamped strictly AFTER the call that produced it
    /// (`update_scratchpad`, `screen_capture`), so counting one would let a model spinning on
    /// that very tool refresh its own cutoff with every repeat.
    ///
    /// Exhaustive on purpose — no `default`. A context added later must be classified by
    /// whoever adds it; the compiler asks, because either answer is silently wrong for the
    /// other kind (a missed boundary blames the model for reacting to news; a spurious one
    /// lets a real spin run forever — and if it is spurious on a context the model itself
    /// produces, it disables the detector for that tool permanently).
    var carriesUnsolicitedInformation: Bool {
        switch self {
        case .supervisorMessage, .autovisorEvent:
            return true
        case .consultation, .meeting, .changeRequest, .supervisorAnswer,
             .delegatedQuestion, .delegationEscalation,
             .serverError, .loopCorrection, .retryNudge,
             .toolAcknowledgement, .runtimeWarning, .screenDescription:
            return false
        }
    }

    private static let displayLabelMap: [MessageSourceContext: String] = [
        .consultation: "consultation",
        .meeting: "meeting",
        .changeRequest: "change request",
        .supervisorAnswer: "supervisor answer",
        .supervisorMessage: "message",
        .delegatedQuestion: "delegated question",
        .delegationEscalation: "escalation",
        .loopCorrection: "loop correction",
        .retryNudge: "retry",
        .toolAcknowledgement: "note",
        .runtimeWarning: "warning",
        .autovisorEvent: "event",
        .screenDescription: "screen description",
    ]

    var displayLabel: String { Self.displayLabelMap[self] ?? rawValue }

    /// Shared attribution marker prepended to queued Supervisor turns. Single
    /// source of truth so the write side (`NTMSOrchestrator.consumeQueuedSupervisorMessage`)
    /// and the read side (`LLMMessage.displayContent`) can't drift on rename.
    static let supervisorMessagePrefix = "Supervisor:\n"

    /// Attribution marker prepended to supervisor ANSWER turns (`.supervisorAnswer`).
    /// Single source of truth across the write sides
    /// (`StepMessagingService.answerSupervisorQuestion`, the auto-answer append in
    /// `LLMExecutionService+ToolLoopState`, the stateless rebuild in `PromptBuilder`)
    /// and the read sides (`LLMMessage.displayContent`, the answered-notification
    /// extraction in `ActivityFeedBuilder.emitItems`).
    static let supervisorAnswerPrefix = "Supervisor answer: "

    /// Attribution marker for revision/correction feedback turns. `step.revisionComment`
    /// holds the RAW text; this prefix is attached exactly once where the feedback
    /// reaches the LLM — at the stateful send site (`LLMExecutionService+StepLifecycle`)
    /// or baked into the single `StepMessage` copy that the stateless rebuild relays
    /// (`PromptBuilder` reads `step.messages`). Single source of truth across the
    /// write sites (`requestRevision`, `correctRole`) and the send site.
    static let supervisorFeedbackPrefix = "Supervisor Feedback: "

    /// Delimiters wrapping a `.loopCorrection` turn (`LoopRecoveryPolicy.retryWithNudge`).
    ///
    /// **Wire-side purpose.** Both providers FLATTEN consecutive user-side turns into one
    /// message (`OllamaClient.buildRequest` joins them with a blank line; the LM Studio
    /// builder renders the same flat shape), and the correction is appended where the
    /// looping generation was DISCARDED — so nothing assistant-side separates it from the
    /// preceding `[Tool Result]` block and it would arrive as a trailing paragraph of that
    /// block rather than as a turn of its own. Delimiting in the TEXT fixes both providers
    /// at once; changing the merge would not — many chat templates render or drop
    /// consecutive user messages badly, and diverging the two wire builders is its own bug
    /// source. (No `handleNoToolCalls` nudge needs delimiters: each is appended
    /// AFTER `processStreamingResult` has committed the assistant turn, which separates them.)
    ///
    /// **Why they live here** rather than on the policy that writes them: they are a
    /// contract between a wire writer and a display reader — `displayContent` strips them
    /// so the feed's one-line row is the correction's opening sentence and not a decorative
    /// separator. One constant, both sides derived from it (CLAUDE.md #117); Domain cannot
    /// reach into `Services/` for the writer's copy. Same reason `supervisorMessagePrefix`
    /// and `supervisorAnswerPrefix` are here.
    ///
    /// The PERSISTED content keeps them: `ConversationReplay.rebuildFromDisplayRecord` reads
    /// the raw `content` and `.loopCorrection` is the one system notice that really was sent,
    /// so stripping at the write side would make the replayed wire diverge from the live one.
    static let loopCorrectionBlockOpen = "--- LOOP CORRECTION ---"
    static let loopCorrectionBlockClose = "--- END LOOP CORRECTION ---"

    /// Opening line of an `.autovisorEvent` notice
    /// (`NTMSOrchestrator.composeAutovisorEventNotice`).
    ///
    /// **Wire-side purpose.** The notice ships UNMARKED — no `Supervisor:` badge, matching
    /// every other system notice — and both providers flatten consecutive user-side turns,
    /// so this line is the only thing telling the manager where the app stopped relaying a
    /// human and started reporting folder state. It is not decoration and is never stripped
    /// from `content`: `ConversationReplay` replays the persisted text verbatim, and unlike
    /// `.serverError` this notice really was sent.
    ///
    /// **Display-side purpose.** `SystemNoticePresentation` skips it when building the
    /// collapsed row's one-line preview, so the glance shows the first bullet (what actually
    /// happened) instead of a banner the row's own `system: event` label already states.
    ///
    /// One constant, both sides derived from it (CLAUDE.md #117) — same reason
    /// `supervisorMessagePrefix` and the loop-correction delimiters live here rather than on
    /// the `Services/` type that writes them, which `Domain` cannot reach.
    static let autovisorEventNoticeHeader =
        "Event update while you are reviewing — new since this pass started:"

    /// Normalizes incoming feedback to its RAW form: trims whitespace and strips a
    /// leading ``supervisorFeedbackPrefix`` if the author already included one — the
    /// Autovisor's LLM sees the prefixed pattern in conversation history and can emit
    /// it inside the `comment` argument; legacy `revisionComment` values persisted by
    /// pre-fix builds carry it too. Idempotent, so every prefix-attaching site can
    /// apply it unconditionally without double-stripping user text.
    static func rawFeedback(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Match the marker without its trailing space: the outer trim can eat that
        // space when the prefix arrives bare ("Supervisor Feedback:"), and model
        // emissions sometimes omit it ("Supervisor Feedback:text").
        let bareMarker = supervisorFeedbackPrefix.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(bareMarker) else { return trimmed }
        return String(trimmed.dropFirst(bareMarker.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - LLM Role

/// OpenAI-compatible role for LLM conversation messages.
nonisolated enum LLMRole: String, Codable, Hashable {
    case system
    case user
    case assistant
    case tool
}

// MARK: - LLM Message

/// Represents a single message in the LLM conversation (full prompts sent to the model).
nonisolated struct LLMMessage: Codable, Identifiable, Hashable {
    var id: UUID
    var createdAt: Date
    var role: LLMRole
    var content: String
    /// Reasoning / thinking content from the LLM (e.g. reasoning_content from DeepSeek/QwQ).
    var thinking: String?
    /// The originating role for injected messages (e.g. teammate consultation responses).
    /// When set, views use this for avatar/title instead of inferring from ``role``.
    var sourceRole: Role?
    /// How this message was produced (consultation, meeting, etc.).
    var sourceContext: MessageSourceContext?

    enum CodingKeys: String, CodingKey {
        case id, createdAt, role, content, thinking, sourceRole, sourceContext
    }

    init(id: UUID = UUID(), createdAt: Date = MonotonicClock.shared.now(), role: LLMRole, content: String, thinking: String? = nil, sourceRole: Role? = nil, sourceContext: MessageSourceContext? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.role = role
        self.content = content
        self.thinking = thinking
        self.sourceRole = sourceRole
        self.sourceContext = sourceContext
    }

    /// Display label for the message's source context (e.g. "(consultation)", "(input)").
    /// Returns nil for regular assistant/system messages without special context.
    var sourceContextDisplayLabel: String? {
        // `.supervisorMessage` is rendered with bubble styling matching the
        // initial Supervisor task brief — the avatar + role name already convey
        // the context, so no secondary "(message)" label.
        if sourceContext == .supervisorMessage { return nil }
        // The red bubble + self-describing content already convey "server error";
        // a "(serverError)" label would be redundant noise.
        if sourceContext == .serverError { return nil }
        if let ctx = sourceContext { return ctx.displayLabel }
        if role == .user && sourceRole == nil { return "input" }
        if sourceRole != nil { return "consultation" }
        return nil
    }

    /// Content ready for rendering in the activity feed. For `.supervisorMessage`
    /// turns, strips the leading attribution marker (`MessageSourceContext.supervisorMessagePrefix`)
    /// — it's there so the LLM can identify the speaker when the turn lands in a
    /// combined `input` string alongside tool results and memory blocks, but the
    /// bubble already shows the role name above, so the prefix is redundant UI noise.
    ///
    /// Also accepts the legacy single-line `"Supervisor: "` form so messages
    /// persisted by earlier builds still render cleanly after upgrade.
    ///
    /// `.supervisorAnswer` turns strip `supervisorAnswerPrefix` the same way —
    /// unpaired answers (escalation / Autovisor idle park) render as durable
    /// Supervisor bubbles whose header already attributes the speaker.
    var displayContent: String {
        switch sourceContext {
        case .supervisorMessage:
            let multiline = MessageSourceContext.supervisorMessagePrefix
            if content.hasPrefix(multiline) {
                return String(content.dropFirst(multiline.count))
            }
            let inline = "Supervisor: "
            if content.hasPrefix(inline) {
                return String(content.dropFirst(inline.count))
            }
            return content
        case .supervisorAnswer:
            let prefix = MessageSourceContext.supervisorAnswerPrefix
            if content.hasPrefix(prefix) {
                return String(content.dropFirst(prefix.count))
            }
            return content
        case .loopCorrection:
            return Self.strippingLoopCorrectionBlock(content)
        default:
            return content
        }
    }

    /// Removes the wire-side framing from a `.loopCorrection` body.
    ///
    /// The markers are addressed to the PROVIDER (see
    /// ``MessageSourceContext/loopCorrectionBlockOpen``), and the feed row that renders this
    /// turn is already labelled `system: loop correction` — so leaving them in made
    /// `SystemNoticePresentation.previewLine`, which takes the first non-empty line, reduce the
    /// row to `--- LOOP CORRECTION ---`: a preview that duplicated its own label and carried
    /// nothing else.
    ///
    /// Each marker is dropped on its own merit rather than as a pair: a body carrying only one
    /// of them should lose that one. Line-based, so a body of nothing but markers collapses to
    /// empty (the row then renders label-only) and a body carrying neither is returned
    /// unchanged — which is also what makes it idempotent, and what keeps corrections persisted
    /// before the block existed rendering as they always did.
    private static func strippingLoopCorrectionBlock(_ content: String) -> String {
        var lines = content.components(separatedBy: .newlines)
        if lines.first?.trimmingCharacters(in: .whitespaces)
            == MessageSourceContext.loopCorrectionBlockOpen {
            lines.removeFirst()
        }
        if lines.last?.trimmingCharacters(in: .whitespaces)
            == MessageSourceContext.loopCorrectionBlockClose {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? MonotonicClock.shared.now()
        // Decode as String for backward compatibility, then convert to LLMRole
        let roleString = try c.decode(String.self, forKey: .role)
        self.role = LLMRole(rawValue: roleString) ?? .user
        self.content = try c.decode(String.self, forKey: .content)
        self.thinking = try c.decodeIfPresent(String.self, forKey: .thinking)
        self.sourceRole = try c.decodeIfPresent(Role.self, forKey: .sourceRole)
        // Decode tolerantly (string + rawValue lookup, same as `role` above): an
        // unknown context raw — e.g. a case added by a newer build, read after a
        // downgrade — degrades to `nil` instead of throwing and failing the whole
        // message (and the step / task) to decode.
        let sourceContextRaw = try c.decodeIfPresent(String.self, forKey: .sourceContext)
        self.sourceContext = sourceContextRaw.flatMap(MessageSourceContext.init(rawValue:))
    }
}
