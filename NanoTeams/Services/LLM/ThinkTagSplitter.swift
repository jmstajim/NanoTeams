import Foundation

// MARK: - Think Tag Splitter

/// Re-routes an inline leading `<think>…</think>` span from the content channel to
/// the thinking channel. Both stream parsers feed it: `OllamaChatStreamParser` for
/// a model whose chat template Ollama does not parse server-side, and
/// `SSEEventParser` for an LM Studio build that ships no reasoning parser for the
/// loaded repo — either way the reasoning arrives inline in content, and every
/// downstream consumer (thinking disclosure, loop detection, `HarmonyToolCallParser`,
/// the append-only wire) must see ONE content/thinking split regardless of the
/// provider. Lived inside `OllamaChatStreamParser.swift` until 2026-09-07, when only
/// the Ollama path ran it. Stateful because a tag can split across stream chunks
/// (`"<th"` + `"ink>"`): a chunk's trailing characters are held back while they are
/// still a viable prefix of the next expected tag.
///
/// The open tag is recognized ONLY before any non-whitespace content has been
/// emitted (reasoning models think first, answer second). Once real content
/// has flowed, a literal `<think>` in prose or code stays content — this
/// protects Harmony tool-call envelopes from being split across channels
/// mid-JSON, which would corrupt `HarmonyToolCallParser` extraction.
nonisolated struct ThinkTagSplitter {

    struct Output: Equatable {
        var content: String = ""
        var thinking: String = ""
    }

    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    private var inThink = false
    private var hasEmittedContent = false
    private var pending = ""

    mutating func feed(_ chunk: String) -> Output {
        // Fast path: past the (optional) leading think block, no further tags
        // are recognized — pass everything straight through. `pending` can
        // hold a previously held-back prefix whose tag window just closed.
        if !inThink && hasEmittedContent {
            let text = pending + chunk
            pending = ""
            var out = Output()
            emit(text, into: &out)
            return out
        }

        pending += chunk
        var out = Output()
        // Every pass either breaks (real content flowed, or the buffer is spent) or
        // toggles the channel and continues — and the window closes only on the
        // breaking passes, so no continued pass ever finds it closed. The entry
        // fast path above is the ONE place that reads a closed window; a second
        // check at the top of the loop was unreachable code until 2026-09-07.
        while true {
            let tag = inThink ? Self.closeTag : Self.openTag
            if let range = pending.range(of: tag) {
                let before = String(pending[..<range.lowerBound])
                if !inThink && !before.allSatisfy(\.isWhitespace) {
                    // Real content precedes the tag in this same buffer — the
                    // tag is literal prose/code, not a think opener. The same
                    // bytes split across two chunks take the entry fast path to
                    // the same output, so the split never depends on how a
                    // server or proxy frames the deltas.
                    emit(pending, into: &out)
                    pending = ""
                    break
                }
                emit(before, into: &out)
                pending = String(pending[range.upperBound...])
                inThink.toggle()
                continue
            }
            // No full tag: emit everything except a trailing viable prefix of
            // the expected tag, which stays buffered for the next chunk.
            let holdCount = trailingPrefixLength(of: tag, in: pending)
            let emitEnd = pending.index(pending.endIndex, offsetBy: -holdCount)
            emit(String(pending[..<emitEnd]), into: &out)
            pending = String(pending[emitEnd...])
            break
        }
        return out
    }

    /// Emit whatever is buffered (stream end). An unfinished tag prefix is
    /// surfaced verbatim on the current channel rather than dropped.
    mutating func flush() -> Output {
        var out = Output()
        emit(pending, into: &out)
        pending = ""
        return out
    }

    private mutating func emit(_ text: String, into out: inout Output) {
        guard !text.isEmpty else { return }
        if inThink {
            out.thinking += text
        } else {
            out.content += text
            // Whitespace before the opening tag must not close the tag window
            // (models emit `\n<think>` on occasion).
            if !text.allSatisfy(\.isWhitespace) { hasEmittedContent = true }
        }
    }

    /// Length of the longest suffix of `s` that is a proper prefix of `tag`.
    private func trailingPrefixLength(of tag: String, in s: String) -> Int {
        let maxLen = min(tag.count - 1, s.count)
        guard maxLen > 0 else { return 0 }
        for len in stride(from: maxLen, through: 1, by: -1) {
            if tag.hasPrefix(s.suffix(len)) { return len }
        }
        return 0
    }
}
