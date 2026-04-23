import Foundation

/// Centralized factory for JSON encoder/decoder configurations.
/// Eliminates duplication of dateEncodingStrategy/outputFormatting setup across 12+ files.
enum JSONCoderFactory {

    // MARK: - ISO 8601 formatters

    /// ISO 8601 with fractional seconds (e.g. `2026-04-23T14:30:00.123Z`).
    /// Preserves the millisecond spacing produced by `MonotonicClock`, so persisted
    /// timestamps don't collapse to the same second on save and scramble ordering
    /// (e.g. activity feed messages/tool calls interleaving) after reload.
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Plain ISO 8601, second precision — used for backward-compatible decoding
    /// of pre-fix task.json files that were written with the default `.iso8601` strategy.
    private static let plainFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let dateEncodingStrategy: JSONEncoder.DateEncodingStrategy = .custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(fractionalFormatter.string(from: date))
    }

    private static let dateDecodingStrategy: JSONDecoder.DateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        if let date = fractionalFormatter.date(from: string) { return date }
        if let date = plainFormatter.date(from: string) { return date }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Invalid ISO 8601 date string: \(string)"
        )
    }

    /// Persistence encoder: prettyPrinted + sortedKeys + withoutEscapingSlashes + ISO 8601 dates.
    /// Used by: AtomicJSONStore, NetworkLogger.
    static func makePersistenceEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = dateEncodingStrategy
        return encoder
    }

    /// Export encoder: prettyPrinted + sortedKeys + ISO 8601 dates.
    /// Used by: NTMSRepository (diagnostics), TeamImportExportService.
    static func makeExportEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = dateEncodingStrategy
        return encoder
    }

    /// JSONL encoder: compact single-line, withoutEscapingSlashes + ISO 8601 dates.
    /// Used by: ToolCallLogger.
    static func makeJSONLEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        encoder.dateEncodingStrategy = dateEncodingStrategy
        return encoder
    }

    /// Wire encoder: sortedKeys only. No dates.
    /// Used by: NativeLMStudioClient, Tools+Envelope (tool result JSON).
    static func makeWireEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// Display encoder: prettyPrinted + sortedKeys + withoutEscapingSlashes. No dates.
    /// Used by: NativeLMStudioClient+RequestBuilder (tool schemas in prompt), ToolDefinitionEditorSheetView.
    static func makeDisplayEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Wire decoder: plain JSONDecoder for API/SSE responses without Date fields.
    /// Used by: NativeLMStudioClient (model list), SSEEventParser (streaming chunks).
    static func makeWireDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    /// ISO 8601 decoder for persistence and export data. Accepts both fractional-
    /// seconds format (new) and second-precision (pre-fix files already on disk).
    /// Used by: AtomicJSONStore, NetworkLogger, TeamImportExportService.
    static func makeDateDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = dateDecodingStrategy
        return decoder
    }

    /// Shared ISO 8601 date formatter for display strings (default options).
    /// Used by: ArtifactService.
    static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()
}
