import Foundation

/// Pure decisions for a **context-compaction epoch**: replacing a step's wire with its
/// pinned head plus one seed turn that stands in for everything folded away.
///
/// The wire is append-only and resent whole on every request, so a long-lived role walks
/// toward a window it cannot see (playbook R3.9.1). There are exactly two sanctioned ways
/// for that array to get shorter, and both are whole-array epochs rather than splices: the
/// planning boundary (`PlanningPhasePolicy.implementationWire`) and this one. Splicing an
/// earlier index would invalidate the server's KV prefix from that point AND break the
/// append-only invariant the loop detectors read
/// (`ConversationAppendInvariantTests`).
///
/// Three properties make an epoch safe to run in the middle of a live step:
///
/// 1. **The head is preserved byte-for-byte.** It is the leading run of non-assistant
///    messages: the system prompt with its tool catalog, the `## Supervisor Task` brief,
///    and whatever pipeline turns the builder appended — i.e. exactly the "pinned buffer"
///    R3.9.5 requires to survive verbatim. Preserving it by SLICING the array that already
///    went over the wire is byte-exact by construction; re-rendering it through
///    `PromptBuilder` would read task state that has moved since t0 and guarantee a prefix
///    miss, which is the cost the epoch exists to avoid.
/// 2. **The Supervisor's own words are carried forward verbatim.** A summary is the
///    model's paraphrase, and a paraphrased constraint is a lost constraint. The record
///    block is built by the APP from the discarded range and round-trips exactly
///    (`recordedSupervisorMessages`), so instructions accumulate across epochs instead of
///    decaying.
/// 3. **The seed is a `.user` turn.** `.assistant` is constructible in exactly one place
///    (`processStreamingResult`), and a fabricated assistant turn would also read to the
///    model as something it said — which the summary is not: the app asked for it.
///
/// The model writes the summary; nothing here schedules one. A fixed interval would
/// compact a step that is nowhere near its budget and leave one that raced past it
/// (R3.9.6). What triggers an epoch lives in `LLMExecutionService+ContextCompaction`.
///
/// `nonisolated` is required (the app target defaults types to `@MainActor`); everything
/// here is value-in/value-out so it composes from any context, tests included.
nonisolated enum CompactionPolicy {

    // MARK: - Reason

    /// Why an epoch ran. Reaches the human as the feed row's parenthetical and nothing
    /// else — the model is never told, because "your context was full" is a fact about the
    /// server that invites the model to apologise for it.
    enum CompactionReason: String, Equatable, CaseIterable {
        /// The user clicked the fill indicator. Ignores the terminal latch: a human asking
        /// twice is a human who knows the first one did not help.
        case manual
        /// The server's own prompt count crossed `ContextBudgetPolicy.stepBudget`.
        case budgetExceeded
        /// The server stopped processing everything we send
        /// (`ContextBudgetPolicy.shouldReportTruncation`).
        case serverTruncation
        /// The server refused the request outright as an overflow. Compacts WITHOUT asking
        /// the model for a summary — that request would not fit either.
        case serverRefusedOverflow

        /// The parenthetical on the feed row.
        var noticeLabel: String {
            switch self {
            case .manual: "requested"
            case .budgetExceeded: "budget exceeded"
            case .serverTruncation: "server truncating"
            case .serverRefusedOverflow: "server refused the prompt"
            }
        }
    }

    // MARK: - Markers

    /// First line of the seed turn. Matched with `hasPrefix` rather than `contains`, unlike
    /// `PlanningPhasePolicy.briefIndex`: a summary written by the model can legitimately
    /// QUOTE a heading it saw, and a `contains` match would then read the quotation as a
    /// second seed and truncate the wire at it on the next epoch.
    static let seedMarker = "## Context summary"

    /// Every spelling recognised on READ. One entry today; the array exists from the first
    /// day because the planning phase learned the same lesson late — a step suspended under
    /// an older build carries the OLD header inside its persisted `wireTranscript`, and a
    /// matcher that only knows the new one silently reads "never compacted" and folds the
    /// previous seed away along with the Supervisor record inside it.
    static let seedMarkers: [String] = [seedMarker]

    /// Heading of the verbatim Supervisor block inside a seed.
    static let recordSectionHeader = "### Supervisor instructions, verbatim"

    /// Heading of the model's summary body inside a seed.
    private static let summarySectionHeader = "### Summary"

    /// Heading of the role's own recorded notes inside a seed.
    private static let notesSectionHeader = "### Your recorded notes"

    /// Per-entry header inside the record block: `#### 1 · 3 lines`.
    ///
    /// The line COUNT is what makes the block round-trip for any content. A delimiter would
    /// not: a Supervisor may type anything, delimiter line included, and the entries must
    /// come back byte-identical or the carry-forward is a slow paraphrase after all.
    private static func recordEntryHeader(index: Int, lineCount: Int) -> String {
        "#### \(index) · \(lineCount) lines"
    }

    /// The line count in an entry header, or `nil` when the line is not one.
    ///
    /// Parsed by hand rather than by `NSRegularExpression`: a literal pattern's compilation
    /// cannot fail, so its `try?` branch is a line no test can reach and no reader can judge
    /// — and the shape here is two fixed affixes around two integers.
    private static func recordEntryLineCount(in line: String) -> Int? {
        guard line.hasPrefix("#### ") else { return nil }
        // Searched AFTER the prefix, not across the whole line: `#### · 1 lines` puts a " · "
        // that starts INSIDE the prefix, and a whole-line search would hand back a separator
        // before the index field — an inverted range, which traps rather than returning nil.
        let body = line.dropFirst(5)
        guard let separator = body.range(of: " · ") else { return nil }
        let index = body[body.startIndex..<separator.lowerBound]
        guard !index.isEmpty, index.allSatisfy(\.isNumber) else { return nil }
        let tail = body[separator.upperBound...]
        let digits = tail.prefix { $0.isNumber }
        guard !digits.isEmpty, let count = Int(digits) else { return nil }
        // Sliced at the digits' own end index, never `dropFirst(digits.count)`: the count is a
        // grapheme walk of the number, and the index is already in hand.
        let suffix = tail[digits.endIndex...]
        guard suffix == " lines" || suffix == " line" else { return nil }
        return count
    }

    /// True for the seed turn of a previous epoch.
    static func isCompactionSeed(_ message: ChatMessage) -> Bool {
        guard message.role == .user, let content = message.content else { return false }
        return seedMarkers.contains { content.hasPrefix($0) }
    }

    // MARK: - Wire inspection

    /// Exclusive end of the PINNED HEAD: the first index that is either an assistant turn
    /// or a previous epoch's seed.
    ///
    /// Stopping at the seed is load-bearing and is the one thing most likely to be
    /// re-derived wrongly. After epoch 1 the wire reads `[system, task…, seed, assistant,
    /// …]`, so the seed EXTENDS the leading run of non-assistant messages. A `headEnd` that
    /// only looked for the first assistant would keep seed 1 and append seed 2 after it, and
    /// every later epoch would add another — the wire would grow a stack of summaries of
    /// summaries, which is the opposite of compaction.
    static func headEnd(in wire: [ChatMessage]) -> Int {
        wire.firstIndex { $0.role == .assistant || isCompactionSeed($0) } ?? wire.count
    }

    /// Index of the last assistant turn, or `nil`.
    static func lastAssistantIndex(in wire: [ChatMessage]) -> Int? {
        wire.lastIndex { $0.role == .assistant }
    }

    /// What one epoch keeps.
    struct Plan: Equatable {
        /// Exclusive end of the head. `wire[..<headEnd]` survives byte-for-byte.
        let headEnd: Int
        /// Inclusive start of a retained tail, or `nil` when everything after the head is
        /// folded away.
        let tailStart: Int?

        /// The half-open range that the seed stands in for.
        func discardedRange(in wire: [ChatMessage]) -> Range<Int> {
            headEnd..<(tailStart ?? wire.count)
        }
    }

    /// The epoch's plan, or `nil` when there is nothing to fold.
    ///
    /// - Parameters:
    ///   - retainTail: keep the trailing assistant turn and its tool results when that turn
    ///     is a PARK — an `ask_supervisor` / `wait_for_events` call whose `{"status":
    ///     "pending"}` result is still open. Re-entry resolves that park by finding the
    ///     pending result by `toolCallID` and replacing it in place
    ///     (`LLMExecutionService+ToolLoopState`), so folding it away would leave the answer
    ///     with nothing to attach to. Never requested from inside the tool loop: there the
    ///     seed must be the LAST turn, or a 100 KB `create_artifact` envelope sitting in the
    ///     tail defeats the whole epoch.
    ///   - maxTailTokens: refuse the epoch when the retained tail alone is this big. A tail
    ///     that already fills half the budget cannot be compacted INTO anything, and running
    ///     the epoch would spend an LLM call to shrink a conversation that stays too big.
    static func plan(
        for wire: [ChatMessage],
        retainTail: Bool,
        maxTailTokens: Int? = nil
    ) -> Plan? {
        let headEnd = headEnd(in: wire)
        guard headEnd < wire.count else { return nil }

        guard retainTail else { return Plan(headEnd: headEnd, tailStart: nil) }

        guard let lastAssistant = lastAssistantIndex(in: wire),
              lastAssistant > headEnd,
              carriesOpenPark(wire[lastAssistant])
        else {
            // Nothing structural to preserve: fold the whole body. A step suspended without
            // an open park (paused, failed) resumes by appending, not by resolving a call.
            return Plan(headEnd: headEnd, tailStart: nil)
        }

        if let maxTailTokens {
            let tail = Array(wire[lastAssistant...])
            guard ContextBudgetPolicy.estimateTokens(messages: tail) < maxTailTokens else {
                return nil
            }
        }
        return Plan(headEnd: headEnd, tailStart: lastAssistant)
    }

    /// Whether an assistant turn is a PARK — a call the step is suspended on.
    private static func carriesOpenPark(_ message: ChatMessage) -> Bool {
        message.toolCalls?.contains {
            $0.name == ToolNames.askSupervisor || $0.name == ToolNames.waitForEvents
        } ?? false
    }

    // MARK: - Wire composition

    /// The compacted wire: the pinned head, the seed, and whatever tail the plan retained.
    ///
    /// A slice plus one turn — the same shape as the planning boundary, for the same
    /// reason: the head that goes back over the wire has to be the bytes that already went
    /// over it, or the server re-prefills everything.
    static func compactedWire(
        from wire: [ChatMessage],
        plan: Plan,
        seedTurn: String
    ) -> [ChatMessage] {
        let head = Array(wire[..<plan.headEnd])
        let tail = plan.tailStart.map { Array(wire[$0...]) } ?? []
        return head + [ChatMessage(role: .user, content: seedTurn)] + tail
    }

    // MARK: - Supervisor record

    /// Everything the Supervisor said inside the folded range, verbatim and in order.
    ///
    /// Three shapes reach the wire and all three are read here: the queued turn
    /// (`## Supervisor\n…`), revision feedback (`Supervisor Feedback: …`), and an answer to
    /// `ask_supervisor` — which lands as a `.tool` envelope rather than as prose, because
    /// the loop replaces the pending result in place. A previous epoch's record is
    /// recovered from its seed and carried first, so the block only ever grows.
    ///
    /// Growing without bound is the deliberate price of R3.9.5: a constraint the Supervisor
    /// stated once holds until they say otherwise, and there is no signal in the
    /// conversation that says which constraints have expired. In practice the block is
    /// small — it holds what a human typed, not what a model generated.
    static func supervisorRecord(in wire: [ChatMessage], discarded: Range<Int>) -> [String] {
        var entries: [String] = []
        for index in discarded where wire.indices.contains(index) {
            let message = wire[index]
            if isCompactionSeed(message), let content = message.content {
                entries += recordedSupervisorMessages(in: content)
                continue
            }
            guard let content = message.content else { continue }
            switch message.role {
            case .user:
                if let stripped = strippingSupervisorPrefix(content) { entries.append(stripped) }
            case .tool:
                if let response = supervisorAnswerResponse(inToolResult: content) {
                    entries.append(response)
                }
            default:
                continue
            }
        }
        return entries
    }

    /// The body of a Supervisor-authored `.user` turn, prefix removed, or `nil` when the
    /// turn is not one.
    ///
    /// Prefixes come from `MessageSourceContext`, which owns them — including the legacy
    /// spellings, so a conversation persisted by an older build still yields its
    /// instructions. Longest-first, because `supervisorAnswerPrefix +
    /// supervisorFeedbackPrefix` is a real composed form and stripping the outer one alone
    /// would leave the inner marker inside the "verbatim" record.
    private static func strippingSupervisorPrefix(_ content: String) -> String? {
        let prefixes =
            (MessageSourceContext.supervisorMessage.attributionPrefixes
                + MessageSourceContext.supervisorAnswer.attributionPrefixes
                + MessageSourceContext.supervisorFeedback.attributionPrefixes)
            .sorted { $0.count > $1.count }
        for prefix in prefixes where content.hasPrefix(prefix) {
            // `trimmingPrefix`, not `dropFirst(prefix.count)`: the latter counts GRAPHEMES of
            // the marker on every Supervisor turn of the folded range, which is a walk to
            // compute a length the collection can strip without one.
            return String(content.trimmingPrefix(prefix))
        }
        return nil
    }

    /// The `response` field of an `ask_supervisor` result envelope
    /// (`buildCollaborationToolResult`), or `nil` for any other tool result.
    private static func supervisorAnswerResponse(inToolResult json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["tool"] as? String == ToolNames.askSupervisor,
              let response = object["response"] as? String
        else { return nil }
        return response
    }

    /// Reads a record block back out of a seed turn — the inverse of what `seedTurn` writes.
    ///
    /// Entries are framed by a header carrying a LINE COUNT rather than separated by a
    /// delimiter, so any content round-trips: a Supervisor is free to type the header, the
    /// delimiter, or anything else, and the parser never looks at the entry's bytes.
    static func recordedSupervisorMessages(in seedTurn: String) -> [String] {
        let lines = seedTurn.components(separatedBy: "\n")
        guard let sectionIndex = lines.firstIndex(of: recordSectionHeader) else { return [] }
        var entries: [String] = []
        var cursor = sectionIndex + 1
        while cursor < lines.count {
            guard let lineCount = recordEntryLineCount(in: lines[cursor]) else { break }
            let start = cursor + 1
            let end = start + lineCount
            guard end <= lines.count else { break }
            entries.append(lines[start..<end].joined(separator: "\n"))
            cursor = end
        }
        return entries
    }

    // MARK: - Marker neutralization

    /// Collapses every `##`-or-longer run to a single `#`.
    ///
    /// The summary is written by a model that has just read a conversation full of `## `
    /// headings, and models quote what they read. A quoted `## Planning phase` inside the
    /// seed is indistinguishable — to `PlanningPhasePolicy.briefIndex`, which matches with
    /// `contains` — from the real brief, and the boundary would then slice the wire at the
    /// seed on every single iteration. Applied to the MODEL's text only: the Supervisor
    /// record is verbatim by contract, and the same hazard already rides the original wire.
    static func neutralizeWireMarkers(_ text: String) -> String {
        text.replacingOccurrences(
            of: "#{2,}", with: "#", options: .regularExpression)
    }

    // MARK: - Summary extraction

    /// The prose of a finished summary reply, or `nil` when there is none.
    ///
    /// A model told "write prose, do not call a tool" sometimes calls one anyway — the
    /// catalog is still in its system prompt. When it does, the summary is inside the call's
    /// arguments rather than in the content channel, so the first plausible free-text
    /// argument is taken instead of discarding a summary that exists.
    static func summaryText(from resolution: FinishedReplyToolCallResolver.Resolution) -> String? {
        let prose = resolution.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prose.isEmpty { return prose }
        for call in resolution.toolCalls {
            guard let data = call.argumentsJSON.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            for key in ["summary", "content", "answer", "text", "question", "message"] {
                if let value = object[key] as? String,
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    return value.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return nil
    }

    /// Whether a summary is worth putting in the seed at all.
    static func isUsableSummary(_ summary: String?) -> Bool {
        guard let summary else { return false }
        return !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether an epoch would produce a seed that says anything. A seed with no summary, no
    /// notes and no record replaces the conversation with nothing, which is worse than the
    /// overflow it was answering.
    static func hasSeedMaterial(summary: String?, notes: String?, record: [String]) -> Bool {
        isUsableSummary(summary)
            || !(notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !record.isEmpty
    }

    // MARK: - Prompt text

    /// The one-shot request that asks the model to summarise its own conversation.
    ///
    /// Sent as a trailing `.user` turn on a copy of the wire and never appended to the real
    /// one: the answer replaces that conversation, so keeping the question would leave the
    /// wire carrying an instruction about an array that no longer exists.
    ///
    /// The rubric is fixed while the CONTENT is the model's, which is the split R3.9.6 asks
    /// for — the model knows what mattered, the app knows what a successor turn needs to be
    /// able to continue without the transcript.
    /// runtime-prompt
    static func summaryRequestTurn() -> String {
        var block = "## Context summary request\n"
        block += "Write a summary that stands in for every turn above. It becomes the only "
        block += "record of this step's work, so it has to stand alone.\n\n"
        block += "Cover, in this order:\n"
        block += "1. Done — what is finished, with file paths and symbol names.\n"
        block += "2. In progress — what is half-done, and what remains.\n"
        block += "3. Decisions — each choice made, with the reason for it.\n"
        block += "4. Files touched — every path, with what changed in it.\n"
        block += "5. Open questions — what is still unresolved.\n\n"
        block += "Restate every fact in full: names, paths, numbers, exact strings. A pointer "
        block += "back to a turn above will not survive, because those turns are going away.\n"
        block += "Write prose. Do not call a tool."
        return block
    }

    /// The seed turn: one `.user` message that stands in for the folded range.
    ///
    /// Three sections, each optional and each answering a different question. The SUMMARY is
    /// the model's memory of its own work. The NOTES are `step.scratchpad` — the plan it
    /// wrote for itself, which `PromptBuilder` never injects, so this is the only place it
    /// survives a fold. The RECORD is what the Supervisor said, verbatim, and it is last
    /// because it is the part that must still be true when the model reads it for the
    /// hundredth time.
    /// runtime-prompt
    static func seedTurn(
        summary: String?,
        notes: String?,
        record: [String]
    ) -> String {
        var block = seedMarker + "\n"
        block += "The earlier turns of this step are folded into what follows. It is the "
        block += "whole record of the work so far — continue from it.\n"

        if isUsableSummary(summary), let summary {
            block += "\n" + summarySectionHeader + "\n"
            block += neutralizeWireMarkers(
                summary.trimmingCharacters(in: .whitespacesAndNewlines)) + "\n"
        }

        let trimmedNotes = (notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty {
            block += "\n" + notesSectionHeader + "\n"
            block += neutralizeWireMarkers(trimmedNotes) + "\n"
        }

        if !record.isEmpty {
            block += "\n" + recordSectionHeader + "\n"
            for (offset, entry) in record.enumerated() {
                let lines = entry.components(separatedBy: "\n")
                block += recordEntryHeader(index: offset + 1, lineCount: lines.count) + "\n"
                block += lines.joined(separator: "\n") + "\n"
            }
        }
        return block
    }

    // MARK: - Feed notice

    /// The activity-feed row's content: a headline the row collapses to, then the seed the
    /// detail window opens.
    ///
    /// The two numbers are NOT measured the same way, and the row says so. `beforeTokens` is
    /// the server's own count of the request that triggered the epoch; `afterTokens` can only
    /// be `estimateTokens`, because nothing has been sent since the fold — so it wears the
    /// tilde every estimate in this app wears.
    static func noticeText(
        reason: CompactionReason,
        beforeTokens: Int?,
        afterTokens: Int?,
        foldedTurns: Int,
        seedTurn: String
    ) -> String {
        var headline = "Compacted \(foldedTurns) turns"
        if let beforeTokens, let afterTokens {
            headline += ": \(TokenCountFormat.exact(beforeTokens)) → "
            headline += "\(TokenCountFormat.approximate(afterTokens)) tokens"
        }
        headline += " (\(reason.noticeLabel))."
        return headline + "\n\n" + seedTurn
    }
}
