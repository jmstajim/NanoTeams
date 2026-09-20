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
        // The benchmark's OWN verdict first, because it is the one that works on both providers:
        // a sample the guard cut is voided `.outputCeilingReached`, decided from the token counts
        // in `GenerationSampleRecorder`. LM Studio sends no stop reason at all on its streaming
        // route, so a field keyed on `doneReason` was blind exactly where the truncation defect
        // was found.
        let cut = measuredSamples.count { $0.void == .outputCeilingReached }
        if cut > 0 {
            return [
                "Output cap": "\(requested) tokens — reached by \(cut) of "
                    + "\(measuredSamples.count) samples, which are therefore not measured",
            ]
        }
        // Then the OTHER output bound, and it is a different fact with a different fix: the
        // server stopped for length somewhere below the ceiling this run asked for, so what
        // ended the answer is the server's own context window. Reporting it as the cap being
        // "reached" — which is what this field did until the rung existed — points the user at
        // a ceiling that was never touched.
        let windowed = measuredSamples.count { $0.void == .contextWindowReached }
        if windowed > 0 {
            return [
                "Output cap": "\(requested) tokens — not reached; the server ended \(windowed) of "
                    + "\(measuredSamples.count) samples at its own context window, which are "
                    + "therefore not measured",
            ]
        }
        // Where the server SAYS why it stopped, say that too — a second opinion on the same fact,
        // and the only one available for a sample that stopped at the ceiling without being
        // voided (a provider that overshoots, or a legacy row recorded before either rung).
        //
        // `highest == requested` is what licenses the word "reached": by here no sample was
        // voided for either bound, so a bare `length` alone cannot say WHICH bound it hit, and
        // on a legacy row it is the only evidence there is.
        let reasons = Set(measuredSamples.compactMap(\.doneReason))
        guard !reasons.isEmpty else { return ["Output cap": "\(requested) tokens"] }
        if !reasons.contains(StreamEvent.lengthDoneReason) {
            return ["Output cap": "\(requested) tokens — not reached, the model stopped on its own"]
        }
        return [
            "Output cap": highest == requested
                ? "\(requested) tokens — reached, generation was cut off there"
                : "\(requested) tokens — not reached; a sample stopped at \(highest) and the "
                + "server reported it as cut off, so something below this ceiling bounded it",
        ]
    }

    // Residency deliberately has no function here. It used to be inferred from the warm-up's
    // reported load time, as a fallback for a server that would not answer a listing. Since
    // 2026-09-20 the warm-up is bounded on the wire rather than cancelled, so it DOES reach the
    // terminal frame that number rides in and the inference is available again — and it is still
    // not taken. `GenerationBenchmarkRunner` records what `BenchmarkResidencyPreparer` saw on the
    // server: a measurement of residency beats an inference from a load time, which reads the
    // same whether a model was absent or merely slow to warm.
}
