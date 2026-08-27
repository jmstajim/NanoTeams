import Foundation

/// Cumulative fingerprint of an outgoing conversation, used to tell whether the server's
/// prompt-prefix (KV) cache can still be reused.
///
/// The transport is stateless on both providers: every request resends the FULL conversation
/// and the only speed lever is the server reusing its cache on a byte-identical leading run of
/// bytes (measured on this project's models: ~350 ms warm vs ~4300–6100 ms cold at 13k tokens).
/// A miss is silent — the server answers HTTP 200 either way — so the only way to notice one is
/// to compare what we are about to send against what we sent last.
///
/// `chain` produces one hash per wire segment, each folded over its predecessor, so the index of
/// the first mismatch between two chains IS the number of segments the server can still reuse.
/// Comparison is O(n) over hashes rather than over content.
///
/// Explicit FNV-1a rather than `Hasher`: `Hasher` is seeded per process, so its output cannot be
/// asserted in tests, and CLAUDE.md #22 already bans `hashValue` where identity matters.
///
/// `nonisolated` because the app target defaults types to `@MainActor`; pure value-in /
/// value-out (house pattern: `ConversationReplay`, `ContextBudgetPolicy`, `LoopRecoveryPolicy`).
nonisolated enum PromptPrefixFingerprint {

    // MARK: - FNV-1a (64-bit)

    static let fnvOffsetBasis: UInt64 = 14_695_981_039_346_656_037
    private static let fnvPrime: UInt64 = 1_099_511_628_211

    /// Folds `string`'s UTF-8 into `seed`. `&*` / `^` wrap by definition of the algorithm.
    /// Internal (not private): `ToolCallAccumulator` folds argument deltas through the
    /// SAME function for its raw-duplicate signature — one hash, one home.
    static func fold(_ seed: UInt64, _ string: String) -> UInt64 {
        var hash = seed
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* fnvPrime
        }
        return hash
    }

    // MARK: - Chain

    /// One cumulative hash per wire segment, in the order the segment reaches the server.
    ///
    /// Segment 0 is the system prompt **plus** `toolSchemaText`, mirroring what both request
    /// builders actually do: they join every `.system` message and append the Harmony tool
    /// catalog to it — but only when the joined prompt does not already carry it. For a role
    /// step it always does (`PromptBuilder` renders the catalog into the system message via the
    /// `{toolCalling}` chip), so `toolSchemaText` is then empty and the catalog is counted once,
    /// inside the system prompt. `NativeLMStudioClient.toolSchemaTextForMeasurement` owns that
    /// rule for this surface and for `ContextBudgetPolicy.estimateTokens` alike. Either way the
    /// catalog IS in segment 0 — it is the largest fixed part of the prefix, so leaving it out
    /// would miss the single most expensive way a prefix can change (a tool appearing or
    /// disappearing mid-run, e.g. `filterForGitAvailability` reacting to a `git init`).
    ///
    /// Segment 0 always exists, even with no system message, so an empty conversation and a
    /// one-message conversation are never confused.
    static func chain(messages: [ChatMessage], toolSchemaText: String = "") -> [UInt64] {
        let systemPrompt = messages
            .filter { $0.role == .system }
            .compactMap(\.content)
            .joined(separator: "\n\n")

        var result: [UInt64] = []
        result.reserveCapacity(messages.count + 1)

        var running = fold(fnvOffsetBasis, systemPrompt)
        running = fold(running, toolSchemaText)
        result.append(running)

        for message in messages where message.role != .system {
            running = fold(running, segmentText(of: message))
            result.append(running)
        }
        return result
    }

    /// The wire-visible content of one non-system message.
    ///
    /// Deliberately EXCLUDES `toolCallID` and `ChatToolCall.id`: neither reaches either
    /// provider's wire (LM Studio flattens every turn into a labelled `input` string;
    /// `OllamaClient` re-materializes calls as `{"name":…,"arguments":…}` with no id), while
    /// both are freshly minted `UUID().uuidString` values. Hashing them would report a
    /// divergence the server cannot see — a false positive, which for a warning is the
    /// expensive direction to be wrong in.
    ///
    /// The calls themselves ARE folded, through `HarmonyToolCallEnvelope` — the same function
    /// both request builders render from, so what is hashed is exactly what ships, including
    /// the role gate (neither builder reads `toolCalls` outside its `.assistant` branch). Going
    /// through that function rather than folding `name`/`argumentsJSON` by hand is what keeps
    /// this type from carrying its own copy of a format it has to agree with.
    ///
    /// `isToolError` is likewise excluded: it routes error guidance in-process and is never
    /// serialized.
    ///
    /// Images are folded by shape (`mimeType` + payload length), not by payload. A screenshot is
    /// megabytes of base64 and appears in exactly one request before
    /// `runOneLLMToolIteration` strips it, so hashing it in full would be the most expensive
    /// thing this type does in exchange for distinguishing two images of identical byte length.
    ///
    /// The length is taken as `.utf8.count`, and the spelling is the whole point: `String.count`
    /// is O(graphemes) — it WALKS the payload, which is exactly what folding "by shape" exists to
    /// avoid, so until 2026-08-25 the cheap-by-design branch was paying the expensive-by-design
    /// cost, once per image per wire request. Native Swift strings store UTF-8, so `.utf8.count`
    /// is the stored length. The two agree on every value that can appear here — base64 is
    /// ASCII-only — which is what keeps `chain` and `chainAndTokens` in the byte-for-byte parity
    /// `PromptPrefixFingerprintTests.assertParity` asserts.
    private static func segmentText(of message: ChatMessage) -> String {
        var parts: [String] = [message.role.rawValue, message.content ?? ""]
        let toolCallText = HarmonyToolCallEnvelope.appendedWireText(for: message)
        if !toolCallText.isEmpty { parts.append(toolCallText) }
        for image in message.imageContent ?? [] {
            parts.append(image.mimeType)
            parts.append(String(image.base64Data.utf8.count))
        }
        // A separator that cannot appear in a role name, so ["a", "b"] and ["ab"] differ.
        return parts.joined(separator: "\u{1}")
    }

    // MARK: - Comparison

    /// Number of leading segments two chains share — i.e. how much of the prefix the server can
    /// still reuse. Equal chains return their full length.
    static func commonPrefixLength(_ lhs: [UInt64], _ rhs: [UInt64]) -> Int {
        var index = 0
        let limit = min(lhs.count, rhs.count)
        while index < limit, lhs[index] == rhs[index] {
            index += 1
        }
        return index
    }

    // MARK: - Fused chain + pricing

    /// `chain` and `ContextBudgetPolicy.estimateTokens` in ONE traversal of the
    /// conversation.
    ///
    /// `PromptPrefixLedger.record` needs both on every request, and
    /// `warnIfContextBudgetExceeded` needed the estimate again — three full
    /// scalar-by-scalar walks of a conversation that grows two messages per tool
    /// iteration, on EVERY iteration (the fingerprint walk itself is the
    /// detector's contract — it exists to catch prefix rewrites, so it can never
    /// trust "append-only" and skip bytes — but walking the same bytes three
    /// times bought nothing). Here the FNV fold counts scalar classes as it goes:
    /// an ASCII scalar is a byte under 0x80, any other scalar is exactly one
    /// non-continuation lead byte, so the counts equal
    /// `WorkFolderContextPromptPlanner.estimateTokens`'s per-scalar classes.
    ///
    /// Parity is pinned two ways (`PromptPrefixFingerprintTests`): `.chain` must
    /// equal `chain(messages:toolSchemaText:)` element-for-element, and
    /// `.totalPromptTokens` must equal
    /// `ContextBudgetPolicy.estimateTokens(messages:toolSchemaText:)` — including
    /// the per-string rounding granularity, which is why each priced part is
    /// ceiled separately below. Hash-only bytes (role labels, separators, image
    /// shape) are folded without pricing; price-only bytes (image base64, which
    /// `segmentText` deliberately folds by SHAPE) are counted without folding.
    struct ChainWithTokens {
        let chain: [UInt64]
        let totalPromptTokens: Int
    }

    static func chainAndTokens(messages: [ChatMessage],
                               toolSchemaText: String = "") -> ChainWithTokens {
        var total = WorkFolderContextPromptPlanner.estimateTokens(toolSchemaText)

        // Segment 0: hash folds the JOINED system prompt + schema text (identical
        // byte sequence to `chain`, since folding concatenated parts in order is
        // folding the concatenation); pricing ceils each system content and the
        // schema text separately, exactly as `estimateTokens` does.
        var result: [UInt64] = []
        result.reserveCapacity(messages.count + 1)
        var running = fnvOffsetBasis
        var first = true
        for message in messages where message.role == .system {
            guard let content = message.content else { continue }
            if !first { running = fold(running, "\n\n") }
            running = fold(running, content)
            first = false
            total += WorkFolderContextPromptPlanner.estimateTokens(content)
        }
        running = fold(running, toolSchemaText)
        result.append(running)
        // `estimateTokens` prices wire text and images for system messages too
        // (both are "" / empty in practice — priced here so the parity is exact
        // by construction, not by an assumption about system turns).
        for message in messages where message.role == .system {
            total += WorkFolderContextPromptPlanner.estimateTokens(
                HarmonyToolCallEnvelope.appendedWireText(for: message))
            for image in message.imageContent ?? [] {
                total += WorkFolderContextPromptPlanner.estimateTokensForBase64(image.base64Data)
            }
        }

        for message in messages where message.role != .system {
            // segmentText's parts, folded in order with its separators — no joined
            // copy is materialized. Content and wire text are the shared bytes:
            // folded AND counted in the same pass.
            running = fold(running, message.role.rawValue)
            running = fold(running, "\u{1}")
            let content = message.content ?? ""
            var ascii = 0, nonAscii = 0
            running = foldCounting(running, content, ascii: &ascii, nonAscii: &nonAscii)
            if message.content != nil {
                total += WorkFolderContextPromptPlanner.estimateTokens(
                    ascii: ascii, nonAscii: nonAscii)
            }
            let toolCallText = HarmonyToolCallEnvelope.appendedWireText(for: message)
            if !toolCallText.isEmpty {
                running = fold(running, "\u{1}")
                var wa = 0, wn = 0
                running = foldCounting(running, toolCallText, ascii: &wa, nonAscii: &wn)
                total += WorkFolderContextPromptPlanner.estimateTokens(ascii: wa, nonAscii: wn)
            }
            for image in message.imageContent ?? [] {
                running = fold(running, "\u{1}")
                running = fold(running, image.mimeType)
                running = fold(running, "\u{1}")
                running = fold(running, String(image.base64Data.utf8.count))
                total += WorkFolderContextPromptPlanner.estimateTokensForBase64(image.base64Data)
            }
            result.append(running)
        }
        return ChainWithTokens(chain: result, totalPromptTokens: total)
    }

    /// `fold`, also counting the string's scalar classes from its UTF-8 bytes:
    /// ASCII scalar = byte < 0x80; any other scalar = its single lead byte
    /// (`byte & 0xC0 != 0x80`). Continuation bytes hash but do not count.
    private static func foldCounting(_ seed: UInt64, _ string: String,
                                     ascii: inout Int, nonAscii: inout Int) -> UInt64 {
        var hash = seed
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* fnvPrime
            if byte < 0x80 {
                ascii += 1
            } else if byte & 0xC0 != 0x80 {
                nonAscii += 1
            }
        }
        return hash
    }
}
