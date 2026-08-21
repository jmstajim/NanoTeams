import Foundation

/// Dispatches provenance questions on `config.provider`, mirroring `LLMClientRouter`'s shape so
/// there is one dispatch idiom in the codebase rather than two.
///
/// Unlike that router, every member here IS provider-polymorphic: there is no lifecycle surface
/// that only one server understands, because "what version are you" is a question both answer —
/// just not on the same transport.
nonisolated struct ServerProvenanceRouter: ServerProvenanceProbe {

    private let lmStudioProbe: any ServerProvenanceProbe
    private let ollamaProbe: any ServerProvenanceProbe

    init(
        lmStudioProbe: any ServerProvenanceProbe = LMStudioServerProvenanceProbe(),
        ollamaProbe: any ServerProvenanceProbe = OllamaServerProvenanceProbe()
    ) {
        self.lmStudioProbe = lmStudioProbe
        self.ollamaProbe = ollamaProbe
    }

    private func probe(for provider: LLMProvider) -> any ServerProvenanceProbe {
        switch provider {
        case .lmStudio: lmStudioProbe
        case .ollama: ollamaProbe
        }
    }

    func serverProvenance(config: LLMConfig) async -> ServerProvenance {
        await probe(for: config.provider).serverProvenance(config: config)
    }

    func probeServingEngine(config: LLMConfig) async -> ServerProvenance.Engine? {
        await probe(for: config.provider).probeServingEngine(config: config)
    }
}
