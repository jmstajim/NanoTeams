import Foundation

@testable import NanoTeams

/// Shared test-side reader for the wire log. The log is JSONL (2026-08-21) —
/// one `NetworkLogRecord` per line — and every writer-facing test decodes it
/// through here so the format lives in ONE place on the test side too.
enum NetworkLogTestReading {

    /// Every non-empty line MUST decode — for tests whose point is
    /// "the file stays fully decodable".
    static func strictRecords(at url: URL) throws -> [NetworkLogRecord] {
        let decoder = JSONCoderFactory.makeDateDecoder()
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n", omittingEmptySubsequences: true).map {
            try decoder.decode(NetworkLogRecord.self, from: Data($0.utf8))
        }
    }
}
