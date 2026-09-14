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

    /// Appends each delta to its partial without copying the accumulated blob.
    ///
    /// The shape that stood here read the partial out of the dictionary with a plain
    /// subscript, appended, and wrote it back — leaving `arguments` referenced twice, so
    /// `+=` could never take its uniquely-referenced fast path. Every delta reallocated
    /// and memcpy'd the whole blob, which the type's own doc measures in hundreds of KB:
    /// Θ(args²) across a stream, the same defect as `StreamingPreviewManager.append`.
    ///
    /// Live since the native tool-calling wave (2026-09-13): `OllamaChatStreamParser` under
    /// `.native` and `OpenAIChatChunkParser` emit `toolCallDeltas` — whole calls on Ollama,
    /// argument fragments on the OpenAI-compat route — and `ContextCompactionSummaryService`
    /// and `DelegatedSupervisorAnswerService` absorb them beside the step loop. Fixed before
    /// that, because it is the same class as `StreamingPreviewManager.append`.
    mutating func absorb(_ deltas: [StreamEvent.ToolCallDelta]) {
        for delta in deltas {
            let idx = delta.index ?? 0
            // `removeValue`, not a plain subscript READ: taking the partial out drops the
            // dictionary's reference to its `arguments` buffer, so the `+=` below is
            // uniquely referenced and appends in place. Reading a copy while the
            // dictionary still holds one — the shape that stood here — made every delta
            // reallocate and memcpy the whole accumulated blob.
            var partial = callsByIndex.removeValue(forKey: idx)
                ?? Partial(providerID: nil, name: "", arguments: "")

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
    /// (whitespace / key-order differences) runs behind a `StreamProbeGate`
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
