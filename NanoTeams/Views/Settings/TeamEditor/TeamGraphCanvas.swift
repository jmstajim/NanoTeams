import SwiftUI

// MARK: - Team Graph Canvas

/// Canvas for drawing artifact dependency connections between role nodes.
/// Arrows connect from the bottom edge of the source node to the top edge of the target node.
/// When a node is selected, incoming connections are highlighted blue and outgoing green.
/// Connection endpoints are distributed along node edges to prevent overlapping lines.
struct TeamGraphCanvas: View {
    let nodePositions: [TeamNodePosition]
    let roleDefinitions: [TeamRoleDefinition]
    let teamMembers: Set<String>
    let selectedRoleID: String?
    var team: Team?
    var producedArtifacts: Set<String>?
    var roleStatuses: [String: RoleExecutionStatus]?
    var drawingOffset: CGPoint = .zero
    var nodeHeight: CGFloat = 90
    var nodeSizes: [String: CGSize] = [:]

    /// Controls which connections to draw (for layered rendering).
    /// `.all` draws everything. `.excludeHighlighted` draws only dim connections.
    /// `.onlyHighlighted` draws only connections involving the selected node.
    var connectionFilter: ConnectionDrawMode = .all

    @ScaledMetric(relativeTo: .caption2) private var labelFontSize: CGFloat = 9
    @ScaledMetric(relativeTo: .caption2) private var highlightedLabelFontSize: CGFloat = 10

    enum ConnectionDrawMode {
        case all
        case excludeHighlighted
        case onlyHighlighted
    }

    /// Check if artifact has been produced
    private func isArtifactProduced(_ artifactName: String) -> Bool {
        producedArtifacts?.contains(artifactName) ?? false
    }

    /// Get role status
    private func status(for roleID: String) -> RoleExecutionStatus {
        roleStatuses?[roleID] ?? .idle
    }

    var body: some View {
        Canvas { context, size in
            let allConnections = TeamGraphCanvasGeometry.collectConnections(
                nodePositions: nodePositions,
                roleDefinitions: roleDefinitions,
                teamMembers: teamMembers
            )
            let (sourceOffsets, targetOffsets) = TeamGraphCanvasGeometry.computePortOffsets(
                connections: allConnections,
                nodeSizes: nodeSizes,
                fallbackNodeWidth: GraphTokens.nodeMaxWidth
            )

            for (index, conn) in allConnections.enumerated() {
                let sourcePortX = sourceOffsets[index] ?? 0
                let targetPortX = targetOffsets[index] ?? 0

                let fromNodeH = nodeSizes[conn.producerID]?.height ?? nodeHeight
                let toNodeH = nodeSizes[conn.consumerID]?.height ?? nodeHeight

                // Source: bottom edge of producer node (with port offset)
                let fromPoint = CGPoint(
                    x: conn.fromPos.x + drawingOffset.x + sourcePortX,
                    y: conn.fromPos.y + drawingOffset.y + fromNodeH / 2
                )
                // Target: top edge of consumer node (with port offset)
                let toPoint = CGPoint(
                    x: conn.toPos.x + drawingOffset.x + targetPortX,
                    y: conn.toPos.y + drawingOffset.y - toNodeH / 2
                )

                // Determine connection color based on selection
                let strokeColor: Color
                let isDashed: Bool

                if let selected = selectedRoleID {
                    if selected == conn.consumerID && conn.producerID != selected {
                        // Incoming dependency — subtle highlight
                        strokeColor = Colors.textSecondary
                        isDashed = false
                    } else if selected == conn.producerID && conn.consumerID != selected {
                        // Outgoing dependency — subtle highlight
                        strokeColor = Colors.textSecondary
                        isDashed = false
                    } else if selected == conn.producerID && selected == conn.consumerID {
                        strokeColor = Colors.textSecondary
                        isDashed = false
                    } else {
                        // Unrelated — dim
                        strokeColor = Colors.borderSubtle
                        isDashed = true
                    }
                } else {
                    // No selection: structural colors (gray), not status colors
                    let producerStatus = status(for: conn.producerID)
                    let consumerStatus = status(for: conn.consumerID)

                    if producerStatus == .failed || consumerStatus == .failed {
                        strokeColor = Colors.error
                        isDashed = false
                    } else if isArtifactProduced(conn.artifactName) {
                        // Artifact delivered — bright gray (not green)
                        strokeColor = Colors.textSecondary
                        isDashed = false
                    } else if producerStatus == .working {
                        // In progress — medium gray, dashed
                        strokeColor = Colors.neutral
                        isDashed = true
                    } else {
                        // Default — visible but muted
                        strokeColor = Colors.neutral
                        isDashed = true
                    }
                }

                let isHighlighted = selectedRoleID == conn.producerID || selectedRoleID == conn.consumerID

                // Apply connection filter
                switch connectionFilter {
                case .excludeHighlighted where isHighlighted:
                    continue
                case .onlyHighlighted where !isHighlighted:
                    continue
                default:
                    break
                }

                let controlX = TeamGraphCanvasGeometry.controlX(
                    from: fromPoint,
                    to: toPoint,
                    producerID: conn.producerID,
                    consumerID: conn.consumerID,
                    nodePositions: nodePositions,
                    drawingOffset: drawingOffset
                )

                drawConnection(
                    context: context,
                    from: fromPoint,
                    to: toPoint,
                    controlX: controlX,
                    color: strokeColor,
                    isDashed: isDashed,
                    isHighlighted: isHighlighted
                )

                drawArtifactLabel(
                    context: context,
                    label: conn.artifactName,
                    from: fromPoint,
                    to: toPoint,
                    controlX: controlX,
                    color: strokeColor,
                    isHighlighted: isHighlighted
                )
            }
        }
    }

    // MARK: - Drawing

    /// Draw a connection line between two points.
    private func drawConnection(
        context: GraphicsContext,
        from: CGPoint,
        to: CGPoint,
        controlX: CGFloat,
        color: Color,
        isDashed: Bool,
        isHighlighted: Bool
    ) {
        var path = Path()

        let dy = abs(to.y - from.y)
        let controlOffset = max(dy * 0.4, 30)
        let controlPoint1 = CGPoint(x: controlX, y: from.y + controlOffset)
        let controlPoint2 = CGPoint(x: controlX, y: to.y - controlOffset)
        let arrowLength: CGFloat = isHighlighted ? GraphTokens.highlightedArrowLength : GraphTokens.arrowLength
        let lineWidth: CGFloat = isHighlighted ? GraphTokens.highlightedLineWidth : GraphTokens.connectionLineWidth

        // Shorten the line so it ends at the arrowhead base
        let arrowDepth = arrowLength * cos(.pi / 6)
        let tangentDx = to.x - controlPoint2.x
        let tangentDy = to.y - controlPoint2.y
        let tangentLen = hypot(tangentDx, tangentDy)
        let lineEnd: CGPoint
        if tangentLen > 0 {
            lineEnd = CGPoint(
                x: to.x - (tangentDx / tangentLen) * arrowDepth,
                y: to.y - (tangentDy / tangentLen) * arrowDepth
            )
        } else {
            lineEnd = to
        }

        path.move(to: from)
        path.addCurve(to: lineEnd, control1: controlPoint1, control2: controlPoint2)

        if isDashed {
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: [5, 3])
            )
        } else {
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
        }

        drawArrowhead(context: context, at: to, from: controlPoint2, color: color, arrowLength: arrowLength)
    }

    /// Draw artifact name label at the midpoint of a connection
    private func drawArtifactLabel(
        context: GraphicsContext,
        label: String,
        from: CGPoint,
        to: CGPoint,
        controlX: CGFloat,
        color: Color,
        isHighlighted: Bool
    ) {
        let midX = 0.125 * from.x + 0.75 * controlX + 0.125 * to.x
        let midY = (from.y + to.y) / 2

        let dx = controlX - from.x
        let offsetX: CGFloat = abs(dx) < 1 ? -4 : (dx > 0 ? 4 : -4)
        let labelPoint = CGPoint(x: midX + offsetX, y: midY)

        let fontSize: CGFloat = isHighlighted ? highlightedLabelFontSize : labelFontSize
        let textColor = isHighlighted ? color : Colors.textSecondary

        let displayLabel = label.count > 20 ? String(label.prefix(18)) + "..." : label

        let text = Text(displayLabel)
            .font(.system(size: fontSize, weight: isHighlighted ? .medium : .regular))
            .foregroundStyle(textColor)

        let resolvedText = context.resolve(text)
        let textSize = resolvedText.measure(in: CGSize(width: 200, height: 30))

        let pillRect = CGRect(
            x: labelPoint.x - textSize.width / 2 - GraphTokens.labelPaddingH,
            y: labelPoint.y - textSize.height / 2 - GraphTokens.labelPaddingV,
            width: textSize.width + GraphTokens.labelPaddingH * 2,
            height: textSize.height + GraphTokens.labelPaddingV * 2
        )

        let pillPath = RoundedRectangle(cornerRadius: GraphTokens.labelCornerRadius, style: .continuous).path(in: pillRect)
        context.fill(pillPath, with: .color(Colors.surfaceElevated))
        context.stroke(pillPath, with: .color(color.opacity(DynamicTintOpacity.stroke)), lineWidth: 0.5)

        context.draw(resolvedText, at: labelPoint, anchor: .center)
    }

    /// Draw arrowhead at the end of connection
    private func drawArrowhead(
        context: GraphicsContext,
        at point: CGPoint,
        from controlPoint: CGPoint,
        color: Color,
        arrowLength: CGFloat
    ) {
        let angle = atan2(point.y - controlPoint.y, point.x - controlPoint.x)
        let arrowAngle: CGFloat = .pi / 6

        var arrowPath = Path()
        let tip1 = CGPoint(
            x: point.x - arrowLength * cos(angle - arrowAngle),
            y: point.y - arrowLength * sin(angle - arrowAngle)
        )
        let tip2 = CGPoint(
            x: point.x - arrowLength * cos(angle + arrowAngle),
            y: point.y - arrowLength * sin(angle + arrowAngle)
        )

        arrowPath.move(to: point)
        arrowPath.addLine(to: tip1)
        arrowPath.addLine(to: tip2)
        arrowPath.closeSubpath()

        context.fill(arrowPath, with: .color(color))
    }
}

// MARK: - Previews

#Preview("Graph Canvas") {
    let team = Team.default
    TeamGraphCanvas(
        nodePositions: team.graphLayout.nodePositions,
        roleDefinitions: team.roles,
        teamMembers: Set(team.roles.map(\.id)),
        selectedRoleID: nil,
        team: team,
        producedArtifacts: ["Supervisor Task", "Product Requirements"],
        roleStatuses: [
            "supervisor": .done,
            "productManager": .done,
            "techLead": .working,
        ],
        drawingOffset: CGPoint(x: 50, y: 20)
    )
    .frame(width: 600, height: 500)
    .background(Colors.surfaceCard)
}

#Preview("Canvas — Selected Node") {
    let team = Team.default
    TeamGraphCanvas(
        nodePositions: team.graphLayout.nodePositions,
        roleDefinitions: team.roles,
        teamMembers: Set(team.roles.map(\.id)),
        selectedRoleID: team.roles.first(where: { $0.name == "Tech Lead" })?.id,
        team: team,
        drawingOffset: CGPoint(x: 50, y: 20)
    )
    .frame(width: 600, height: 500)
    .background(Colors.surfaceCard)
}
