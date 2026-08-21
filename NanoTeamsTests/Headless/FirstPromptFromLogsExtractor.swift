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
        // Dual-format, mirroring the bash: current runs write JSONL (one record
        // per line); pre-2026-08-21 runs wrote a JSON ARRAY, and log artifacts
        // die with their run, so nothing converts them — the reader carries both.
        // Discriminated by the first non-whitespace byte, not the extension, so
        // a legacy file fed directly still parses.
        let firstByte = data.first(where: { $0 != 0x20 && $0 != 0x0A && $0 != 0x0D && $0 != 0x09 })
        if firstByte == UInt8(ascii: "[") {
            do {
                records = try decoder.decode([NetworkLogRecord].self, from: data)
            } catch {
                throw ExtractError.malformedLog(underlying: error)
            }
        } else {
            guard let text = String(data: data, encoding: .utf8) else {
                throw ExtractError.malformedLog(
                    underlying: CocoaError(.fileReadInapplicableStringEncoding))
            }
            records = text.split(separator: "\n", omittingEmptySubsequences: true).compactMap {
                try? decoder.decode(NetworkLogRecord.self, from: Data($0.utf8))
            }
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
