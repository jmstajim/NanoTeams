//
//  Artifact.swift
//  NanoTeams
//
//  Simplified artifact model for step execution.
//  Artifacts are identified by name (string), with computed id from slugified name.
//

import Foundation

/// Represents an artifact produced by a step execution.
/// Artifacts are identified by their name (e.g., "Product Requirements", "Implementation Plan").
nonisolated struct Artifact: Codable, Identifiable, Hashable {
    /// Display name of the artifact (e.g., "Product Requirements")
    var name: String

    /// SF Symbol icon name
    var icon: String

    /// MIME type (e.g., "text/markdown", "application/json")
    var mimeType: String

    /// Human-readable description
    var description: String

    /// Creation timestamp
    var createdAt: Date

    /// Last update timestamp
    var updatedAt: Date

    /// Optional relative path within .nanoteams/ for persisted artifact payload
    var relativePath: String?

    /// True if this artifact was created from a built-in system template
    var isSystem: Bool

    // MARK: - Computed Properties

    /// Computed ID from the artifact name (lowercase underscore)
    var id: String {
        Artifact.slugify(name)
    }

    /// Project-root-relative path the file tools (`read_file`/`read_lines`) accept for this
    /// artifact's persisted payload — i.e. `relativePath` *with* the `.nanoteams/` prefix the
    /// sandbox resolves against (`relativePath` is stored relative to `.nanoteams/`, so the file
    /// tools — which resolve against the project root — can't read it verbatim).
    ///
    /// A non-nil return is a PROMISE of readability, so it returns nil whenever the file tools
    /// can't serve the payload:
    ///   • no persisted file (`relativePath` nil, empty, or whitespace-only);
    ///   • an internal artifact such as Build Diagnostics, persisted under
    ///     `.nanoteams/internal/…` — the sandbox blocks `internal/`; or
    ///   • a non-nested path (no `/`) — every persisted artifact lives nested under
    ///     `tasks/…/roles/…`, so a bare name is malformed and `.nanoteams/<bare>` wouldn't exist.
    /// Such artifacts are still listed by name; they just have no readable reference.
    var llmReadablePath: String? {
        guard let rel = relativePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rel.isEmpty else { return nil }
        guard !rel.hasPrefix("internal/") else { return nil }
        guard rel.contains("/") else { return nil }
        return ".nanoteams/" + rel
    }

    // MARK: - Initialization

    init(
        name: String,
        icon: String = "doc.text",
        mimeType: String = "text/markdown",
        description: String = "",
        createdAt: Date = MonotonicClock.shared.now(),
        updatedAt: Date = MonotonicClock.shared.now(),
        relativePath: String? = nil,
        isSystem: Bool = false
    ) {
        self.name = name
        self.icon = icon
        self.mimeType = mimeType
        self.description = description
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.relativePath = relativePath
        self.isSystem = isSystem
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case name
        case icon
        case mimeType
        case description
        case createdAt
        case updatedAt
        case relativePath
        case isSystem
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.name = try container.decode(String.self, forKey: .name)
        self.icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? "doc.text"
        self.mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType) ?? "text/markdown"
        self.description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? MonotonicClock.shared.now()
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? MonotonicClock.shared.now()
        self.relativePath = try container.decodeIfPresent(String.self, forKey: .relativePath)
        self.isSystem = try container.decodeIfPresent(Bool.self, forKey: .isSystem) ?? false
    }
}

// MARK: - Helper Methods

nonisolated extension Artifact {
    /// Slugify an artifact name for use as id and file paths
    static func slugify(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Get the default icon for an artifact name from system templates
    static func defaultIconForName(_ name: String) -> String {
        if let template = SystemTemplates.artifacts[name] {
            return template.icon
        }
        return "doc.text"
    }

}
