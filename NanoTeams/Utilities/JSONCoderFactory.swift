import Foundation

/// Centralized factory for JSON encoder/decoder configurations.
/// Eliminates duplication of dateEncodingStrategy/outputFormatting setup across 12+ files.
enum JSONCoderFactory {

    /// Persistence encoder: prettyPrinted + sortedKeys + withoutEscapingSlashes + ISO 8601 dates.
    /// Used by: AtomicJSONStore, NetworkLogger.
    static func makePersistenceEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Export encoder: prettyPrinted + sortedKeys + ISO 8601 dates.
    /// Used by: NTMSRepository (diagnostics), TeamImportExportService.
    static func makeExportEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// JSONL encoder: compact single-line, withoutEscapingSlashes + ISO 8601 dates.
    /// Used by: ToolCallLogger.
    static func makeJSONLEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
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

    /// ISO 8601 decoder for persistence and export data.
    /// Used by: AtomicJSONStore, NetworkLogger, TeamImportExportService.
    static func makeDateDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Shared ISO 8601 date formatter for display strings (default options).
    /// Used by: ArtifactService.
    static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()
}
