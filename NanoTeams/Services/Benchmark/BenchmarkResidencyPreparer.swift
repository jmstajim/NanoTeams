import Foundation

/// Puts the MACHINE into a known state before a benchmark: exactly one model resident anywhere the
/// app can see, and it is the one being measured.
///
/// This is the app's version of `benchmark_prompt_processing.sh`'s H1 check. Its comment there is
/// the whole justification — *"a co-resident 21GB model swaps and poisons every timing"*. Two
/// models sharing the machine compete for memory bandwidth and, on a Mac, for unified memory
/// itself; a figure taken in that state describes the pair, not the model.
///
/// Scope used to be one server — the target's — which made the check answer a narrower question
/// than it appeared to (`DEBTS.md` D-B1 §2): a model resident in Ollama depressed every figure
/// measured on LM Studio, and `Residency` said nothing about it because it described the target's
/// server alone. Callers now pass the OTHER servers they know of, and each is emptied outright:
/// nothing on them is being measured, so there is no all-but-one to preserve.
///
/// The listing is the proof, and that is what keeps this from guessing. A caller may hand over an
/// address nobody has confirmed a server at (a provider's documented default, say); this asks it
/// for a model list first and does nothing at all unless it answers with one. No unload command is
/// ever fired at an address that has not just identified itself as a server.
///
/// Pure orchestration over `LLMClient`, `nonisolated`, no state: what it did is returned rather
/// than stored, so the run record can carry it and the user can see it happened.
nonisolated enum BenchmarkResidencyPreparer {

    /// What preparation actually achieved. Recorded verbatim into the run's provenance — a
    /// benchmark that could NOT clear the machine is still worth running, but the reader has to
    /// know which of the two it was.
    struct Report: Equatable, Sendable {
        /// Models evicted to make room. Empty when nothing else was resident.
        var unloadedModels: [String] = []
        /// The target was already in memory, so this run did not pay to load it.
        var targetWasResident = false
        /// The server answered the residency question at all. False means the provider exposes no
        /// listing, or the probe failed — in which case nothing was cleared and the figures may be
        /// contaminated by whatever else is loaded.
        var couldInspect = false
        /// Non-nil when eviction was attempted and refused. The run continues: a benchmark that
        /// aborts because housekeeping failed is less useful than one that reports the caveat.
        var failure: String?
        /// The server's own identifier for the resident target, when it names instances.
        /// Recorded so a row says WHICH instance was measured — without it, an engine attributed
        /// to "this model" has nothing to be attributed to.
        var targetInstanceID: String?
        /// The app loaded the target during preparation, as opposed to finding it already there.
        var didLoadTarget = false
        /// One entry per OTHER server the caller named and that was not the target's own, in the
        /// order they were cleared. Empty means the caller named none — never that none were
        /// found, which is what `couldInspect == false` on an entry says.
        var otherServers: [OtherServerReport] = []

        /// Whether the target is known to be in memory now — the precondition for any probe that
        /// spends a request. Deliberately requires `couldInspect`: "we could not look" is not
        /// evidence of residency, and treating it as such is what would let a provenance probe
        /// trigger a load outside the app's own model lifecycle.
        var targetResidentAfterPrepare: Bool {
            couldInspect && (targetWasResident || didLoadTarget)
        }

        var summary: String {
            guard couldInspect else { return "not verified" }
            if unloadedModels.isEmpty {
                return targetWasResident ? "already alone, resident" : "already alone"
            }
            return "unloaded \(unloadedModels.count) other "
                + (unloadedModels.count == 1 ? "model" : "models")
        }
    }

    /// What clearing one server that holds no target achieved.
    ///
    /// Separate from `Report` rather than a second instance of it, because the two answer
    /// different questions and share only the verb. There is no target here to preserve, to find
    /// resident, or to load — every model on such a server is competing with the measurement and
    /// none of them is it. A shared type would carry three fields that can only ever be false, and
    /// a reader would rightly wonder what a `targetWasResident` on a server with no target meant.
    struct OtherServerReport: Equatable, Sendable {
        var server: BenchmarkServer
        /// Everything evicted here. Empty with `couldInspect` true means the server was already
        /// holding nothing.
        var unloadedModels: [String] = []
        /// The server answered the residency question at all. False means no server answered at
        /// that address, or it exposes no listing — and then nothing was touched there.
        var couldInspect = false
        /// Non-nil when an eviction was attempted and refused. Like the target's own, this never
        /// aborts the run: the caveat is worth more than the missing measurement.
        var failure: String?

        var summary: String {
            guard couldInspect else { return "not verified" }
            guard !unloadedModels.isEmpty else { return "already clear" }
            return "unloaded \(unloadedModels.count) "
                + (unloadedModels.count == 1 ? "model" : "models")
        }
    }

    /// Empties every server in `otherServers`, then evicts every model on the target's own server
    /// except the target itself, then makes sure the target is loaded where the provider lets us
    /// say so.
    ///
    /// `otherServers` is a required argument with no default. An empty array is a legitimate
    /// answer — the caller knows of no other server — but it has to be given, because the value
    /// that would be defaulted is the one that reinstates the defect: a run that clears only its
    /// own server and reports `Residency` as if that covered the machine.
    ///
    /// Others are cleared FIRST. Where the app is allowed to place a load (LM Studio), the target
    /// should land on a machine already as empty as this pass can make it, rather than alongside a
    /// model that is about to be evicted anyway.
    ///
    /// An entry naming the target's own address is skipped, not deduplicated by provider: two
    /// providers configured at one address is a misconfiguration, and treating them as two
    /// machines would empty the one the target lives on.
    static func prepare(
        target: BenchmarkTarget,
        otherServers: [BenchmarkServer],
        client: any LLMClient
    ) async -> Report {
        var report = Report()

        var visited: Set<String> = [target.server.baseURLString.normalizedBaseURL]
        for server in otherServers {
            let address = server.baseURLString.normalizedBaseURL
            // A blank address is not a server; asking about it would throw `invalidBaseURL` and
            // record "not verified" about a machine the caller never named.
            guard !address.isEmpty, visited.insert(address).inserted else { continue }
            report.otherServers.append(await clear(server, client: client))
        }

        // Two things had to be said out loud for this to be an answer rather than a formality,
        // and their absence was one defect wearing two hats.
        //
        // `provider`: without it the router had nothing to dispatch on and sent every listing to
        // the LM Studio client, which asks an Ollama server for `/api/v0/models`.
        //
        // `.listed` vs `.unsupported`: Ollama answers that path `404 page not found`, and the LM
        // Studio client's 404 branch — written for an older LM Studio that lacks the route —
        // returned an empty list. `couldInspect` went true and the run stamped "already alone"
        // onto a machine nobody had asked. This is the ONE caller for which the two are different
        // facts, which is why it is the one that switches instead of taking `.adoptable`.
        let resident: [LoadedModelInstance]
        switch try? await client.listLoadedInstances(
            provider: target.provider, baseURLString: target.baseURLString) {
        case .listed(let instances): resident = instances
        case .unsupported, nil: return report
        }
        report.couldInspect = true

        let wanted = target.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        for instance in resident where instance.modelName != wanted {
            do {
                try await client.unloadModel(
                    provider: target.provider,
                    instanceID: instance.instanceID, baseURLString: target.baseURLString)
                report.unloadedModels.append(instance.modelName)
            } catch {
                report.failure = "could not unload \(instance.modelName): "
                    + error.localizedDescription
            }
        }

        report.targetWasResident = resident.contains { $0.modelName == wanted }
        report.targetInstanceID = resident.first { $0.modelName == wanted }?.instanceID

        // Only where the app is allowed to load: on Ollama the model loads on first use, and
        // `LLMProvider.managesModelResidency` is the app-wide statement of who owns that.
        if !report.targetWasResident, target.provider.managesModelResidency {
            do {
                report.targetInstanceID = try await client.loadModel(
                    provider: target.provider,
                    modelName: wanted, baseURLString: target.baseURLString)
                report.didLoadTarget = true
            } catch {
                report.failure = "could not load \(wanted): " + error.localizedDescription
            }
        }
        return report
    }

    /// Empties one server that holds no target.
    ///
    /// Everything, not all-but-one: the target is not here, so every resident model is competing
    /// with the measurement and none of them is the measurement. Nothing is ever loaded here for
    /// the same reason.
    ///
    /// The listing comes first and decides everything. `.unsupported` or a throw returns with
    /// `couldInspect` false and NO command sent — which is what makes it safe to pass an address
    /// that is only a provider's documented default: an address with nothing behind it produces a
    /// recorded "not verified", never an unload aimed at whatever else might be listening.
    private static func clear(
        _ server: BenchmarkServer, client: any LLMClient
    ) async -> OtherServerReport {
        var report = OtherServerReport(server: server)

        let resident: [LoadedModelInstance]
        switch try? await client.listLoadedInstances(
            provider: server.provider, baseURLString: server.baseURLString) {
        case .listed(let instances): resident = instances
        case .unsupported, nil: return report
        }
        report.couldInspect = true

        for instance in resident {
            do {
                try await client.unloadModel(
                    provider: server.provider,
                    instanceID: instance.instanceID, baseURLString: server.baseURLString)
                report.unloadedModels.append(instance.modelName)
            } catch {
                report.failure = "could not unload \(instance.modelName) on "
                    + server.displayLabel + ": " + error.localizedDescription
            }
        }
        return report
    }
}
