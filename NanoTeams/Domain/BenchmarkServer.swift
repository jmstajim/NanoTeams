import Foundation

/// One LLM server the benchmark knows how to reach: a provider, and the address it answers at.
///
/// `BenchmarkTarget` is this plus the model being measured, and the split is what lets the two
/// questions be asked separately. Measuring is about ONE model on ONE server. Clearing the machine
/// is about every server on it: on a Mac both providers draw from the same unified memory, so a
/// model resident in Ollama depresses a figure measured on LM Studio just as surely as a
/// co-resident model on the target's own server would.
nonisolated struct BenchmarkServer: Codable, Hashable, Sendable {
    var provider: LLMProvider
    var baseURLString: String

    /// Whether two references name the same machine, whatever spelling either side used.
    ///
    /// Compares the ADDRESS only, deliberately ignoring the provider. Two providers configured at
    /// one address is a misconfiguration rather than two machines, and the consequence of getting
    /// it wrong is not cosmetic: the "clear every other server" pass would unload the very model
    /// the run is about to measure. `normalizedBaseURL` is the single canonicalizer in this
    /// codebase — comparing raw strings splits one server into two on a trailing slash.
    func isSameServer(as other: BenchmarkServer) -> Bool {
        baseURLString.normalizedBaseURL == other.baseURLString.normalizedBaseURL
    }

    /// `Provider · host:port`, the label used wherever a server has to be named to the user.
    var displayLabel: String {
        "\(provider.displayName) · \(baseURLString.endpointHostLabel)"
    }
}

nonisolated extension BenchmarkTarget {
    /// The machine this target lives on, without the model.
    var server: BenchmarkServer {
        BenchmarkServer(provider: provider, baseURLString: baseURLString)
    }
}
