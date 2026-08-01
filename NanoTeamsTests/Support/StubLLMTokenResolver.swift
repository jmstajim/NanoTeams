import Foundation
@testable import NanoTeams

/// Test resolver. Construct with a `[urlString: token]` dictionary; lookup
/// normalizes the URL the same way production does so tests can hit either form.
///
/// Lives in the test target on purpose: it has zero production references, so
/// shipping it inside `NanoTeams` would compile a test double into the app binary.
nonisolated struct StubLLMTokenResolver: LLMTokenResolver {
    let tokens: [String: String]

    init(_ tokens: [String: String] = [:]) {
        var normalized: [String: String] = [:]
        for (url, token) in tokens {
            normalized[KeychainSecureTokenStorage.normalize(baseURL: url)] = token
        }
        self.tokens = normalized
    }

    func token(forBaseURL urlString: String) -> String? {
        tokens[KeychainSecureTokenStorage.normalize(baseURL: urlString)]
    }
}
