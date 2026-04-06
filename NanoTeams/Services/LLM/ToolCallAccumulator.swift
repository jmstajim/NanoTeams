import Foundation

struct ToolCallAccumulator {
    struct Partial: Hashable {
        var providerID: String?
        var name: String
        var arguments: String
    }

    private var callsByIndex: [Int: Partial] = [:]

    mutating func absorb(_ deltas: [StreamEvent.ToolCallDelta]) {
        for delta in deltas {
            let idx = delta.index ?? 0
            var partial = callsByIndex[idx] ?? Partial(providerID: nil, name: "", arguments: "")

            if let id = delta.id, !id.isEmpty {
                partial.providerID = id
            }

            if let fnName = delta.name, !fnName.isEmpty {
                partial.name = fnName
            }

            if let args = delta.argumentsDelta, !args.isEmpty {
                partial.arguments += args
            }

            callsByIndex[idx] = partial
        }
    }

    func finalize() -> [StepToolCall] {
        let sorted = callsByIndex.keys.sorted()
        return sorted.compactMap { idx in
            guard let partial = callsByIndex[idx] else { return nil }
            guard !partial.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return StepToolCall(providerID: partial.providerID, name: partial.name, argumentsJSON: partial.arguments)
        }
    }
}
