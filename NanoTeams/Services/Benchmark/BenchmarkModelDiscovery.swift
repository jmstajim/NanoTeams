import Foundation

/// What one server said when asked for its chat models.
///
/// Three cases rather than an optional array, because all three are things a sweep must say
/// differently. `[]` inside `.answered` is a fact ABOUT the server; `.noAnswer` is the absence of
/// one; `.undetermined` is the absence of a question. Collapsing any pair reproduces the mistake
/// `LoadedInstanceListing` was split to end (`.listed` vs `.unsupported`) — there, silence read as
/// absence and a run recorded `Residency: already alone` about a machine nobody had asked.
nonisolated enum BenchmarkDiscoveryOutcome: Equatable, Sendable {
    /// The server RETURNED a list. An empty one means it offers no chat models — a different
    /// statement from not having answered, and one that still earns the server a clearing pass,
    /// because `fetchModels` filters embedders out and an embedder holds real memory.
    case answered([String])
    /// A lookup happened and no list came back. `detail` carries whatever the fetch captured — a
    /// 401, a decode mismatch — when there was one. Deliberately never worded as "offline" at any
    /// render site: a server that refuses an unauthorized request is running perfectly well.
    case noAnswer(detail: String?)
    /// No answer was OBSERVED, which is not the same as no answer existing. `ModelCatalog.refresh`
    /// returns false immediately when a fetch for the same key is already in flight — it did not
    /// wait for it, so it saw nothing. Rendering that as "this server has no models" would be a
    /// claim about a server nobody heard from; the row asks for a rescan instead.
    case undetermined
}

/// Asks one server what chat models it offers.
///
/// A protocol rather than a direct `ModelCatalog` dependency so the sweep's planning and
/// sequencing are testable with no catalog, no client and no network — the fake answers in three
/// lines. Narrow on purpose (ISP): a sweep needs exactly this one question answered.
@MainActor
protocol BenchmarkModelDiscovering {
    func chatModels(on server: BenchmarkServer) async -> BenchmarkDiscoveryOutcome

    /// Whether the server answers at all — one GET, no model enumeration.
    ///
    /// A second, cheaper question than `chatModels` because it is asked far more often: before
    /// every target, as a cost governor. The expensive shape it prevents is a server that accepts
    /// connections and never replies, where each of `repeats + 1` requests waits out
    /// `llmRequestTimeoutSeconds` — 600 by default, and settable to "forever". That is up to an
    /// hour per model, on every model left in the plan.
    ///
    /// Deliberately not expressed as "did `chatModels` succeed": on Ollama that call fans out an
    /// `/api/show` per model in the catalogue, which is a heavy way to ask whether a socket is
    /// open, and paying it before every target would cost more than it saves on a healthy machine.
    func isAnswering(_ server: BenchmarkServer) async -> Bool
}

/// The production adapter: the app's shared model-list cache, which is also what fills the model
/// pickers, so a scan warms exactly the state the rest of the screen reads.
@MainActor
struct ModelCatalogDiscovery: BenchmarkModelDiscovering {

    let catalog: ModelCatalog

    /// The same path the status pill probes (`LLMProvider.reachabilityProbePath`), with the same
    /// bearer resolution — so a server behind LM Studio's "Require Authentication" answers here
    /// exactly as it does everywhere else in the app.
    func isAnswering(_ server: BenchmarkServer) async -> Bool {
        await LLMConnectionChecker.check(
            baseURL: server.baseURLString, provider: server.provider)
    }

    func chatModels(on server: BenchmarkServer) async -> BenchmarkDiscoveryOutcome {
        let refreshed = await catalog.refresh(
            url: server.baseURLString, provider: server.provider)
        return BenchmarkDiscoveryClassifier.classify(
            refreshed: refreshed,
            hasLoaded: catalog.hasLoaded(server.baseURLString, provider: server.provider),
            models: catalog.models(for: server.baseURLString, provider: server.provider),
            error: catalog.error(for: server.baseURLString, provider: server.provider))
    }
}

/// Reads a model-list lookup and says what it proved.
///
/// A `nonisolated` namespace of its own rather than a static on the adapter: it touches no
/// main-actor state, and the whole point of extracting it is that the four-way decision can be
/// exercised in a table test without a catalog, a client, or an actor hop.
nonisolated enum BenchmarkDiscoveryClassifier {

    /// `refreshed == true` is positive proof: the model-list path and the reachability probe path
    /// are the same URL on both providers, so a returned list IS a 2xx from the address the status
    /// pill probes.
    ///
    /// `false` is the interesting half, and `ModelCatalog.refresh`'s own doc says it claims
    /// NOTHING — *"callers may only use `true` to turn reachability ON, never OFF"*. The fetch may
    /// have failed, or it may have returned immediately because a lookup for the same key was
    /// already in flight, in which case this call observed nothing at all. So `false` is split by
    /// what else the catalog holds: a captured error means the lookup failed; a cached list means
    /// an earlier lookup succeeded and this one merely arrived late; and with neither, the honest
    /// answer is that we did not hear — never that the server was silent.
    static func classify(
        refreshed: Bool, hasLoaded: Bool, models: [String], error: String?
    ) -> BenchmarkDiscoveryOutcome {
        if refreshed { return .answered(models) }
        if let error, !error.isEmpty { return .noAnswer(detail: error) }
        if hasLoaded { return .answered(models) }
        return .undetermined
    }
}
