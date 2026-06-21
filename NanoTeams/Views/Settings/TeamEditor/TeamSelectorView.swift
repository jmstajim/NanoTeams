import SwiftUI

// MARK: - Team Selector View

/// Prominent team selector with dropdown for switching, creating, and managing teams.
/// Shows active team name with a larger icon and member count.
struct TeamSelectorView: View {
    let teams: [Team]
    let activeTeamID: NTMSID
    let canDelete: Bool
    let canDuplicate: Bool
    let onSelect: (NTMSID) -> Void
    let onAdd: () -> Void
    let onGenerate: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Menu {
            // Generate Team — separate first section
            Button {
                onGenerate()
            } label: {
                Label("Generate Team...", systemImage: "wand.and.stars")
            }

            Divider()

            // Team list — regular teams first, then the managed singleton
            // (Autovisor) behind its own divider so it reads as a distinct entry.
            ForEach(teams.filter { !$0.isManagedSingleton }) { team in
                teamRow(team)
            }

            let singletons = teams.filter { $0.isManagedSingleton }
            if !singletons.isEmpty {
                Divider()
                ForEach(singletons) { team in
                    teamRow(team)
                }
            }

            Divider()

            // Management actions
            Button {
                onAdd()
            } label: {
                Label("New Team...", systemImage: "plus")
            }

            if canDuplicate {
                Button {
                    onDuplicate()
                } label: {
                    Label("Duplicate Team", systemImage: "doc.on.doc")
                }
            }

            if canDelete {
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
                    RoundedRectangle.squircle(CornerRadius.medium)
                        .fill(Colors.accentTintStrong)
                        .frame(width: 36, height: 36)

                    Image(systemName: "person.3")
                        .font(Typography.subheadlineSemibold)
                        .foregroundStyle(Colors.accent)
                }

                // Team name + member count
                VStack(alignment: .leading, spacing: 1) {
                    Text(activeTeam?.name ?? "Select Team")
                        .font(Typography.termLg)
                        .foregroundStyle(Colors.textPrimary)
                        .lineLimit(1)

                    Text("\(activeTeam?.memberCount ?? 0) members · \(activeTeam?.artifacts.count ?? 0) artifacts")
                        .font(Typography.term2xs)
                        .foregroundStyle(Colors.textTertiary)
                }

                Image(systemName: "chevron.up.chevron.down")
                    .font(Typography.term2xs.weight(.medium))
                    .foregroundStyle(Colors.textTertiary)
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .background(
                RoundedRectangle.squircle(CornerRadius.medium)
                    .fill(Colors.surfacePrimary)
            )
            .overlay(
                RoundedRectangle.squircle(CornerRadius.medium)
                    .strokeBorder(Colors.accentBorder, lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private func teamRow(_ team: Team) -> some View {
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
                    .foregroundStyle(Colors.textSecondary)
            }
        }
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
        canDelete: true,
        canDuplicate: true,
        onSelect: { _ in },
        onAdd: {},
        onGenerate: {},
        onDuplicate: {},
        onDelete: {}
    )
    .padding()
    .frame(width: 400)
    .background(Colors.surfacePrimary)
}
