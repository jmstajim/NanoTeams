import Foundation

/// How the model reads one string field of a `tools/call` content block — the ONE table the
/// result mapper cleans by and the client scrubs by (`MCPClient.scrubbingOwnSecrets`).
///
/// The scrub has to look at a field in the form the model will read it. A field laid out as a
/// line or as prose loses characters the data pass keeps — a zero-width space, a joiner — so a
/// secret split by one is whole again after the mapper's cleaning. Until 2026-09-23 the client
/// cleaned every field as data and the mapper cleaned a link's `uri`, `name` and `description`
/// its own way, and a `token=wk_live\u{200B}_8f3a…` in a `resource_link` reached the model
/// whole. Two copies of this table were the defect; one is the fix.
nonisolated enum MCPResultFieldReading: Equatable, Sendable {
    /// A file's contents or someone's message: `sanitizeData`, every byte that is not a lie kept.
    case data
    /// Prose this app lays out — a link's description: `sanitize`.
    case prose
    /// One line — an address, a name, a type: `singleLine`.
    case line
    /// Base64 — `data` on an image or audio block, `blob` on a resource. Not text: never
    /// cleaned, never scrubbed (a short value turns up in a megabyte of base64 by chance).
    case binary

    /// A field the mapper does not read is still data: cleaning it costs nothing, and it keeps
    /// every block the client hands on free of what the data pass drops.
    init(field: String) {
        switch field {
        case "text": self = .data
        case "description": self = .prose
        case "uri", "name", "mimeType", "type": self = .line
        case "data", "blob": self = .binary
        default: self = .data
        }
    }

    func cleaned(_ text: String) -> String {
        switch self {
        case .data: MCPTextSanitizer.sanitizeData(text)
        case .prose: MCPTextSanitizer.sanitize(text)
        case .line: MCPTextSanitizer.singleLine(text)
        case .binary: text
        }
    }

    /// `field` of `block`, as the model reads it — `nil` when absent or not a string.
    static func read(_ field: String, of block: [String: JSONValue]) -> String? {
        block[field]?.stringValue.map(Self(field: field).cleaned)
    }
}
