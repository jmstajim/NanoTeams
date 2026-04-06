import SwiftUI

// MARK: - Team Graph Canvas Geometry

/// Pure geometry algorithms for computing connection layout between role nodes.
/// Extracted from TeamGraphCanvas for testability and SRP.
enum TeamGraphCanvasGeometry {

    /// A single artifact dependency connection between two roles.
    struct ConnectionInfo {
        let producerID: String
        let consumerID: String
        let artifactName: String
        let fromPos: TeamNodePosition
        let toPos: TeamNodePosition
    }

    /// Collect all artifact dependency connections for visible roles.
    static func collectConnections(
        nodePositions: [TeamNodePosition],
        roleDefinitions: [TeamRoleDefinition],
        teamMembers: Set<String>
    ) -> [ConnectionInfo] {
        var result: [ConnectionInfo] = []
        for nodePos in nodePositions {
            guard teamMembers.contains(nodePos.roleID) else { continue }
            guard let roleDef = roleDefinitions.first(where: { $0.id == nodePos.roleID }) else { continue }
            // Skip incoming connections for Supervisor (user-controlled role)
            if roleDef.isSupervisor { continue }

            for requiredArtifact in roleDef.dependencies.requiredArtifacts {
                let producers = roleDefinitions.filter { producerDef in
                    teamMembers.contains(producerDef.id) &&
                    producerDef.dependencies.producesArtifacts.contains(requiredArtifact)
                }
                for producer in producers {
                    guard let fromPos = nodePositions.first(where: { $0.roleID == producer.id }) else { continue }
                    result.append(ConnectionInfo(
                        producerID: producer.id,
                        consumerID: nodePos.roleID,
                        artifactName: requiredArtifact,
                        fromPos: fromPos,
                        toPos: nodePos
                    ))
                }
            }
        }
        return result
    }

    /// Compute X offsets for connection endpoints to distribute them along node edges.
    /// Returns (sourceOffsets, targetOffsets) keyed by connection index.
    static func computePortOffsets(
        connections: [ConnectionInfo],
        nodeSizes: [String: CGSize],
        fallbackNodeWidth: CGFloat
    ) -> (source: [Int: CGFloat], target: [Int: CGFloat]) {
        var sourceOffsets: [Int: CGFloat] = [:]
        var targetOffsets: [Int: CGFloat] = [:]

        // Group connection indices by source/target role
        var outgoingBySource: [String: [Int]] = [:]
        var incomingByTarget: [String: [Int]] = [:]
        for (index, conn) in connections.enumerated() {
            outgoingBySource[conn.producerID, default: []].append(index)
            incomingByTarget[conn.consumerID, default: []].append(index)
        }

        let portSpread = GraphTokens.portSpreadFraction

        // Distribute outgoing ports (bottom edge of source nodes)
        for (roleID, indices) in outgoingBySource {
            let nodeW = nodeSizes[roleID]?.width ?? fallbackNodeWidth
            let spreadWidth = nodeW * portSpread
            // Sort by target X so port position matches curve direction
            let sorted = indices.sorted { a, b in
                let ca = connections[a], cb = connections[b]
                if ca.toPos.x != cb.toPos.x { return ca.toPos.x < cb.toPos.x }
                return ca.toPos.y < cb.toPos.y
            }
            let count = sorted.count
            for (i, connIndex) in sorted.enumerated() {
                if count <= 1 {
                    sourceOffsets[connIndex] = 0
                } else {
                    let t = CGFloat(i) / CGFloat(count - 1) - 0.5
                    sourceOffsets[connIndex] = t * spreadWidth
                }
            }
        }

        // Distribute incoming ports (top edge of target nodes)
        for (roleID, indices) in incomingByTarget {
            let nodeW = nodeSizes[roleID]?.width ?? fallbackNodeWidth
            let spreadWidth = nodeW * portSpread
            // Sort by source X so port position matches curve arrival direction
            let sorted = indices.sorted { a, b in
                let ca = connections[a], cb = connections[b]
                if ca.fromPos.x != cb.fromPos.x { return ca.fromPos.x < cb.fromPos.x }
                return ca.fromPos.y < cb.fromPos.y
            }
            let count = sorted.count
            for (i, connIndex) in sorted.enumerated() {
                if count <= 1 {
                    targetOffsets[connIndex] = 0
                } else {
                    let t = CGFloat(i) / CGFloat(count - 1) - 0.5
                    targetOffsets[connIndex] = t * spreadWidth
                }
            }
        }

        return (sourceOffsets, targetOffsets)
    }

    /// Compute the control point X for a connection's Bezier curve.
    ///
    /// - **Adjacent connections** (≤ 1 depth level): `controlX = to.x` (C-curve toward target).
    /// - **Skip-level connections** (> 1 depth level): checks if the default C-curve would pass
    ///   through any intermediate node's bounding box. If so, computes the minimum offset to
    ///   route around the obstruction, choosing the direction with smaller deviation.
    static func controlX(
        from: CGPoint,
        to: CGPoint,
        producerID: String,
        consumerID: String,
        nodePositions: [TeamNodePosition],
        drawingOffset: CGPoint
    ) -> CGFloat {
        let dy = abs(to.y - from.y)
        guard dy > 180 else {
            return to.x  // Adjacent: C-curve toward target
        }

        let defaultControlX = to.x
        let halfWidth = GraphTokens.nodeMaxWidth / 2
        let margin: CGFloat = 20

        // Check intermediate nodes for collision with the default curve
        var maxRightControlX = defaultControlX
        var minLeftControlX = defaultControlX
        var hasCollision = false

        for pos in nodePositions {
            guard pos.roleID != producerID && pos.roleID != consumerID else { continue }
            let nodeY = pos.y + drawingOffset.y
            let nodeX = pos.x + drawingOffset.x
            guard nodeY > from.y && nodeY < to.y else { continue }

            // Compute where the default curve passes at this node's Y level
            let t = (nodeY - from.y) / (to.y - from.y)
            guard t > 0.01 && t < 0.99 else { continue }
            let bezierX = cubicBezierX(t: t, fromX: from.x, controlX: defaultControlX, toX: to.x)

            // Check if curve passes through node bounds
            guard bezierX > nodeX - halfWidth - margin && bezierX < nodeX + halfWidth + margin else {
                continue
            }
            hasCollision = true

            // Compute controlX needed to route RIGHT of this node
            let coeff = 3 * t * (1 - t)
            guard coeff > 0.01 else { continue }
            let fromTerm = pow(1 - t, 3) * from.x
            let toTerm = pow(t, 3) * to.x

            let rightTarget = nodeX + halfWidth + margin
            let rightControlX = (rightTarget - fromTerm - toTerm) / coeff
            maxRightControlX = max(maxRightControlX, rightControlX)

            // Compute controlX needed to route LEFT of this node
            let leftTarget = nodeX - halfWidth - margin
            let leftControlX = (leftTarget - fromTerm - toTerm) / coeff
            minLeftControlX = min(minLeftControlX, leftControlX)
        }

        guard hasCollision else { return defaultControlX }

        // Choose direction with smaller deviation from default
        let rightDeviation = abs(maxRightControlX - defaultControlX)
        let leftDeviation = abs(minLeftControlX - defaultControlX)
        return rightDeviation <= leftDeviation ? maxRightControlX : minLeftControlX
    }

    /// Cubic Bezier X at parameter t, with cp1.x = cp2.x = controlX.
    static func cubicBezierX(t: CGFloat, fromX: CGFloat, controlX: CGFloat, toX: CGFloat) -> CGFloat {
        let u = 1 - t
        return u * u * u * fromX + 3 * u * u * t * controlX + 3 * u * t * t * controlX + t * t * t * toX
    }
}
