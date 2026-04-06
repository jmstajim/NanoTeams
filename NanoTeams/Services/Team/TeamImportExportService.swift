import Foundation

// MARK: - Team Import/Export Service

/// Service for importing and exporting team configurations, roles, and artifacts.
enum TeamImportExportService {

    // MARK: - Role Export/Import

    /// Export a role to JSON data
    static func exportRole(_ role: TeamRoleDefinition) throws -> Data {
        let exportData = RoleExportFormat(
            version: 1,
            role: role,
            exportedAt: MonotonicClock.shared.now()
        )

        return try JSONCoderFactory.makeExportEncoder().encode(exportData)
    }

    /// Import a role from JSON data
    static func importRole(from data: Data, into team: inout Team) throws {
        let importData = try JSONCoderFactory.makeDateDecoder().decode(RoleExportFormat.self, from: data)

        // Validate version
        guard importData.version == 1 else {
            throw ImportExportError.unsupportedVersion(importData.version)
        }

        var importedRole = importData.role
        importedRole.isSystemRole = false  // Imported roles are custom
        importedRole.systemRoleID = nil
        importedRole.createdAt = MonotonicClock.shared.now()
        importedRole.updatedAt = MonotonicClock.shared.now()

        // Check for name conflicts (before generating ID so ID matches final name)
        if team.roles.contains(where: { $0.name == importedRole.name }) {
            importedRole.name = "\(importedRole.name) (Imported)"
        }

        // Generate deterministic ID from final name
        importedRole.id = NTMSID.from(name: "\(team.id):\(importedRole.name)")

        team.roles.append(importedRole)
    }

    // MARK: - Artifact Export/Import

    /// Export an artifact to JSON data
    static func exportArtifact(_ artifact: TeamArtifact) throws -> Data {
        let exportData = ArtifactExportFormat(
            version: 1,
            artifact: artifact,
            exportedAt: MonotonicClock.shared.now()
        )

        return try JSONCoderFactory.makeExportEncoder().encode(exportData)
    }

    /// Import an artifact from JSON data
    static func importArtifact(from data: Data, into team: inout Team) throws {
        let importData = try JSONCoderFactory.makeDateDecoder().decode(ArtifactExportFormat.self, from: data)

        // Validate version
        guard importData.version == 1 else {
            throw ImportExportError.unsupportedVersion(importData.version)
        }

        // Generate new ID based on name
        var importedArtifact = importData.artifact

        // Check for name conflicts
        var finalName = importedArtifact.name
        if team.artifacts.contains(where: { $0.name == finalName }) {
            finalName = "\(finalName) (Imported)"
        }

        importedArtifact.name = finalName
        importedArtifact.id = Artifact.slugify(finalName)
        importedArtifact.isSystemArtifact = false  // Imported artifacts are custom
        importedArtifact.systemArtifactName = nil
        importedArtifact.createdAt = MonotonicClock.shared.now()
        importedArtifact.updatedAt = MonotonicClock.shared.now()

        team.artifacts.append(importedArtifact)
    }

    // MARK: - Team Export/Import

    /// Export entire team to JSON data
    static func exportTeam(_ team: Team) throws -> Data {
        let exportData = TeamExportFormat(
            version: 1,
            team: team,
            exportedAt: MonotonicClock.shared.now()
        )

        return try JSONCoderFactory.makeExportEncoder().encode(exportData)
    }

    /// Import team from JSON data
    static func importTeam(from data: Data, newName: String? = nil) throws -> Team {
        let importData = try JSONCoderFactory.makeDateDecoder().decode(TeamExportFormat.self, from: data)

        // Validate version
        guard importData.version == 1 else {
            throw ImportExportError.unsupportedVersion(importData.version)
        }

        // Create new team with fresh IDs
        var importedTeam = importData.team
        let resolvedName = newName ?? "\(importData.team.name) (Imported)"
        importedTeam.id = NTMSID.from(name: resolvedName)
        importedTeam.name = resolvedName
        importedTeam.createdAt = MonotonicClock.shared.now()
        importedTeam.updatedAt = MonotonicClock.shared.now()

        // Regenerate role IDs and build old → new mapping
        var roleIDMapping: [String: String] = [:]
        for index in importedTeam.roles.indices {
            let oldID = importedTeam.roles[index].id
            let newID = NTMSID.from(name: "\(resolvedName):\(importedTeam.roles[index].name)")
            roleIDMapping[oldID] = newID
            importedTeam.roles[index].id = newID
            importedTeam.roles[index].createdAt = MonotonicClock.shared.now()
            importedTeam.roles[index].updatedAt = MonotonicClock.shared.now()
        }

        // Remap graph layout role IDs
        for i in importedTeam.graphLayout.nodePositions.indices {
            let oldRoleID = importedTeam.graphLayout.nodePositions[i].roleID
            if let newID = roleIDMapping[oldRoleID] {
                importedTeam.graphLayout.nodePositions[i].roleID = newID
            }
        }
        importedTeam.graphLayout.hiddenRoleIDs = Set(
            importedTeam.graphLayout.hiddenRoleIDs.compactMap { roleIDMapping[$0] }
        )

        // Remap settings role IDs (hierarchy, coordinator, invitableRoles, checkpoints)
        importedTeam.settings = importedTeam.settings.remappingRoleIDs(roleIDMapping)

        // Regenerate artifact IDs
        for index in importedTeam.artifacts.indices {
            let artifact = importedTeam.artifacts[index]
            importedTeam.artifacts[index].id = Artifact.slugify(artifact.name)
            importedTeam.artifacts[index].createdAt = MonotonicClock.shared.now()
            importedTeam.artifacts[index].updatedAt = MonotonicClock.shared.now()
        }

        return importedTeam
    }

    // MARK: - File Helpers

    /// Suggested file name for role export
    static func suggestedFileName(for role: TeamRoleDefinition) -> String {
        sanitizedFileName(role.name, suffix: "role")
    }

    /// Suggested file name for artifact export
    static func suggestedFileName(for artifact: TeamArtifact) -> String {
        sanitizedFileName(artifact.name, suffix: "artifact")
    }

    /// Suggested file name for team export
    static func suggestedFileName(for team: Team) -> String {
        sanitizedFileName(team.name, suffix: "team")
    }

    private static func sanitizedFileName(_ name: String, suffix: String) -> String {
        let clean = name
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "[^a-z0-9_]", with: "", options: .regularExpression)
        return "\(clean)_\(suffix).json"
    }
}

// MARK: - Export Formats

struct RoleExportFormat: Codable {
    let version: Int
    let role: TeamRoleDefinition
    let exportedAt: Date
}

struct ArtifactExportFormat: Codable {
    let version: Int
    let artifact: TeamArtifact
    let exportedAt: Date
}

struct TeamExportFormat: Codable {
    let version: Int
    let team: Team
    let exportedAt: Date
}

// MARK: - Errors

enum ImportExportError: Error, LocalizedError {
    case unsupportedVersion(Int)
    case invalidData
    case fileAccessError

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "Unsupported export format version: \(version). Please update NanoTeams to import this file."
        case .invalidData:
            return "The selected file does not contain valid export data."
        case .fileAccessError:
            return "Unable to read or write the file. Please check permissions."
        }
    }
}

