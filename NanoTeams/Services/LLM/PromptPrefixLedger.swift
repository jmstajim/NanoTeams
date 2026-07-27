import Foundation

/// Remembers what each caller last sent to each `(server, model)`, so the next request can be
/// told whether the server's prompt-prefix (KV) cache can still be reused.
///
/// **Why the key includes the OWNER.** The obvious design — one slot per `(server, model)`,
/// "whoever sent last" — is unsound in this app. `TeamEngine` starts ready roles concurrently
/// (CLAUDE.md #45) and `ChatModelEnsurer` tracks `openRequests` as a *count, not a flag*,
/// precisely because "parallel roles legitimately stream against the same model". With N
/// requests in flight on one key:
///
/// 1. Both clients send from a `Task.detached`, so the record lands on the global executor after
///    `streamChat` has already returned. Two roles calling in order A,B can record B,A — the
///    "previous request" would be chosen by scheduling, not by send order.
/// 2. A server that serves concurrent streams keeps more than one cache slot, so another
///    caller's request does not imply eviction anyway.
///
/// Keying per owner makes the comparison owner-against-itself. A step's tool loop is serial
/// within itself, so that comparison is deterministic no matter how the executor interleaves —
/// and it answers the question that IS sound: "did *we* break our own prefix".
///
/// Eviction by someone else is a separate, *measured* claim (`PrefixCachePolicy.resolve`): it is
/// only ever reported when the server confirms it re-processed the prompt, and the interleaving
/// caller is then named as a suspect rather than as a verdict.
///
/// An `actor` rather than a lock: `record` is a read-compare-write that must not interleave, and
/// every caller is already `async`.
actor PromptPrefixLedger {

    // MARK: - Stored

    private struct OwnerEntry {
        /// The `LLMCallOwner.key` half of the composite dictionary key, stored so `forgetOwner`
        /// can select by owner by EQUALITY across every `(server, model)`. Parsing it back out of
        /// the composite would be a guess: the composite is `base|model|owner`, and while
        /// `normalizedBaseURL` cannot contain `|`, nothing constrains a model name.
        var ownerKey: String
        var chain: [UInt64]
        var seq: UInt64
    }

    private struct ModelEntry {
        /// Recent callers on this model, oldest first. Bounded — it exists only to name a
        /// suspect, so history beyond the last few requests is worthless.
        var activity: [(owner: String, seq: UInt64)] = []
        /// Lowest server-reported ns-per-prefilled-token ever seen: the warm floor.
        var prefillFloorNsPerToken: Double?
        /// Prompt depth at which that minimum was sampled. The rate is roughly
        /// `overhead / depth` on a cache hit, so the floor is only meaningful against requests
        /// of a comparable size — see `PrefixCachePolicy.comparableDepthFraction`.
        var prefillFloorPromptTokens: Int?
        var prefillSampleCount: Int = 0
    }

    private static let activityWindow = 8

    private var owners: [String: OwnerEntry] = [:]
    private var models: [String: ModelEntry] = [:]

    /// Ordering token for `suspect` and for LRU eviction, assigned INSIDE the actor.
    ///
    /// Deliberately not a clock. Both uses are pure ORDERING — nothing here measures an interval,
    /// nothing renders or persists it — and a stamp could not express that ordering correctly at
    /// this seam anyway: a default argument (`Date()`, and `MonotonicClock.shared.now()` equally)
    /// is evaluated at the CALL SITE, before the hop onto this actor, while `record` holds the
    /// actor across two full passes over the conversation (`estimateTokens` and `chain`). Two
    /// callers can therefore stamp in one order and land in the other, which is exactly the
    /// comparison `suspect` depends on. A counter taken under isolation cannot disagree with the
    /// order records actually arrived in, and it is immune to the wall-clock/monotonic mixing trap
    /// (CLAUDE.md Грабли 2026-07-18) because there is no clock left to mix.
    private var sequence: UInt64 = 0

    // MARK: - Keys

    /// `String.normalizedBaseURL` is the single canonicalizer in this codebase (the Keychain
    /// account key, the model-list cache, `ChatModelEnsurer`'s census and `referencesModel` all
    /// delegate to it). Divergence here would silently split one server into two.
    static func modelKey(baseURL: String, model: String) -> String {
        "\(baseURL.normalizedBaseURL)|\(model)"
    }

    static func ownerKey(baseURL: String, model: String, owner: LLMCallOwner) -> String {
        "\(modelKey(baseURL: baseURL, model: model))|\(owner.key)"
    }

    // MARK: - Recording

    /// What one request observed about the cache it was about to use.
    struct Observation: Sendable {
        /// The structural half — what we can prove about our own bytes.
        var structural: PrefixCachePolicy.Verdict
        /// The last DIFFERENT caller seen on this model since this owner's previous request, if
        /// any. A lead for `serverDroppedCache`, never a verdict on its own.
        var suspect: String?
        /// Tokens the server must re-process if the structural verdict is a miss.
        var discardedTokens: Int
        /// Estimated size of the whole request, used when the server later reports it
        /// re-processed everything.
        var totalPromptTokens: Int
        /// Tokens this request APPENDED beyond what the previous one already sent — the segments
        /// the server has never seen. A cache hit legitimately pays for these, so the
        /// prefill-rate comparison in `PrefixCachePolicy.resolve` is only meaningful while they
        /// stay small. 0 on a first request and on a miss (where the whole prefix is the cost).
        var appendedTokens: Int
        /// The warm floor, the depth it was sampled at, and its sample count, for
        /// `PrefixCachePolicy.resolve`.
        var warmFloorNsPerToken: Double?
        var warmFloorPromptTokens: Int?
        var floorSampleCount: Int
    }

    /// Fingerprint this request, compare it against this owner's previous one, and remember it.
    ///
    /// One-shot owners are recorded in the model's activity (so they can be named as suspects)
    /// but keep no chain: their conversation is genuinely new every time, so `.firstRequestForOwner`
    /// is the honest verdict rather than a manufactured miss.
    func record(
        baseURL: String,
        model: String,
        owner: LLMCallOwner,
        messages: [ChatMessage],
        toolSchemaText: String
    ) -> Observation {
        let mKey = Self.modelKey(baseURL: baseURL, model: model)
        let oKey = Self.ownerKey(baseURL: baseURL, model: model, owner: owner)

        // Taken here, under actor isolation, so the token's order IS the order the records land
        // in — see `sequence`.
        sequence += 1
        let seq = sequence

        var modelEntry = models[mKey] ?? ModelEntry()
        let previous = owners[oKey]

        let suspect = Self.suspect(
            in: modelEntry.activity, excluding: owner.key, since: previous?.seq)

        modelEntry.activity.append((owner: owner.key, seq: seq))
        if modelEntry.activity.count > Self.activityWindow {
            modelEntry.activity.removeFirst(modelEntry.activity.count - Self.activityWindow)
        }
        models[mKey] = modelEntry

        let totalTokens = ContextBudgetPolicy.estimateTokens(
            messages: messages, toolSchemaText: toolSchemaText)

        guard owner.accumulatesPrefix else {
            return Observation(
                structural: .firstRequestForOwner,
                suspect: suspect,
                discardedTokens: 0,
                totalPromptTokens: totalTokens,
                appendedTokens: 0,
                warmFloorNsPerToken: modelEntry.prefillFloorNsPerToken,
                warmFloorPromptTokens: modelEntry.prefillFloorPromptTokens,
                floorSampleCount: modelEntry.prefillSampleCount)
        }

        let chain = PromptPrefixFingerprint.chain(
            messages: messages, toolSchemaText: toolSchemaText)

        // Compare first with a placeholder cost, then price only the segments that were actually
        // discarded — estimating tokens is the expensive half and is pointless on a hit.
        let probe = PrefixCachePolicy.compare(
            previous: previous?.chain, current: chain, discardedTokens: 0)
        var verdict = probe
        var discarded = 0
        var appended = 0
        if let diagnosis = probe.diagnosis {
            discarded = PrefixCachePolicy.discardedTokens(
                messages: messages,
                toolSchemaText: toolSchemaText,
                commonSegments: diagnosis.commonSegments)
            var priced = diagnosis
            priced.discardedTokens = discarded
            verdict = .missed(priced)
        } else if case .reused(let segments) = probe {
            // The same slice, read the other way round: everything from the first UNCACHED
            // segment on. On a reuse those are exactly the segments this request appended, and
            // the server pays for them even on a perfect hit — which is what makes the
            // prefill-rate branch in `resolve` uninterpretable once they grow. Walks only the
            // tail, so a hit still never prices the whole conversation.
            appended = PrefixCachePolicy.discardedTokens(
                messages: messages,
                toolSchemaText: toolSchemaText,
                commonSegments: segments)
        }

        owners[oKey] = OwnerEntry(ownerKey: owner.key, chain: chain, seq: seq)
        pruneOwnersIfNeeded()

        return Observation(
            structural: verdict,
            suspect: suspect,
            discardedTokens: discarded,
            totalPromptTokens: totalTokens,
            appendedTokens: appended,
            warmFloorNsPerToken: modelEntry.prefillFloorNsPerToken,
            warmFloorPromptTokens: modelEntry.prefillFloorPromptTokens,
            floorSampleCount: modelEntry.prefillSampleCount)
    }

    /// Most recent caller that is not `excluding`, and — when we have a previous request to
    /// anchor to — that was RECORDED after it. Ordering is `seq`, never a clock: see `sequence`.
    /// Without the anchor any historical caller would look like a suspect forever.
    private static func suspect(
        in activity: [(owner: String, seq: UInt64)],
        excluding ownerKey: String,
        since: UInt64?
    ) -> String? {
        for entry in activity.reversed() where entry.owner != ownerKey {
            if let since, entry.seq <= since { return nil }
            return entry.owner
        }
        return nil
    }

    // MARK: - Warm floor

    /// Feed a server-measured prefill rate. Tracks the MINIMUM, which is the warm case: a cache
    /// hit is the fastest this model can possibly prefill on this machine.
    ///
    /// `promptTokens` is recorded ALONGSIDE the minimum, not merely counted: the rate is roughly
    /// `overhead / depth` on a hit, so a floor sampled at 13k tokens says nothing about a 900
    /// token request. `PrefixCachePolicy.isComparableDepth` is what consumes it.
    func noteServerPrefill(
        baseURL: String, model: String, nsPerToken: Double, promptTokens: Int
    ) {
        // A sample whose depth is unknown is unusable, not merely imprecise: it would be stored
        // as the floor's depth, and `isComparableDepth` refuses a non-positive `floorTokens` —
        // so one such sample would silently retire the whole branch for this model until a
        // strictly FASTER sample happened to replace it. Dropping it keeps the failure to "one
        // fewer sample", which the `minimumPrefillSamplesForFloor` gate already tolerates.
        // Unreachable in production (`ServerPrefillReport.nsPerToken` is nil unless
        // `promptTokens > 0`), which is exactly why it must not depend on staying unreachable.
        guard nsPerToken > 0, promptTokens > 0 else { return }
        let key = Self.modelKey(baseURL: baseURL, model: model)
        var entry = models[key] ?? ModelEntry()
        entry.prefillSampleCount += 1
        if entry.prefillFloorNsPerToken.map({ nsPerToken < $0 }) ?? true {
            entry.prefillFloorNsPerToken = nsPerToken
            entry.prefillFloorPromptTokens = promptTokens
        }
        models[key] = entry
    }

    /// Drop EVERY `(server, model)` chain this owner holds.
    ///
    /// The seam is **"this caller is starting a conversation from scratch"**, not "this caller is
    /// gone". `LLMCallOwner.step`'s key is `step:<taskID>:<roleID>` and `StepExecution.id` IS the
    /// role id, so the key outlives every run of the task and every `restartRole` while the
    /// conversation does not. Called from
    /// `LLMExecutionService.forgetPrefixChainForFreshConversation`, at the one place that already
    /// knows replay-from-fresh (`ConversationReplay.resume(from:) == nil`).
    ///
    /// Scoped by OWNER rather than by `(server, model)` because a fresh conversation invalidates
    /// the comparison on every server this owner ever used — a role's `llmOverride` edited
    /// between runs, or `preflightCheck` falling back to the global, moves the key, and a keyed
    /// drop would clear the new slot while leaving the stale chain live under the old one. It is
    /// also what lets the call site sit BEFORE config resolution, where no wrong key exists to
    /// pick.
    ///
    /// A full scan, bounded by `maxTrackedOwners` and run once per step start — not per request,
    /// where `record` already walks the whole conversation twice.
    func forgetOwner(_ owner: LLMCallOwner) {
        owners = owners.filter { $0.value.ownerKey != owner.key }
    }

    /// Chains are one `UInt64` per message and every step that ever ran leaves one behind, so
    /// without a bound a long-lived process accumulates them. Evicting the least recently used
    /// is safe: the worst an evicted owner can suffer is one `.firstRequestForOwner`, which is
    /// never reported.
    private static let maxTrackedOwners = 512

    private func pruneOwnersIfNeeded() {
        guard owners.count > Self.maxTrackedOwners else { return }
        let sorted = owners.sorted { $0.value.seq < $1.value.seq }
        for (key, _) in sorted.prefix(owners.count - Self.maxTrackedOwners) {
            owners.removeValue(forKey: key)
        }
    }

}
