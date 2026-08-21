import Foundation

/// Turns what the providers report about themselves into the flat, verbatim record a benchmark
/// row carries. Pure and `nonisolated` — every function takes what it transforms.
nonisolated enum BenchmarkProvenance {

    /// Every reported field, verbatim, keyed by its label.
    ///
    /// Deliberately untyped: the set of fields differs per provider and per build. A dictionary
    /// means a field a provider starts reporting tomorrow lands in the record without a schema
    /// change, and a field one provider lacks is simply absent rather than defaulted to something
    /// that reads as a measurement. That design paid off on 2026-08-19, when LM Studio turned out
    /// to report engine versions after all — see `provenanceFields`.
    static func serverFields(from details: ModelLoadDetails?) -> [String: String] {
        guard let details else { return [:] }
        var out: [String: String] = [:]
        for field in details.fields where !field.value.isEmpty {
            out[field.label] = field.value
        }
        return out
    }

    /// Sampling parameters, when the provider reports them.
    ///
    /// A provider asymmetry, not a gap: Ollama returns a modelfile block
    /// (`temperature 1\ntop_k 20\n…`) from `/api/show`, while LM Studio reports nothing at all
    /// because its per-model config is server-side only. Empty is the honest answer there —
    /// filling it with the app's defaults would claim the server used values it never told us
    /// about.
    static func samplingParameters(from details: ModelLoadDetails?) -> [String: String] {
        guard let block = details?.value(for: ModelLoadDetails.modelfileParametersLabel)
        else { return [:] }
        return parseModelfileParameters(block)
    }

    /// Splits `name value` lines. Values keep their internal spacing; a line with no value is
    /// skipped rather than stored as an empty string, which would read as "the server said empty".
    static func parseModelfileParameters(_ block: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in block.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(where: \.isWhitespace) else { continue }
            let name = String(trimmed[..<separator])
            let value = trimmed[separator...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.isEmpty else { continue }
            out[name] = value
        }
        return out
    }

    /// What clearing the machine achieved, as provenance rows.
    ///
    /// Recorded even when nothing was cleared: "already alone" and "could not check" are
    /// different facts about a measurement, and only one of them means the figure is trustworthy.
    ///
    /// `Residency` describes the TARGET's server and always has. The second key is what stops that
    /// from reading as a statement about the machine: on a Mac both providers draw from the same
    /// unified memory, so a row whose target server was spotless can still have been measured
    /// beside a 21 GB model on the other one. Present only when the run named another server at
    /// all — an absent key means nothing was claimed, which is honest; an "n/a" would be a claim.
    static func residencyFields(
        _ report: BenchmarkResidencyPreparer.Report
    ) -> [String: String] {
        var out = ["Residency": report.summary]
        if !report.unloadedModels.isEmpty {
            out["Unloaded for this run"] = report.unloadedModels.sorted().joined(separator: ", ")
        }
        if !report.otherServers.isEmpty {
            out["Residency (other servers)"] = report.otherServers
                .map { "\($0.server.displayLabel): \($0.summary)" }
                .joined(separator: "; ")
        }
        // The target's own warning first, then the others', so the most relevant one is not
        // pushed off the end of a truncated cell — and joined rather than replaced, because a
        // machine where two evictions were refused is a worse machine than one where a single
        // eviction was, and a single-slot field cannot say so.
        let warnings = [report.failure].compactMap { $0 }
            + report.otherServers.compactMap(\.failure)
        if !warnings.isEmpty {
            out["Residency warning"] = warnings.joined(separator: "; ")
        }
        return out
    }

    /// What the server said about ITSELF, as provenance rows.
    ///
    /// The two engine keys are deliberately different sentences, and that is the whole honesty
    /// mechanism of this function. `listEngines` answers "what is installed on this machine" —
    /// on a Mac that is both llama.cpp and MLX, and choosing between them by the model's file
    /// format would be an inference dressed as a measurement. The probe request answers "what
    /// served a completion on this model, seconds ago", which is a different and stronger claim.
    /// Neither is ever written under a bare `"Engine"`, because a reader would take that for the
    /// engine of the measured samples.
    static func provenanceFields(
        _ provenance: ServerProvenance,
        servingEngine: ServerProvenance.Engine?
    ) -> [String: String] {
        var out: [String: String] = [:]
        if let build = provenance.build, !build.isEmpty {
            out["Server build"] = build
        }
        if !provenance.installedEngines.isEmpty {
            out["Engines installed"] = provenance.installedEngines
                .map(\.label).sorted().joined(separator: ", ")
        }
        if let servingEngine {
            out["Engine (probe request)"] = servingEngine.label
        }
        return out
    }

    /// Whether the output ceiling the request asked for actually held, read back from the token
    /// counts the run already records.
    ///
    /// Exists because the two providers disagree about how a rejected key behaves. LM Studio's
    /// `/api/v1/chat` is strict — an unknown key is HTTP 400, so a wrong name cannot pass
    /// unnoticed. Ollama ignores options it does not recognise, so there a wrong name would leave
    /// the run silently uncapped and comparable with nothing. This turns that silence into a
    /// recorded fact: the samples say how many tokens actually came back, and a count above the
    /// ceiling is proof the server did not honour it.
    ///
    /// Nil when there is nothing to say — no ceiling requested, or no sample reported a count.
    /// A sample AT the ceiling is honoured, not violated: a server that stops exactly on the
    /// limit is doing what it was asked.
    static func outputCapField(
        requested: Int?,
        measuredSamples: [GenerationBenchmarkSample]
    ) -> [String: String] {
        guard let requested, requested > 0 else { return [:] }
        let counts = measuredSamples.compactMap(\.outputTokens)
        guard let highest = counts.max() else { return [:] }
        if highest > requested {
            return ["Output cap": "\(requested) requested — NOT honoured (a sample returned \(highest))"]
        }
        // Where the server SAYS why it stopped, say that instead of inferring it. Reading the
        // counts back can only ever catch a server exceeding the ceiling; it cannot tell a run
        // that finished on its own from one cut off exactly at the limit, and those are different
        // workloads. `"length"` on any measured sample means the cap bound the run.
        let reasons = Set(measuredSamples.compactMap(\.doneReason))
        guard !reasons.isEmpty else { return ["Output cap": "\(requested) tokens"] }
        return [
            "Output cap": reasons.contains("length")
                ? "\(requested) tokens — reached, generation was cut off there"
                : "\(requested) tokens — not reached, the model stopped on its own",
        ]
    }

    // Residency deliberately has no function here. It used to be inferred from the warm-up's
    // reported load time, as a fallback for a server that would not answer a listing; since the
    // warm-up is stopped as soon as it is decoding (`BenchmarkWarmUpPolicy`) it never reaches the
    // terminal frame that number rides in, so the inference could only ever have returned its
    // no-evidence answer. `GenerationBenchmarkRunner` records what `BenchmarkResidencyPreparer`
    // saw on the server instead — a measurement rather than an inference from a missing one.
}
