import XCTest

@testable import NanoTeams

/// Pin the highest-stakes leak vector: a user exporting a team JSON to share
/// with a colleague. The team contains role definitions; each role can carry
/// an `LLMOverride` with a custom URL. If the bearer token ever lived on
/// `LLMOverride` (or an adjacent Codable type), `exportTeam` would silently
/// ship it inside the team file — visible to anyone who opens the file or
/// shares it on Slack.
///
/// This test (a) builds a Team with an `LLMOverride.baseURLString = "X"`,
/// (b) seeds the in-memory storage with a canary token for `X`, and
/// (c) calls `TeamImportExportService.exportTeam`. The exported bytes must
/// not contain the canary anywhere. If they do, the export path has started
/// pulling from the resolver (a regression that re-opens this leak vector).
final class TeamExportTokenLeakTests: XCTestCase {

    private let canary = "TOK-EXPORT-LEAK-CANARY-\(UUID().uuidString)"
    private let overrideURL = "http://very-private-server:8443"

    func testExportTeam_doesNotIncludeKeychainToken_evenWhenStored() throws {
        // Stash a token for the override URL. Production reads this from
        // Keychain via `DefaultLLMTokenResolver`; we use the in-memory
        // storage to keep the test hermetic.
        let storage = InMemorySecureTokenStorage()
        try storage.setToken(
            canary,
            forKey: KeychainSecureTokenStorage.normalize(baseURL: overrideURL)
        )
        XCTAssertEqual(
            storage.token(forKey: KeychainSecureTokenStorage.normalize(baseURL: overrideURL)),
            canary,
            "Sanity: storage seed must succeed."
        )

        // Build a Team where one role has an LLMOverride pointing at the
        // private URL. If a future change adds a token field to LLMOverride,
        // the role construction here will fail to compile or the assertion
        // below will catch the leak.
        let role = TeamRoleDefinition(
            id: "role-canary",
            name: "Token Canary",
            prompt: "Just exists to carry an LLMOverride.",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            llmOverride: LLMOverride(
                baseURLString: overrideURL,
                modelName: "private-model"
            )
        )
        var team = Team(name: "Export Leak Guard")
        team.addRole(role)

        let data = try TeamImportExportService.exportTeam(team)
        let serialized = String(data: data, encoding: .utf8) ?? ""

        XCTAssertFalse(
            serialized.contains(canary),
            "Team export contains the bearer token. The export path must NEVER read "
                + "from the token storage. If a future change made it 'helpful' to bundle "
                + "the token with the team JSON, revert it — that exposes the secret to "
                + "anyone who opens the export."
        )
        // The override URL itself is fine to be exported (it's already in
        // LLMOverride.baseURLString and the user explicitly asked to export
        // the team). Only the secret must stay behind. Compare against a
        // host-only substring so JSON `\/` escaping doesn't fool the check.
        XCTAssertTrue(
            serialized.contains("very-private-server"),
            "Sanity: the override URL host IS expected in the export. If this fails, "
                + "TeamImportExportService stopped serializing LLMOverride.baseURLString "
                + "and the leak guard above is no longer testing the right path."
        )
    }

    func testExportTeam_serializedRoles_haveNoTokenFieldOnLLMOverride() throws {
        // Belt-and-suspenders: even with no token in storage, exporting a
        // role with `llmOverride` must not gain a token-shaped field.
        let role = TeamRoleDefinition(
            id: "r",
            name: "R",
            prompt: "p",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            llmOverride: LLMOverride(baseURLString: "http://x:1")
        )
        var team = Team(name: "T")
        team.addRole(role)
        let data = try TeamImportExportService.exportTeam(team)

        // exportTeam wraps in TeamExportFormat: { version, team, exportedAt }
        let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let teamJSON = envelope["team"] as? [String: Any] ?? [:]
        let roles = teamJSON["roles"] as? [[String: Any]] ?? []
        guard let exportedRole = roles.first(where: { $0["id"] as? String == "r" }) else {
            return XCTFail("Exported team must contain the role we added. Envelope keys: \(envelope.keys), team keys: \(teamJSON.keys), roles count: \(roles.count)")
        }
        let override = exportedRole["llmOverride"] as? [String: Any] ?? [:]
        let banned: Set<String> = [
            "apiToken", "api_token", "authToken", "auth_token",
            "bearerToken", "bearer_token", "secret", "password",
            "Authorization", "authorization"
        ]
        let leaks = banned.intersection(Set(override.keys))
        XCTAssertTrue(
            leaks.isEmpty,
            "LLMOverride in exported team JSON contains banned key(s): \(leaks)."
        )
    }
}
