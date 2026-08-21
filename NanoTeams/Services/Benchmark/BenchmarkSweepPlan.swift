import Foundation

/// Turns what the scan found into the ordered list of measurements a sweep will make.
///
/// Pure and `nonisolated`: it takes rows and returns entries, so every ordering and exclusion rule
/// below is testable by handing it two servers.
nonisolated enum BenchmarkSweepPlan {

    /// The measurements, in the order they will be taken.
    ///
    /// **Provider-major, server-consecutive.** Every model on one server is measured before any
    /// model on the other, and that is load-bearing rather than tidy: each run clears the OTHER
    /// servers first, so a plan that alternated between two servers would evict and re-load a
    /// whole model between every neighbouring pair of measurements. Grouped, the other server is
    /// emptied once and then stays empty for the entire block.
    ///
    /// Within a server, models are sorted rather than taken in the order the server listed them.
    /// Ollama's `/api/tags` order is not stable across restarts, and a sweep whose order changed
    /// between runs would make "it got slower after the third model" impossible to check.
    /// `localizedStandardCompare` so `llama3.2` follows `llama3.9` the way a reader expects.
    ///
    /// There is deliberately no cheapest-first ordering: it would need parameter counts or file
    /// sizes that neither provider reports reliably, and a wrong estimate arranging an hour of
    /// work is worse than an arbitrary but stable one.
    static func entries(from servers: [BenchmarkSweepServer]) -> [BenchmarkSweepEntry] {
        var seen: Set<String> = []
        return servers
            .filter(\.isIncluded)
            .sorted(by: serverOrder)
            .flatMap { row -> [BenchmarkSweepEntry] in
                row.models
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                    .map { model in
                        BenchmarkSweepEntry(
                            target: BenchmarkTarget(
                                provider: row.provider,
                                baseURLString: row.baseURLString,
                                modelName: model))
                    }
            }
            // On identity, not on name: the same model offered by two providers is two
            // measurements, and two rows that normalize to one address are one.
            .filter { seen.insert($0.id).inserted }
    }

    /// The servers a run may send commands to — every included server that ANSWERED a scan.
    ///
    /// This is the list handed to `BenchmarkResidencyPreparer` as `otherServers`, and the reason
    /// the sweep may clear an address the app was never configured with: by the time this returns
    /// it, that address has identified itself as a server by answering a read.
    static func verifiedServers(from servers: [BenchmarkSweepServer]) -> [BenchmarkServer] {
        var seen: Set<String> = []
        return servers
            .filter(\.isVerified)
            .sorted(by: serverOrder)
            .map(\.server)
            .filter { seen.insert($0.baseURLString.normalizedBaseURL).inserted }
    }

    /// `LLMProvider.allCases` order first (source order, so the sequence is the same on every
    /// machine), then the normalized address — two servers of one provider still need a total
    /// order, and a stable one.
    private static func serverOrder(_ lhs: BenchmarkSweepServer, _ rhs: BenchmarkSweepServer) -> Bool {
        let left = LLMProvider.allCases.firstIndex(of: lhs.provider) ?? 0
        let right = LLMProvider.allCases.firstIndex(of: rhs.provider) ?? 0
        if left != right { return left < right }
        return lhs.baseURLString.normalizedBaseURL < rhs.baseURLString.normalizedBaseURL
    }
}
