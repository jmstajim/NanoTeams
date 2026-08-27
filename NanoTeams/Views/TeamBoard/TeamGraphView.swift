import SwiftUI

// MARK: - Team Graph View

/// Read-only runtime view of the team graph showing execution status.
/// Uses shared TeamGraphCanvas for connection drawing.
struct TeamGraphView: View {
    let roleStatuses: [String: RoleExecutionStatus]
    let roleDefinitions: [TeamRoleDefinition]
    let nodePositions: [TeamNodePosition]
    let teamMembers: Set<String>
    @Binding var selectedRoleID: String?
    let producedArtifacts: Set<String>
    var team: Team? = nil
    var onRestartRole: ((String) -> Void)? = nil
    var onFinishRole: ((String) -> Void)? = nil
    var onCorrectRole: ((String) -> Void)? = nil
    var isChatMode: Bool = false
    var isPaused: Bool = false
    var isEngineRunning: Bool = true
    var meetingParticipants: Set<String> = []
    var isTaskInReview: Bool = false
    /// When set (non-nil), every role node renders its label as
    /// `RoleName.\(teamLabelSuffix)` — used by the parent panel to disambiguate
    /// a delegated child team's nodes from the parent team's nodes when both
    /// share `Role` enum cases (e.g. two teams with `.softwareEngineer`).
    /// `nil` = active team (bare role name).
    var teamLabelSuffix: String? = nil

    @Environment(\.windowResizeMonitor) private var resizeMonitor

    /// Shared layout cache — `collectConnections` + `computePortOffsets`
    /// memoized across the foreground/background Canvas pair and across
    /// every body re-evaluation during live resize. Reference-typed
    /// `Storage` inside survives `@State` value copies.
    @State private var layoutCache = TeamGraphLayoutCache()

    /// Last view size observed when NOT in live resize. Snapping to a 4px
    /// grid dampens sub-pixel jitter; freezing during resize means the
    /// graph keeps its pre-resize scale until `didEndLiveResize` fires.
    @State private var snappedViewSize: CGSize = .zero

    /// Bounding box of a set of node positions.
    ///
    /// A named `nonisolated struct` rather than the anonymous tuple this used to return:
    /// a tuple cannot be a parameter type without respelling it at every call site, and
    /// cannot be `Equatable` for the geometry tests.
    nonisolated struct Bounds: Equatable {
        let minX: CGFloat
        let maxX: CGFloat
        let minY: CGFloat
        let maxY: CGFloat
    }

    /// Visible node positions (Supervisor + team members only).
    ///
    /// Takes an `index` rather than scanning the roster per node: this used to be a
    /// computed property whose filter ran a linear roster scan for every node, and
    /// SwiftUI re-evaluates a computed property at every reference — five per body pass
    /// here (three through `nodeBounds`, one in `fitScale`, one as the `ForEach` data),
    /// so the cost was 5 × Θ(nodes × roles). `body` derives it ONCE and threads it.
    nonisolated static func visibleNodePositions(
        _ positions: [TeamNodePosition],
        index: RoleRosterIndex,
        teamMembers: Set<String>
    ) -> [TeamNodePosition] {
        positions.filter { position in
            let isSupervisor = index.role(forExactID: position.roleID)?.isSupervisor ?? false
            return isSupervisor || teamMembers.contains(position.roleID)
        }
    }

    /// Bounding box of visible node positions (single-pass)
    nonisolated static func nodeBounds(of positions: [TeamNodePosition]) -> Bounds? {
        guard let first = positions.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for pos in positions.dropFirst() {
            if pos.x < minX { minX = pos.x }
            if pos.x > maxX { maxX = pos.x }
            if pos.y < minY { minY = pos.y }
            if pos.y > maxY { maxY = pos.y }
        }
        return Bounds(minX: minX, maxX: maxX, minY: minY, maxY: maxY)
    }

    private static let runtimeNodeHeight: CGFloat = GraphTokens.nodeHeight

    /// Calculate scale factor so the graph fits within the view
    nonisolated static func fitScale(viewSize: CGSize, bounds: Bounds?, visibleCount: Int) -> CGFloat {
        guard let b = bounds, visibleCount >= 2 else { return 1.0 }

        let nodeW: CGFloat = GraphTokens.nodeMaxWidth
        let nodeH = Self.runtimeNodeHeight
        let padding: CGFloat = GraphTokens.edgePadding

        let graphW = (b.maxX - b.minX) + nodeW + padding * 2
        let graphH = (b.maxY - b.minY) + nodeH + padding * 2

        guard graphW > 0, graphH > 0, viewSize.width > 0, viewSize.height > 0 else { return 1.0 }

        return max(0.3, min(1.0, min(viewSize.width / graphW, viewSize.height / graphH)))
    }

    /// Extra horizontal margin to accommodate connection curves and labels
    /// that extend beyond the outermost nodes (e.g. skip-level Bezier control points).
    private static let connectionOvershoot: CGFloat = 80

    /// Graph-local offset: translates node positions so all coordinates are positive
    /// within a fixed-size frame. Prevents Canvas clipping at negative coordinates.
    nonisolated static func graphFrameSize(bounds: Bounds?) -> CGSize {
        guard let b = bounds else { return CGSize(width: 100, height: 100) }
        let nodeW: CGFloat = GraphTokens.nodeMaxWidth
        let nodeH = Self.runtimeNodeHeight
        let padding: CGFloat = GraphTokens.edgePadding
        let hMargin = padding + Self.connectionOvershoot
        return CGSize(
            width: (b.maxX - b.minX) + nodeW + hMargin * 2,
            height: (b.maxY - b.minY) + nodeH + padding * 2
        )
    }

    /// Offset to translate raw node positions into the graph-local frame
    /// (always positive, starts at padding)
    nonisolated static func graphLocalOffset(bounds: Bounds?) -> CGPoint {
        guard let b = bounds else { return .zero }
        let nodeW: CGFloat = GraphTokens.nodeMaxWidth
        let nodeH = Self.runtimeNodeHeight
        let padding: CGFloat = GraphTokens.edgePadding
        let hMargin = padding + Self.connectionOvershoot
        return CGPoint(
            x: -b.minX + nodeW / 2 + hMargin,
            y: -b.minY + nodeH / 2 + padding
        )
    }

    var body: some View {
        // Derived ONCE per body pass and threaded down. `body` already hoisted the three
        // CONSUMERS (scale / offset / frame size) but not the shared INPUT all three
        // re-derive, so `visibleNodePositions` ran five times per pass and `nodeBounds`
        // three — each a Θ(nodes × roles) filter. The roster index is built here rather
        // than in the parent because `GraphPanelView` constructs this view once per
        // delegation layer, so a parent-side build would only move the cost.
        let index = RoleRosterIndex(roster: roleDefinitions)
        let visible = Self.visibleNodePositions(nodePositions, index: index, teamMembers: teamMembers)
        let bounds = Self.nodeBounds(of: visible)
        let scale = Self.fitScale(viewSize: snappedViewSize, bounds: bounds, visibleCount: visible.count)
        let localOffset = Self.graphLocalOffset(bounds: bounds)
        let frameSize = Self.graphFrameSize(bounds: bounds)

        Color.clear
            .background(Colors.surfacePrimary)
            .overlay {
                graphContent(localOffset: localOffset, visible: visible, index: index)
                    .frame(width: frameSize.width, height: frameSize.height)
                    .scaleEffect(scale)
            }
            .clipped()
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { newSize in
                guard !resizeMonitor.isResizing else { return }
                let snapped = Self.snap(newSize)
                guard snapped != snappedViewSize else { return }
                snappedViewSize = snapped
            }
            .gesture(
                TapGesture()
                    .onEnded { _ in
                        selectedRoleID = nil
                    }
            )
    }

    /// Snap a view size to a 4-point grid. Resize gestures pour out
    /// sub-pixel size deltas; snapping coalesces them so we re-render once
    /// per ~4 px of drag instead of once per pixel.
    ///
    /// `nonisolated` because the math is pure and we want tests to call it
    /// without inheriting @MainActor isolation. Pinned by `TeamGraphViewSnapTests`.
    nonisolated static func snap(_ size: CGSize) -> CGSize {
        let grid: CGFloat = 4
        return CGSize(
            width: (size.width / grid).rounded() * grid,
            height: (size.height / grid).rounded() * grid
        )
    }

    @ViewBuilder
    private func graphContent(
        localOffset: CGPoint,
        visible: [TeamNodePosition],
        index: RoleRosterIndex
    ) -> some View {
        // Compute the structural layout ONCE per body re-evaluation and
        // hand the same `Layout` to both stacked canvas instances. Cache
        // hits skip the work entirely on resize-driven re-renders.
        let sharedLayout = layoutCache.layout(
            nodePositions: nodePositions,
            roleDefinitions: roleDefinitions,
            teamMembers: teamMembers,
            nodeSizes: [:],
            fallbackNodeWidth: GraphTokens.nodeMaxWidth
        )

        // Fixed-size graph content stays in an overlay so it does not advertise
        // its natural width back into the enclosing HSplitView layout.
        ZStack {
            // Connection lines (background — dims when a node is selected)
            TeamGraphCanvas(
                nodePositions: nodePositions,
                roleDefinitions: roleDefinitions,
                teamMembers: teamMembers,
                selectedRoleID: selectedRoleID,
                team: team,
                producedArtifacts: producedArtifacts,
                roleStatuses: roleStatuses,
                drawingOffset: localOffset,
                nodeHeight: Self.runtimeNodeHeight,
                precomputedLayout: sharedLayout,
                connectionFilter: selectedRoleID != nil ? .excludeHighlighted : .all
            )

            // Role nodes - positioned in graph-local coordinates
            ForEach(visible) { nodePosition in
                // The lookup `visibleNodePositions` already performed for this node and
                // discarded — same answer, O(1), no second roster scan.
                let roleDef = index.role(forExactID: nodePosition.roleID)
                let role = Role.builtInRole(for: nodePosition.roleID) ?? .custom(id: nodePosition.roleID)
                let status = roleStatuses[nodePosition.roleID] ?? .idle

                let baseRoleName = roleDef?.name ?? role.displayName
                let displayedRoleName = displayRoleLabel(
                    roleName: baseRoleName,
                    teamName: teamLabelSuffix,
                    isChildTeam: teamLabelSuffix != nil
                )
                RoleNodeRuntimeView(
                    roleID: nodePosition.roleID,
                    roleName: displayedRoleName,
                    roleIcon: roleDef?.icon ?? "person",
                    status: status,
                    isSelected: selectedRoleID == nodePosition.roleID,
                    position: CGPoint(
                        x: nodePosition.x + localOffset.x,
                        y: nodePosition.y + localOffset.y
                    ),
                    onSelect: {
                        selectedRoleID = nodePosition.roleID
                    },
                    onRestart: onRestartRole.map { callback in
                        { callback(nodePosition.roleID) }
                    },
                    onFinish: RoleFinishPolicy.canFinish(roleDef: roleDef, status: status, isChatMode: isChatMode)
                        ? onFinishRole.map { callback in { callback(nodePosition.roleID) } }
                        : nil,
                    onCorrect: onCorrectRole.map { callback in
                        { callback(nodePosition.roleID) }
                    },
                    isPaused: isPaused,
                    isEngineRunning: isEngineRunning,
                    isInMeeting: meetingParticipants.contains(nodePosition.roleID),
                    isReviewNode: isTaskInReview && (roleDef?.isSupervisor ?? false),
                    roleTintColor: roleDef?.resolvedTintColor ?? role.tintColor
                )
            }

            // Connection lines (foreground — highlighted connections on top of nodes)
            if selectedRoleID != nil {
                TeamGraphCanvas(
                    nodePositions: nodePositions,
                    roleDefinitions: roleDefinitions,
                    teamMembers: teamMembers,
                    selectedRoleID: selectedRoleID,
                    team: team,
                    producedArtifacts: producedArtifacts,
                    roleStatuses: roleStatuses,
                    drawingOffset: localOffset,
                    nodeHeight: Self.runtimeNodeHeight,
                    precomputedLayout: sharedLayout,
                    connectionFilter: .onlyHighlighted
                )
                .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Previews

#Preview("Graph — Idle") {
    @Previewable @State var selectedRoleID: String? = nil
    let team = Team.default
    TeamGraphView(
        roleStatuses: [:],
        roleDefinitions: team.roles,
        nodePositions: team.graphLayout.nodePositions,
        teamMembers: Set(team.roles.map(\.id)),
        selectedRoleID: $selectedRoleID,
        producedArtifacts: [],
        team: team
    )
    .frame(width: 600, height: 500)
}

#Preview("Graph — In Progress") {
    @Previewable @State var selectedRoleID: String? = nil
    let team = Team.default
    TeamGraphView(
        roleStatuses: [
            team.roles[0].id: .done,
            team.roles[1].id: .done,
            team.roles[2].id: .working,
            team.roles[3].id: .ready,
            team.roles[4].id: .working,
        ],
        roleDefinitions: team.roles,
        nodePositions: team.graphLayout.nodePositions,
        teamMembers: Set(team.roles.map(\.id)),
        selectedRoleID: $selectedRoleID,
        producedArtifacts: ["Supervisor Task", "Product Requirements"],
        team: team,
        isEngineRunning: true
    )
    .frame(width: 600, height: 500)
}

#Preview("Graph — Selected Node") {
    @Previewable @State var selectedRoleID: String? = Team.default.roles.first(where: { $0.name == "Software Engineer" })?.id
    let team = Team.default
    TeamGraphView(
        roleStatuses: [
            team.roles[0].id: .done,
            team.roles[1].id: .done,
            team.roles[2].id: .done,
            team.roles[3].id: .done,
            team.roles[4].id: .done,
            team.roles[5].id: .working,
        ],
        roleDefinitions: team.roles,
        nodePositions: team.graphLayout.nodePositions,
        teamMembers: Set(team.roles.map(\.id)),
        selectedRoleID: $selectedRoleID,
        producedArtifacts: ["Supervisor Task", "Product Requirements", "Research Report", "Design Spec", "Implementation Plan"],
        team: team,
        isEngineRunning: true
    )
    .frame(width: 600, height: 500)
}

#Preview("Graph — Meeting") {
    @Previewable @State var selectedRoleID: String? = nil
    let team = Team.default
    TeamGraphView(
        roleStatuses: [
            team.roles[0].id: .done,
            team.roles[1].id: .working,
            team.roles[4].id: .working,
        ],
        roleDefinitions: team.roles,
        nodePositions: team.graphLayout.nodePositions,
        teamMembers: Set(team.roles.map(\.id)),
        selectedRoleID: $selectedRoleID,
        producedArtifacts: ["Supervisor Task"],
        team: team,
        isEngineRunning: true,
        meetingParticipants: Set([team.roles[1].id, team.roles[4].id])
    )
    .frame(width: 600, height: 500)
}
