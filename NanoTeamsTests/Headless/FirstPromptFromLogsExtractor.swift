import Foundation
@testable import NanoTeams

/// Swift mirror of the `extract_mode` jq pipeline in `train_first_prompt.sh`.
///
/// The bash script is the user-facing CLI; this helper exists so the same
/// extraction logic is regression-tested in Swift against a fixture log,
/// independent of `jq`. If a future change to `NetworkLogRecord` (field rename,
/// codable shape) or to the chat endpoint URL breaks the bash filter, this
/// test catches it — bash drift is otherwise invisible until users run the
/// CLI in anger.
enum FirstPromptFromLogsExtractor {

    /// One `--from-logs` extraction result. `wireBody` is the deserialised
    /// `.body` (an LM Studio chat request) ready to wrap in the renderer
    /// envelope; `matchedCount` distinguishes "earliest of N" from "only one".
    struct Match: Equatable {
        let wireBody: NetworkLogRecord
        let matchedCount: Int
    }

    enum ExtractError: Error, CustomStringConvertible {
        case noMatch(role: String)
        case missingBody
        case malformedLog(underlying: Error)

        var description: String {
            switch self {
            case .noMatch(let role):
                return "no match for role substring '\(role)' in network log"
            case .missingBody:
                return "matched record has no .body field — log may be malformed"
            case .malformedLog(let underlying):
                return "log decode failed: \(underlying)"
            }
        }
    }

    /// Filter records that match the same predicate the jq filter uses:
    ///   - direction == .request
    ///   - httpMethod == "POST"
    ///   - url contains "/api/v1/chat"
    ///   - roleName (lowercased) contains roleSubstring (lowercased)
    /// Returns the earliest match by `createdAt` plus the total match count.
    static func extract(from logURL: URL, roleSubstring: String) throws -> Match {
        let data = try Data(contentsOf: logURL)
        let decoder = JSONCoderFactory.makeDateDecoder()
        let records: [NetworkLogRecord]
        do {
            records = try decoder.decode([NetworkLogRecord].self, from: data)
        } catch {
            throw ExtractError.malformedLog(underlying: error)
        }

        let needle = roleSubstring.lowercased()
        let matches = records
            .filter {
                $0.direction == .request
                    && $0.httpMethod == "POST"
                    && $0.url.contains("/api/v1/chat")
                    && (($0.roleName ?? "").lowercased().contains(needle))
            }
            .sorted { $0.createdAt < $1.createdAt }

        guard let first = matches.first else {
            throw ExtractError.noMatch(role: roleSubstring)
        }
        guard first.body != nil else {
            throw ExtractError.missingBody
        }
        return Match(wireBody: first, matchedCount: matches.count)
    }
}
