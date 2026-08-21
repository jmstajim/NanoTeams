import XCTest

@testable import NanoTeams

/// Dispatch only. The interesting failure is not "the wrong answer" but "the other provider was
/// asked at all" — a version probe sent to the wrong server is a request the user never wanted.
final class ServerProvenanceRouterTests: XCTestCase {

    private func config(_ provider: LLMProvider) -> LLMConfig {
        LLMConfig(
            provider: provider,
            baseURLString: provider == .ollama
                ? "http://127.0.0.1:11434"
                : "http://127.0.0.1:1234",
            modelName: "m")
    }

    func testServerProvenance_dispatchesOnProvider() async {
        let lmStudio = MarkerProbe(marker: "lmstudio")
        let ollama = MarkerProbe(marker: "ollama")
        let router = ServerProvenanceRouter(lmStudioProbe: lmStudio, ollamaProbe: ollama)

        let lm = await router.serverProvenance(config: config(.lmStudio))
        let oll = await router.serverProvenance(config: config(.ollama))

        XCTAssertEqual(lm.version, "lmstudio")
        XCTAssertEqual(oll.version, "ollama")
    }

    func testServerProvenance_neverAsksTheOtherProvider() async {
        let lmStudio = MarkerProbe(marker: "lmstudio")
        let ollama = MarkerProbe(marker: "ollama")
        let router = ServerProvenanceRouter(lmStudioProbe: lmStudio, ollamaProbe: ollama)

        _ = await router.serverProvenance(config: config(.ollama))

        XCTAssertEqual(ollama.provenanceCalls, 1)
        XCTAssertEqual(lmStudio.provenanceCalls, 0)
    }

    func testProbeServingEngine_dispatchesOnProvider() async {
        let lmStudio = MarkerProbe(marker: "lmstudio")
        let ollama = MarkerProbe(marker: "ollama")
        let router = ServerProvenanceRouter(lmStudioProbe: lmStudio, ollamaProbe: ollama)

        let engine = await router.probeServingEngine(config: config(.lmStudio))

        XCTAssertEqual(engine?.name, "lmstudio")
        XCTAssertEqual(lmStudio.engineCalls, 1)
        XCTAssertEqual(ollama.engineCalls, 0)
    }
}

private final class MarkerProbe: ServerProvenanceProbe, @unchecked Sendable {
    private let lock = NSLock()
    private let marker: String
    private var provenanceCount = 0
    private var engineCount = 0

    init(marker: String) { self.marker = marker }

    var provenanceCalls: Int { lock.withLock { provenanceCount } }
    var engineCalls: Int { lock.withLock { engineCount } }

    func serverProvenance(config _: LLMConfig) async -> ServerProvenance {
        lock.withLock { provenanceCount += 1 }
        return ServerProvenance(version: marker)
    }

    func probeServingEngine(config _: LLMConfig) async -> ServerProvenance.Engine? {
        lock.withLock { engineCount += 1 }
        return ServerProvenance.Engine(name: marker, version: "1.0")
    }
}
