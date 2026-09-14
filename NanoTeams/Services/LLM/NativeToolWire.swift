import Foundation

// MARK: - JSONValue

/// An arbitrary JSON value that round-trips through `Codable`.
///
/// Exists for the ONE place the app has to carry model-authored JSON as structure rather
/// than as text: a native `tool_calls` turn. Ollama's `/api/chat` sends and expects
/// `arguments` as an OBJECT, so replaying an assistant turn there means encoding the call's
/// `argumentsJSON` string back into structure, and reading one means decoding structure into
/// the string every downstream consumer already reads (`StepToolCall.argumentsJSON`). Every
/// other wire value in the app has a fixed shape and a fixed `Codable` type.
///
/// Objects keep their keys SORTED on output (`stableString`, and the wire encoder's own
/// `.sortedKeys`), which is what makes a call's bytes deterministic across resends — the
/// property the prompt-prefix cache and `PromptPrefixFingerprint` depend on.
nonisolated indirect enum JSONValue: Codable, Hashable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let bool = try? single.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? single.decode(Double.self) {
            self = .number(number)
        } else if let string = try? single.decode(String.self) {
            self = .string(string)
        } else if let array = try? single.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? single.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: single, debugDescription: "not a JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .object(let object): try single.encode(object)
        case .array(let array): try single.encode(array)
        case .string(let string): try single.encode(string)
        case .number(let number):
            // An integral double encodes as an integer, so `{"depth":1}` does not come back
            // as `{"depth":1.0}` — a byte the model never wrote and the server never cached.
            if number.rounded() == number, abs(number) < 1e15 {
                try single.encode(Int64(number))
            } else {
                try single.encode(number)
            }
        case .bool(let bool): try single.encode(bool)
        case .null: try single.encodeNil()
        }
    }

    /// The value parsed from `json`, or `nil` when the text is not a JSON value.
    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let value = try? JSONCoderFactory.makeWireDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        self = value
    }

    /// The value as compact JSON text with sorted keys — the one spelling every reader of
    /// a call's arguments sees, whichever provider produced it.
    var stableString: String {
        guard let data = try? JSONCoderFactory.makeWireEncoder().encode(self),
              let text = String(data: data, encoding: .utf8)
        else { return "null" }
        return text
    }

    /// Whether this is a JSON object — the only shape a tool's arguments may take.
    var isObject: Bool {
        if case .object = self { return true }
        return false
    }
}

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
        self.function = Function(
            name: schema.name, description: schema.description, parameters: schema.parameters)
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
