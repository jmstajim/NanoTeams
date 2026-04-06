//
//  TeamArtifact.swift
//  NanoTeams
//
//  Team-specific artifact definition with name, icon, and metadata.
//

import Foundation

/// An artifact that belongs to a specific team.
/// Each team has its own set of artifacts that roles can require and produce.
struct TeamArtifact: Codable, Identifiable {
    /// Unique identifier within the team
    var id: String

    /// Display name of the artifact (e.g., "API Specification", "Product Requirements")
    var name: String

    /// SF Symbol name for displaying the artifact icon
    var icon: String

    /// MIME type of the artifact content (e.g., "text/markdown", "text/plain")
    var mimeType: String

    /// Human-readable description of what this artifact contains
    var description: String

    /// True if this artifact was created from a built-in template
    var isSystemArtifact: Bool

    /// Reference to the system artifact template name (e.g., "Product Requirements")
    /// Only used for artifacts created from templates, nil for custom artifacts
    var systemArtifactName: String?

    /// Creation timestamp
    var createdAt: Date

    /// Last update timestamp
    var updatedAt: Date

    // MARK: - Initialization

    init(
        id: String,
        name: String,
        icon: String,
        mimeType: String,
        description: String,
        isSystemArtifact: Bool = false,
        systemArtifactName: String? = nil,
        createdAt: Date = MonotonicClock.shared.now(),
        updatedAt: Date = MonotonicClock.shared.now()
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.mimeType = mimeType
        self.description = description
        self.isSystemArtifact = isSystemArtifact
        self.systemArtifactName = systemArtifactName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case icon
        case mimeType
        case description
        case isSystemArtifact
        case systemArtifactName
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? "doc.text"
        self.mimeType =
            try container.decodeIfPresent(String.self, forKey: .mimeType) ?? "text/markdown"
        self.description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.isSystemArtifact =
            try container.decodeIfPresent(Bool.self, forKey: .isSystemArtifact) ?? false
        self.systemArtifactName = try container.decodeIfPresent(
            String.self, forKey: .systemArtifactName)
        self.createdAt =
            try container.decodeIfPresent(Date.self, forKey: .createdAt)
            ?? MonotonicClock.shared.now()
        self.updatedAt =
            try container.decodeIfPresent(Date.self, forKey: .updatedAt)
            ?? MonotonicClock.shared.now()
    }
}

// MARK: - Helper Methods

extension TeamArtifact {
    /// Returns a copy of this artifact with updated timestamp
    func withUpdatedTimestamp() -> TeamArtifact {
        var copy = self
        copy.updatedAt = MonotonicClock.shared.now()
        return copy
    }

    /// Returns true if this artifact has a markdown MIME type
    var isMarkdown: Bool {
        return mimeType == "text/markdown"
    }

    /// Returns true if this artifact has a plain text MIME type
    var isPlainText: Bool {
        return mimeType == "text/plain"
    }

    /// Returns true if this artifact has a JSON MIME type
    var isJSON: Bool {
        return mimeType == "application/json"
    }

    /// Slugify an artifact name for use in file paths
    static func slugify(_ name: String) -> String {
        let raw = name.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
        // Collapse consecutive underscores
        return raw.replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
    }

    /// Get the default icon for an artifact name from system templates
    static func defaultIconForName(_ name: String) -> String {
        if let template = SystemTemplates.artifacts[name] {
            return template.icon
        }
        return "doc.text"
    }
}

// MARK: - Hashable

extension TeamArtifact: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: TeamArtifact, rhs: TeamArtifact) -> Bool {
        lhs.id == rhs.id
    }
}
