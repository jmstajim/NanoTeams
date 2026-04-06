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
struct Artifact: Codable, Identifiable, Hashable {
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

extension Artifact {
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
