import SwiftUI

// MARK: - Team Graph Editor View

/// Interactive team graph editor with draggable role nodes and dependency visualization.
/// Double-tap a node to open the role editor sheet.
struct TeamGraphEditorView: View {
    @Binding var team: Team
    @Binding var selectedRoleID: String?
    let onSave: () -> Void

    @State private var editingRole: TeamRoleDefinition? = nil
    @State private var nodeSizes: [String: CGSize] = [:]
    private static let editorNodeHeight: CGFloat = GraphTokens.nodeHeight

    /// Get all team member IDs (all roles in team)
    private var teamMemberIDs: Set<String> {
        Set(team.roles.map(\.id))
    }

    /// Bounding box of node positions (single-pass)
    private var nodeBounds: (minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat)? {
        let positions = team.graphLayout.nodePositions
        guard let first = positions.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for pos in positions.dropFirst() {
            if pos.x < minX { minX = pos.x }
            if pos.x > maxX { maxX = pos.x }
            if pos.y < minY { minY = pos.y }
            if pos.y > maxY { maxY = pos.y }
        }
        return (minX, maxX, minY, maxY)
    }

    /// Calculate the center point of all nodes
    private var graphCenter: CGPoint {
        guard let b = nodeBounds else { return .zero }
        return CGPoint(x: (b.minX + b.maxX) / 2, y: (b.minY + b.maxY) / 2)
    }

    var body: some View {
        GeometryReader { geometry in
            let scale = fitScale(viewSize: geometry.size)
            // Inflate inner content so after scaleEffect it fills the full view
            let contentSize = CGSize(
                width: geometry.size.width / scale,
                height: geometry.size.height / scale
            )
            let viewCenter = CGPoint(x: contentSize.width / 2, y: contentSize.height / 2)
            let offset = CGPoint(x: viewCenter.x - graphCenter.x, y: viewCenter.y - graphCenter.y)

            ZStack {
                // Background — not scaled
                Colors.surfacePrimary

                // Scaled graph content — use ZStack (not Group) so scaleEffect
                // applies to the container as a whole, keeping Canvas and nodes aligned.
                ZStack {
                    // Connection lines (background layer — dims when a node is selected)
                    TeamGraphCanvas(
                        nodePositions: team.graphLayout.nodePositions,
                        roleDefinitions: team.roles,
                        teamMembers: teamMemberIDs,
                        selectedRoleID: selectedRoleID,
                        team: team,
                        producedArtifacts: nil,
                        roleStatuses: nil,
                        drawingOffset: offset,
                        nodeHeight: Self.editorNodeHeight,
                        nodeSizes: nodeSizes,
                        connectionFilter: selectedRoleID != nil ? .excludeHighlighted : .all
                    )

                    // Role nodes
                    ForEach(team.roles) { role in
                        if let nodePos = team.graphLayout.nodePositions.first(where: { $0.roleID == role.id }) {
                            let builtInRole = Role.builtInRole(for: role.id) ?? .custom(id: role.id)

                            TeamNodeView(
                                roleName: role.name,
                                icon: role.icon,
                                tintColor: role.resolvedTintColor,
                                dependencies: role.dependencies,
                                isSelected: selectedRoleID == role.id,
                                position: CGPoint(
                                    x: nodePos.x + offset.x,
                                    y: nodePos.y + offset.y
                                ),
                                onSelect: {
                                    selectedRoleID = role.id
                                },
                                onDrag: { newPosition in
                                    handleDrag(roleID: role.id, to: newPosition, offset: offset)
                                },
                                onDragEnd: {
                                    onSave()
                                },
                                onDoubleTap: {
                                    editingRole = role
                                },
                                onRemoveFromGraph: isSupervisor(role) ? nil : {
                                    handleHideRole(role)
                                },
                                onMeasure: { size in
                                    nodeSizes[role.id] = size
                                },
                                isSupervisor: isSupervisor(role)
                            )
                        }
                    }

                    // Connection lines (foreground layer — highlighted connections on top of nodes)
                    if selectedRoleID != nil {
                        TeamGraphCanvas(
                            nodePositions: team.graphLayout.nodePositions,
                            roleDefinitions: team.roles,
                            teamMembers: teamMemberIDs,
                            selectedRoleID: selectedRoleID,
                            team: team,
                            producedArtifacts: nil,
                            roleStatuses: nil,
                            drawingOffset: offset,
                            nodeHeight: Self.editorNodeHeight,
                            nodeSizes: nodeSizes,
                            connectionFilter: .onlyHighlighted
                        )
                        .allowsHitTesting(false)
                    }
                }
                .frame(width: contentSize.width, height: contentSize.height)
                .scaleEffect(scale)
                .frame(width: geometry.size.width, height: geometry.size.height)

                // Instructions overlay — not scaled
                if team.roles.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "person.badge.plus")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)

                        Text("No Roles in Team")
                            .font(.headline)

                        Text("Add roles using the Roles tab")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                            .fill(Colors.surfaceCard)
                            .shadow(radius: 3)
                    )
                }
            }
            .clipped()
            .gesture(
                TapGesture()
                    .onEnded { _ in
                        selectedRoleID = nil
                    }
            )
        }
        .onAppear {
            ensureAllRolesHavePositions()
        }
        .onChange(of: team.roles.count) { _, _ in
            ensureAllRolesHavePositions()
        }
        .sheet(item: $editingRole) { role in
            RoleEditorSheet(
                team: $team,
                mode: .edit(role),
                onSave: onSave
            )
        }
    }

    // MARK: - Scaling

    /// Calculate scale factor so the graph fits within the view
    private func fitScale(viewSize: CGSize) -> CGFloat {
        guard let b = nodeBounds, team.graphLayout.nodePositions.count >= 2 else { return 1.0 }

        let nodeW = TeamNodeView.nodeMaxWidth
        let nodeH: CGFloat = Self.editorNodeHeight
        let padding: CGFloat = 20

        let graphW = (b.maxX - b.minX) + nodeW + padding * 2
        let graphH = (b.maxY - b.minY) + nodeH + padding * 2

        guard graphW > 0, graphH > 0, viewSize.width > 0, viewSize.height > 0 else { return 1.0 }

        return max(0.3, min(1.0, min(viewSize.width / graphW, viewSize.height / graphH)))
    }

    // MARK: - Helpers

    /// Check if role is Supervisor
    private func isSupervisor(_ role: TeamRoleDefinition) -> Bool {
        role.isSupervisor
    }

    /// Handle node drag
    private func handleDrag(roleID: String, to newPosition: CGPoint, offset: CGPoint) {
        // Remove offset to get actual graph coordinates
        let graphPosition = CGPoint(
            x: newPosition.x - offset.x,
            y: newPosition.y - offset.y
        )

        team.graphLayout.setPosition(for: roleID, x: graphPosition.x, y: graphPosition.y)
    }

    /// Hide role from graph (keeps role in team)
    private func handleHideRole(_ role: TeamRoleDefinition) {
        team.graphLayout.hideRole(role.id)

        if selectedRoleID == role.id {
            selectedRoleID = nil
        }

        onSave()
    }

    // MARK: - Ensure Positions

    /// Ensure all roles have positions in the graph layout
    private func ensureAllRolesHavePositions() {
        let existingPositions = Set(team.graphLayout.nodePositions.map(\.roleID))
        let roleIDs = Set(team.roles.map(\.id))

        let hasMissing = roleIDs.contains { roleID in
            !existingPositions.contains(roleID) && !team.graphLayout.hiddenRoleIDs.contains(roleID)
        }
        let hasDeleted = existingPositions.contains { !roleIDs.contains($0) }

        guard hasMissing || hasDeleted else { return }

        if hasMissing {
            // Recompute full layout from dependencies to place new roles correctly
            let autoLayout = TeamGraphLayout.autoLayout(for: team.roles)
            for pos in autoLayout.nodePositions where !existingPositions.contains(pos.roleID)
                                                       && !team.graphLayout.hiddenRoleIDs.contains(pos.roleID) {
                team.graphLayout.setPosition(for: pos.roleID, x: pos.x, y: pos.y)
            }
        }

        // Remove positions for deleted roles
        team.graphLayout.nodePositions.removeAll { pos in
            !roleIDs.contains(pos.roleID)
        }

        // Clean up hidden role IDs for deleted roles
        team.graphLayout.pruneHiddenRoles(existingRoleIDs: roleIDs)

        onSave()
    }
}

// MARK: - Previews

#Preview("Graph Editor") {
    @Previewable @State var team = Team.default
    @Previewable @State var selectedRoleID: String? = nil
    TeamGraphEditorView(team: $team, selectedRoleID: $selectedRoleID, onSave: {})
        .frame(width: 700, height: 500)
}

#Preview("Graph Editor — Selected") {
    @Previewable @State var team = Team.default
    @Previewable @State var selectedRoleID: String? = Team.default.roles.first(where: { !$0.isSupervisor })?.id
    TeamGraphEditorView(team: $team, selectedRoleID: $selectedRoleID, onSave: {})
        .frame(width: 700, height: 500)
}
