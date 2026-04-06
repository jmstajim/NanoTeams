import SwiftUI

// MARK: - Team Selector View

/// Prominent team selector with dropdown for switching, creating, and managing teams.
/// Shows active team name with a larger icon and member count.
struct TeamSelectorView: View {
    let teams: [Team]
    let activeTeamID: NTMSID
    let onSelect: (NTMSID) -> Void
    let onAdd: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Menu {
            // Team list
            ForEach(teams) { team in
                Button {
                    onSelect(team.id)
                } label: {
                    HStack {
                        if team.id == activeTeamID {
                            Image(systemName: "checkmark")
                        }
                        Text(team.name)

                        Spacer()

                        Text("\(team.memberCount) members")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            // Management actions
            Button {
                onAdd()
            } label: {
                Label("New Team...", systemImage: "plus")
            }

            Button {
                onDuplicate()
            } label: {
                Label("Duplicate Team", systemImage: "doc.on.doc")
            }

            if teams.count > 1 {
                Divider()

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete Team...", systemImage: "trash")
                }
            }
        } label: {
            HStack(spacing: Spacing.s) {
                // Team icon — larger and more prominent
                ZStack {
                    RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                        .fill(Colors.accentTintStrong)
                        .frame(width: 36, height: 36)

                    Image(systemName: "person.3.fill")
                        .font(.subheadline).fontWeight(.semibold)
                        .foregroundStyle(Colors.accent)
                }

                // Team name + member count
                VStack(alignment: .leading, spacing: 1) {
                    Text(activeTeam?.name ?? "Select Team")
                        .font(.headline)
                        .lineLimit(1)

                    Text("\(activeTeam?.memberCount ?? 0) members, \(activeTeam?.artifacts.count ?? 0) artifacts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2).fontWeight(.medium)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                    .fill(Colors.surfacePrimary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                    .strokeBorder(Colors.accentBorder, lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var activeTeam: Team? {
        teams.first { $0.id == activeTeamID }
    }
}

#Preview("Team Selector") {
    let faangRoles = (1...8).map { i in
        TeamRoleDefinition(id: "r\(i)", name: "Role \(i)", prompt: "", toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies())
    }
    let faangArtifacts = (1...7).map { i in
        TeamArtifact(id: "a\(i)", name: "Artifact \(i)", icon: "doc.text", mimeType: "text/markdown", description: "")
    }
    let startupRoles = [
        TeamRoleDefinition(id: "swe", name: "Software Engineer", prompt: "", toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies())
    ]
    let startupArtifacts = (1...2).map { i in
        TeamArtifact(id: "sa\(i)", name: "Artifact \(i)", icon: "doc.text", mimeType: "text/markdown", description: "")
    }
    let team1 = Team(name: "FAANG Team", roles: faangRoles, artifacts: faangArtifacts, settings: .default, graphLayout: .default)
    let team2 = Team(name: "Startup", roles: startupRoles, artifacts: startupArtifacts, settings: .default, graphLayout: .default)
    TeamSelectorView(
        teams: [team1, team2],
        activeTeamID: team1.id,
        onSelect: { _ in },
        onAdd: {},
        onDuplicate: {},
        onDelete: {}
    )
    .padding()
    .frame(width: 400)
    .background(Colors.surfacePrimary)
}
