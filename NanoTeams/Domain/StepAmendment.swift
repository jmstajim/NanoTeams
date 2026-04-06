import Foundation

// MARK: - Step Amendment

/// Records a single amendment to a step (triggered by a change request from another role).
struct StepAmendment: Codable, Identifiable, Hashable {
    var id: UUID
    var createdAt: Date
    /// Role ID of the role that requested the change.
    var requestedByRoleID: String
    /// Description of the requested changes.
    var reason: String
    /// ID of the voting meeting that decided on this amendment (nil if validation-rejected).
    var meetingID: UUID?
    /// Outcome: "approved", "rejected", or "escalated".
    var meetingDecision: String
    /// Snapshot of artifacts before the amendment was applied.
    var previousArtifactSnapshots: [ArtifactSnapshot]

    init(
        id: UUID = UUID(),
        createdAt: Date = MonotonicClock.shared.now(),
        requestedByRoleID: String,
        reason: String,
        meetingID: UUID? = nil,
        meetingDecision: String = "approved",
        previousArtifactSnapshots: [ArtifactSnapshot] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.requestedByRoleID = requestedByRoleID
        self.reason = reason
        self.meetingID = meetingID
        self.meetingDecision = meetingDecision
        self.previousArtifactSnapshots = previousArtifactSnapshots
    }
}

// MARK: - Artifact Snapshot

/// Lightweight snapshot of an artifact at a point in time (stores path, not content).
struct ArtifactSnapshot: Codable, Identifiable, Hashable {
    var id: UUID
    var artifactName: String
    var relativePath: String?
    var snapshotAt: Date

    init(
        id: UUID = UUID(),
        artifactName: String,
        relativePath: String? = nil,
        snapshotAt: Date = MonotonicClock.shared.now()
    ) {
        self.id = id
        self.artifactName = artifactName
        self.relativePath = relativePath
        self.snapshotAt = snapshotAt
    }
}
