import Foundation

// MARK: - NativeToolDeclaration

/// One tool as BOTH providers' native `tools` field spells it:
/// `{"type":"function","function":{"name","description","parameters"}}`.
///
/// `parameters` is the app's own `JSONSchema`, encoded by its `Codable` — the same three-level
/// schema the prompt-taught renderer prints as prose. Nothing is translated: a schema a
/// provider cannot express is a schema the app does not have either (CLAUDE.md #46).
nonisolated struct NativeToolDeclaration: Encodable, Hashable, Sendable {
    let type: String
    let function: Function

    nonisolated struct Function: Encodable, Hashable, Sendable {
        let name: String
        let description: String
        let parameters: JSONSchema
    }

    init(_ schema: ToolSchema) {
        self.type = "function"
        let raw = schema.parameters
        let parameters: JSONSchema =
            (raw.type == "object" && raw.properties == nil)
            ? JSONSchema(
                type: raw.type,
                description: raw.description,
                properties: [:],
                required: raw.required,
                items: raw.items,
                enumValues: raw.enumValues)
            : raw
        self.function = Function(
            name: schema.name, description: schema.description, parameters: parameters)
    }
}

// MARK: - NativeToolTurnPairing

/// Pairs every `.tool` message of a wire with the call it answers, for the two native
/// request builders.
///
/// A native wire needs each result to name its call — Ollama by `tool_name`, the OpenAI shape
/// by `tool_call_id` — and the app's `.tool` turns carry the id (`ToolRuntime` mints one per
/// call and the result carries it back; the Supervisor's answer resolves INTO the parked ask's
/// placeholder under that id, `SupervisorAskWireResolution`). Two do not: the
/// delegation-interruption envelope `StatusRecoveryService` writes, and an answer appended to a
/// transcript persisted before ids rode the wire. Both answer the call the preceding assistant
/// turn made, in order, so a `.tool` with no id takes the first call of that turn no earlier
/// result has claimed — the same positional rule `MeetingToolExecutor` pairs by. A `.tool`
/// whose id matches none of them keeps its id and gets no name; the server accepts an unnamed
/// result (measured on Ollama 0.34.0, 2026-09-13).
nonisolated enum NativeToolTurnPairing {

    /// What one `.tool` message answers.
    struct Pair: Hashable, Sendable {
        let id: String
        let name: String?
    }

    /// One entry per `.tool` message of `messages`, in order, keyed by that message's index.
    ///
    /// Linear in the wire: the preceding turn's calls are indexed by id once per assistant
    /// turn, and the positional pick is a cursor over that turn's calls, so no `.tool`
    /// message re-scans the list (`coverage/tools/algorithmic_complexity.py`, axis a1).
    static func pairs(in messages: [ChatMessage]) -> [Int: Pair] {
        var out: [Int: Pair] = [:]
        var pending: [ChatToolCall] = []
        var positionByID: [String: Int] = [:]
        var claimed: Set<Int> = []
        var cursor = 0
        for (index, message) in messages.enumerated() {
            switch message.role {
            case .assistant:
                pending = message.toolCalls ?? []
                positionByID = [:]
                for (position, call) in pending.enumerated() where positionByID[call.id] == nil {
                    positionByID[call.id] = position
                }
                claimed = []
                cursor = 0
            case .tool:
                if let id = message.toolCallID,
                   let position = positionByID[id], !claimed.contains(position)
                {
                    claimed.insert(position)
                    out[index] = Pair(id: pending[position].id, name: pending[position].name)
                } else if message.toolCallID == nil {
                    // The first call of the turn no earlier result has claimed. The cursor
                    // only moves forward, so the walk is amortised over the turn's calls.
                    while cursor < pending.count, claimed.contains(cursor) { cursor += 1 }
                    if cursor < pending.count {
                        claimed.insert(cursor)
                        out[index] = Pair(id: pending[cursor].id, name: pending[cursor].name)
                        cursor += 1
                    } else {
                        out[index] = Pair(id: UUID().uuidString, name: nil)
                    }
                } else {
                    // An id nothing in the preceding turn made, or one already answered: keep
                    // what the message says and let the server decide.
                    out[index] = Pair(id: message.toolCallID ?? UUID().uuidString, name: nil)
                }
            case .user, .system:
                continue
            }
        }
        return out
    }
}
