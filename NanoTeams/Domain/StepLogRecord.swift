import Foundation

/// Which of a step's four stream collections a log record belongs to.
nonisolated enum StepLogStream: String, Codable, CaseIterable {
    case conversation
    case wire
    case toolCalls
    case messages
}

/// One line of a step's `step_log.jsonl` — the append-only home of the four
/// stream collections that used to ride inside `task.json` (98.4% of a task's
/// bytes, rewritten whole on every `mutateTask`; measured ≈39 GB written to
/// produce one 18.3 MB task).
///
/// Replay semantics per case:
///  - `conversation` / `toolCall` / `message`: id-bearing (`UUID`) — replay
///    OVERWRITES the element with that id when present, else appends. That makes
///    replay idempotent-by-id, and an in-place edit (`updateToolCallResult`,
///    `commitStreamingContent`) is expressed as ONE re-emitted record instead of
///    a truncate-and-re-append of the tail (tool results carry file contents —
///    re-emitting a tail would re-duplicate the largest records in the file).
///  - `wire`: positional append — `ChatMessage` has no id, and its writers
///    replace the whole array, which prefix-diffing turns into appends.
///  - `truncate(stream:keep:)`: the non-append mutations (repair, discard,
///    `StepExecution.reset()`) — replay drops the stream's elements past `keep`.
nonisolated enum StepLogRecord {
    case conversation(LLMMessage)
    case toolCall(StepToolCall)
    case message(StepMessage)
    case wire(ChatMessage)
    case truncate(stream: StepLogStream, keep: Int)
}

extension StepLogRecord: Codable {
    private enum CodingKeys: String, CodingKey { case kind, payload, stream, keep }
    private enum Kind: String, Codable {
        case conversation, toolCall, message, wire, truncate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .conversation:
            self = .conversation(try c.decode(LLMMessage.self, forKey: .payload))
        case .toolCall:
            self = .toolCall(try c.decode(StepToolCall.self, forKey: .payload))
        case .message:
            self = .message(try c.decode(StepMessage.self, forKey: .payload))
        case .wire:
            self = .wire(try c.decode(ChatMessage.self, forKey: .payload))
        case .truncate:
            self = .truncate(
                stream: try c.decode(StepLogStream.self, forKey: .stream),
                keep: try c.decode(Int.self, forKey: .keep))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .conversation(let m):
            try c.encode(Kind.conversation, forKey: .kind)
            try c.encode(m, forKey: .payload)
        case .toolCall(let t):
            try c.encode(Kind.toolCall, forKey: .kind)
            try c.encode(t, forKey: .payload)
        case .message(let m):
            try c.encode(Kind.message, forKey: .kind)
            try c.encode(m, forKey: .payload)
        case .wire(let w):
            try c.encode(Kind.wire, forKey: .kind)
            try c.encode(w, forKey: .payload)
        case .truncate(let stream, let keep):
            try c.encode(Kind.truncate, forKey: .kind)
            try c.encode(stream, forKey: .stream)
            try c.encode(keep, forKey: .keep)
        }
    }
}

/// One appended line: a monotonically increasing per-file sequence number plus
/// the record. `seq` is what `StepLogCommit` cross-checks against on hydrate —
/// the desync detector between `task.json` (metadata) and the log.
nonisolated struct StepLogEntry: Codable {
    var seq: Int
    var record: StepLogRecord
}

/// Stamped on `StepExecution` by the repository when (and only when) the step's
/// streams live in `step_log.jsonl`. `nil` ⇔ legacy task — the four arrays are
/// still embedded in `task.json` and remain authoritative.
///
/// `seq` is the last sequence number the metadata write KNEW about; the four
/// counts are the stream lengths at that moment. On hydrate:
///  - log's last seq == `seq`, counts match → consistent;
///  - log ahead → crash after the log write, before the metadata write: trust
///    the log (the extra records are real work), repair on the next flush;
///  - log behind → torn tail: accept the log, repair `seq` down (loss ≤ one
///    flush, and the torn line itself was already truncated by
///    `JSONLFileLog`'s first-append repair).
nonisolated struct StepLogCommit: Codable, Hashable {
    var seq: Int
    var conversation: Int
    var wire: Int
    var toolCalls: Int
    var messages: Int
}
