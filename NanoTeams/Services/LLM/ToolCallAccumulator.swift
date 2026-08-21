import Foundation

nonisolated struct ToolCallAccumulator {
    struct Partial: Hashable {
        var providerID: String?
        var name: String
        var arguments: String
        /// Running FNV-1a over the argument deltas, folded AS THEY ARRIVE — so the
        /// per-delta duplicate probe (`hasRawDuplicate`) never re-reads `arguments`.
        /// Re-hashing the whole blob per delta was the cost this replaces: the old
        /// probe rebuilt `"\(name)\u{1F}\(argumentsJSON)"` for every call on every
        /// `toolCallDeltas` event — O(args) per delta, O(args²) across the stream,
        /// on blobs the doc below measures in hundreds of KB (CLAUDE.md #106).
        var argumentsHash: UInt64 = PromptPrefixFingerprint.fnvOffsetBasis
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
                partial.argumentsHash = PromptPrefixFingerprint.fold(partial.argumentsHash, args)
            }

            callsByIndex[idx] = partial
        }
    }

    /// Byte-identical duplicate among the named partials, O(#calls) per probe:
    /// candidates pair up by (name, args length, running hash); only a candidate
    /// pair pays an exact `arguments` compare (hash collisions must not fabricate
    /// a duplicate — a wrong `true` here aborts the model's stream mid-envelope).
    /// This is the per-delta HALF of duplicate detection: the canonical half
    /// (whitespace / key-order differences) runs behind a `StreamScanCadenceGate`
    /// at the call site, because no O(1) signature can over-approximate JSON
    /// canonical equality.
    var hasRawDuplicate: Bool {
        guard callsByIndex.count >= 2 else { return false }
        var seen: [String: [Int]] = [:]
        for (idx, partial) in callsByIndex {
            let name = partial.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = "\(name)\u{1F}\(partial.arguments.utf8.count)\u{1F}\(partial.argumentsHash)"
            for other in seen[key, default: []]
                where callsByIndex[other]?.arguments == partial.arguments {
                return true
            }
            seen[key, default: []].append(idx)
        }
        return false
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
