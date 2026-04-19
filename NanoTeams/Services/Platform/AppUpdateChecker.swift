import Foundation

/// Fetches the latest GitHub release for the NanoTeams repo.
///
/// Stateless — owns no caching or throttling. The 24h cadence and skip-tag
/// filtering lives on `AppUpdateState`. `AppUpdateChecker` only knows how to
/// hit the GitHub REST endpoint and decode the JSON.
///
/// `NetworkSession` (from `LLMClient.swift`) abstracts URLSession so tests can
/// inject a mock. Errors surface as thrown values — `AppUpdateState.refresh`
/// swallows them silently so an offline user never sees an error banner.
@MainActor
final class AppUpdateChecker {

    struct Release: Equatable, Codable {
        let tag: String
        let htmlURL: URL
        let body: String
    }

    enum CheckerError: LocalizedError {
        case badStatus(Int)
        case invalidResponse
        case unexpectedContentType(String)
        case decodeFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .badStatus(let code):
                if code == 403 { return "GitHub API rate limit reached. Try again in an hour." }
                if code == 404 { return "No releases published for this repository yet." }
                return "Update check failed with HTTP \(code)."
            case .invalidResponse:
                return "Update check got a non-HTTP response."
            case .unexpectedContentType(let ct):
                return "Update check got an unexpected response type (\(ct)). "
                    + "A captive portal or proxy may be intercepting requests."
            case .decodeFailed(let underlying):
                return "Could not parse the update response from GitHub: \(underlying.localizedDescription)"
            }
        }
    }

    private let session: any NetworkSession

    init(session: any NetworkSession = URLSession.shared) {
        self.session = session
    }

    func fetchLatestRelease() async throws -> Release {
        var req = URLRequest(url: AppURLs.githubReleasesLatestAPI)
        // GitHub requires a User-Agent on every API request.
        req.setValue("NanoTeams/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.sessionData(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw CheckerError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CheckerError.badStatus(http.statusCode)
        }
        // Pre-validate content-type so a captive-portal HTML response doesn't
        // surface as a bare `DecodingError`.
        if let ct = http.value(forHTTPHeaderField: "Content-Type"),
           !ct.localizedCaseInsensitiveContains("json")
        {
            throw CheckerError.unexpectedContentType(ct)
        }
        do {
            let decoded = try JSONCoderFactory.makeWireDecoder()
                .decode(LatestReleasePayload.self, from: data)
            return Release(tag: decoded.tag_name, htmlURL: decoded.html_url, body: decoded.body ?? "")
        } catch {
            throw CheckerError.decodeFailed(underlying: error)
        }
    }
}

// MARK: - Wire types

// swiftlint:disable identifier_name — snake_case keys match GitHub API literally.
private struct LatestReleasePayload: Decodable {
    let tag_name: String
    let html_url: URL
    let body: String?
}
// swiftlint:enable identifier_name
