import CoreGraphics

// MARK: - Team Graph Layout Calculator

/// Pure algorithm for computing visual positions of role nodes from artifact dependencies.
/// Separated from `TeamGraphLayout` (data model) per SRP.
enum TeamGraphLayoutCalculator {

    /// Horizontal offset amplitude for single-node zigzag levels in auto-layout.
    /// Must be large enough that left/right columns don't overlap (amplitude > nodeMaxWidth/2).
    private static let zigzagAmplitude: CGFloat = 100

    /// Compute a graph layout from artifact dependencies using topological depth.
    ///
    /// - Supervisor at depth 0
    /// - Non-Supervisor roles with no required artifacts at depth 1
    /// - Others at `1 + max(depth of producer roles for each required artifact)`
    /// - Roles at the same depth are centered horizontally
    static func autoLayout(for roles: [TeamRoleDefinition]) -> TeamGraphLayout {
        guard !roles.isEmpty else { return TeamGraphLayout() }

        // Separate observers from active roles — observers are positioned at the bottom
        let activeRoles = roles.filter { !$0.isObserver }
        let observers = roles.filter { $0.isObserver }

        // Map artifact name → producer role ID
        var producerOf: [String: String] = [:]
        for role in activeRoles {
            for artifact in role.dependencies.producesArtifacts {
                producerOf[artifact] = role.id
            }
        }

        // Compute depth per role (memoized)
        var depths: [String: Int] = [:]

        func depth(of role: TeamRoleDefinition) -> Int {
            if let cached = depths[role.id] { return cached }
            if role.isSupervisor {
                depths[role.id] = 0
                return 0
            }
            let required = role.dependencies.requiredArtifacts
            if required.isEmpty {
                depths[role.id] = 1
                return 1
            }
            var maxProducerDepth = 0
            for artifact in required {
                if let producerID = producerOf[artifact],
                   let producer = roles.first(where: { $0.id == producerID }) {
                    maxProducerDepth = max(maxProducerDepth, depth(of: producer))
                }
            }
            let d = maxProducerDepth + 1
            depths[role.id] = d
            return d
        }

        for role in activeRoles { _ = depth(of: role) }

        // Group by depth level, preserving array order within each level
        let maxDepth = depths.values.max() ?? 0
        var levels: [[TeamRoleDefinition]] = Array(repeating: [], count: maxDepth + 1)
        for role in activeRoles {
            let d = depths[role.id] ?? 1
            levels[d].append(role)
        }

        // Position nodes — spacing must exceed node dimensions to avoid overlap
        // Editor nodes: maxWidth 200, height ~80; Runtime nodes: maxWidth 130, height ~60
        let centerX: CGFloat = 300
        let startY: CGFloat = 40
        let verticalSpacing: CGFloat = 140
        let horizontalSpacing: CGFloat = 220

        var positions: [TeamNodePosition] = []
        for (level, rolesInLevel) in levels.enumerated() {
            let count = CGFloat(rolesInLevel.count)
            for (i, role) in rolesInLevel.enumerated() {
                let x = centerX + (CGFloat(i) - (count - 1) / 2.0) * horizontalSpacing
                let y = startY + CGFloat(level) * verticalSpacing
                positions.append(TeamNodePosition(roleID: role.id, x: x, y: y))
            }
        }

        // Pass 2: Zigzag single-node intermediate levels that have skip-level connections.
        // Only activate zigzag if the graph has enough skip connections to benefit (≥3 pairs).
        // Linear chains (e.g., FAANG with 5 roles, 1 skip pair) stay straight — zigzag would
        // just offset nodes without reducing crossings. Dense graphs (e.g., Quest Party with
        // 5+ skip pairs) benefit from zigzag to separate overlapping edges.

        // Build bidirectional connection map: roleID → set of connected roleIDs
        var connections: [String: Set<String>] = [:]
        for role in activeRoles {
            for artifact in role.dependencies.requiredArtifacts {
                if let pid = producerOf[artifact] {
                    connections[pid, default: []].insert(role.id)
                    connections[role.id, default: []].insert(pid)
                }
            }
        }

        // Count unique skip-level connection pairs (depth diff > 1)
        var skipPairCount = 0
        var countedPairs: Set<String> = []
        for (roleID, connectedIDs) in connections {
            guard let roleDepth = depths[roleID] else { continue }
            for connectedID in connectedIDs {
                let pairKey = roleID < connectedID ? "\(roleID)|\(connectedID)" : "\(connectedID)|\(roleID)"
                guard !countedPairs.contains(pairKey) else { continue }
                countedPairs.insert(pairKey)
                guard let connectedDepth = depths[connectedID] else { continue }
                if abs(roleDepth - connectedDepth) > 1 {
                    skipPairCount += 1
                }
            }
        }

        if skipPairCount >= 3 {
            let zigzagAmplitude = Self.zigzagAmplitude
            var zigzagIndex = 0

            for level in 1..<levels.count {
                let rolesInLevel = levels[level]
                guard rolesInLevel.count == 1 else { continue }
                // Last level stays centered (terminal deliverable role)
                guard level < maxDepth else { continue }

                let role = rolesInLevel[0]
                let connectedRoles = connections[role.id] ?? []
                let hasSkipLevel = connectedRoles.contains { connectedID in
                    guard let connectedDepth = depths[connectedID] else { return false }
                    return abs(level - connectedDepth) > 1
                }
                guard hasSkipLevel else { continue }

                if let posIndex = positions.firstIndex(where: { $0.roleID == role.id }) {
                    let direction: CGFloat = zigzagIndex % 2 == 0 ? -1.0 : 1.0
                    positions[posIndex].x += direction * zigzagAmplitude
                    zigzagIndex += 1
                }
            }
        }

        // Pass 3: Position observers at the bottom, in rows of 2, centered.
        if !observers.isEmpty {
            let lastActiveY = positions.map(\.y).max() ?? startY
            let observerStartY = lastActiveY + verticalSpacing
            let columnsPerRow = 2

            for (i, observer) in observers.enumerated() {
                let row = i / columnsPerRow
                let col = i % columnsPerRow
                let countInRow = min(columnsPerRow, observers.count - row * columnsPerRow)
                let x = centerX + (CGFloat(col) - (CGFloat(countInRow) - 1) / 2.0) * horizontalSpacing
                let y = observerStartY + CGFloat(row) * verticalSpacing
                positions.append(TeamNodePosition(roleID: observer.id, x: x, y: y))
            }
        }

        return TeamGraphLayout(nodePositions: positions)
    }
}
