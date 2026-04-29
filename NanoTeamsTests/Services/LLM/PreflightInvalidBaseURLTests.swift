import XCTest

@testable import NanoTeams

/// User scenario: the user types a typo / blank URL into a per-role LLM
/// override (e.g. `htp://...` or accidentally clears the field). The previous
/// catch-all in `preflightDecision` swept this into the same bucket as
/// "server momentarily unreachable" and silently swapped the override for
/// the global config — every subsequent role-override call ran on the global
/// with no signal that the override was broken.
///
/// The fix splits the catch into two branches:
/// 1. `LLMClientError.invalidBaseURL` ⇒ KEEP the override and post a
///    user-actionable validation message ("LLM override URL is invalid: …").
/// 2. Generic transport failure ⇒ FALL BACK to global (existing behavior).
final class PreflightInvalidBaseURLTests: XCTestCase {

    private final class StubSession: NetworkSession, @unchecked Sendable {
        var sessionDataInvoked = false
        func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
            sessionDataInvoked = true
            return (Data(), HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!)
        }
        func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
            fatalError("not used")
        }
    }

    private actor MessageCollector {
        private(set) var messages: [String] = []
        func add(_ s: String) { messages.append(s) }
    }

    private let globalConfig = LLMConfig(
        provider: .lmStudio, baseURLString: "http://127.0.0.1:1234",
        modelName: "global-m"
    )

    // MARK: - Empty URL

    /// An empty URL string fails `URL(string:)` parsing, throwing
    /// `LLMClientError.invalidBaseURL`. The fix must NOT silently swap to global.
    func testPreflight_emptyOverrideURL_keepsOverride_andSurfacesValidationMessage() async {
        let badOverride = LLMConfig(
            provider: .lmStudio, baseURLString: "",
            modelName: "override-m"
        )
        let session = StubSession()
        let collector = MessageCollector()

        let result = await LLMExecutionService.preflightDecision(
            effectiveConfig: badOverride,
            globalConfig: globalConfig,
            session: session,
            resolver: StubLLMTokenResolver([:]),
            appendSystemMessage: { await collector.add($0) }
        )

        XCTAssertEqual(
            result.baseURLString, badOverride.baseURLString,
            "Invalid override URL must be kept (so the user sees the validation error), not silently fall back to global."
        )
        XCTAssertFalse(
            session.sessionDataInvoked,
            "Preflight must short-circuit before issuing a request when URL parsing fails."
        )
        let messages = await collector.messages
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(
            messages.first?.contains("invalid") == true,
            "Validation message must mention the URL is invalid; got: \(messages.first ?? "")"
        )
        XCTAssertFalse(
            messages.first?.contains("unavailable") == true,
            "Must not surface the generic 'unavailable, using default' message — that hides the misconfig."
        )
    }

    // MARK: - Negative case: real transport failure must still fall back

    /// Reachability test: the existing "transport error → fall back" branch
    /// must remain intact. Otherwise the fix would over-correct and wedge
    /// the run on a momentarily unreachable override server.
    func testPreflight_transportError_stillFallsBackToGlobal() async {
        let validButUnreachableOverride = LLMConfig(
            provider: .lmStudio, baseURLString: "http://override:9999",
            modelName: "override-m"
        )
        final class FailingSession: NetworkSession, @unchecked Sendable {
            func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
                throw URLError(.cannotConnectToHost)
            }
            func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
                fatalError("not used")
            }
        }
        let collector = MessageCollector()

        let result = await LLMExecutionService.preflightDecision(
            effectiveConfig: validButUnreachableOverride,
            globalConfig: globalConfig,
            session: FailingSession(),
            resolver: StubLLMTokenResolver([:]),
            appendSystemMessage: { await collector.add($0) }
        )

        XCTAssertEqual(
            result.baseURLString, globalConfig.baseURLString,
            "Transient transport failures must still fall back to global so the run isn't wedged."
        )
        let messages = await collector.messages
        XCTAssertTrue(
            messages.first?.contains("unavailable") == true,
            "Transport-failure path must show 'unavailable, using default'; got: \(messages.first ?? "")"
        )
    }
}
