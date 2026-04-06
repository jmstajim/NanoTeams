import CoreGraphics
import Foundation

// MARK: - Team Graph Transform

/// Transform for panning and zooming the team graph
struct TeamGraphTransform: Codable, Hashable {
    /// Horizontal offset (pan)
    var offsetX: CGFloat

    /// Vertical offset (pan)
    var offsetY: CGFloat

    /// Scale factor (zoom)
    var scale: CGFloat

    static let identity = TeamGraphTransform(offsetX: 0, offsetY: 0, scale: 1.0)

    init(offsetX: CGFloat = 0, offsetY: CGFloat = 0, scale: CGFloat = 1.0) {
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.scale = scale
    }

    enum CodingKeys: String, CodingKey {
        case offsetX
        case offsetY
        case scale
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.offsetX = try c.decodeIfPresent(CGFloat.self, forKey: .offsetX) ?? 0
        self.offsetY = try c.decodeIfPresent(CGFloat.self, forKey: .offsetY) ?? 0
        self.scale = try c.decodeIfPresent(CGFloat.self, forKey: .scale) ?? 1.0
    }

    /// Reset to identity transform
    mutating func reset() {
        offsetX = 0
        offsetY = 0
        scale = 1.0
    }

    /// Clamp scale to reasonable bounds
    mutating func clampScale() {
        scale = max(0.5, min(2.0, scale))
    }
}

// MARK: - Team Graph Layout

struct TeamGraphLayout: Codable, Hashable {
    var nodePositions: [TeamNodePosition]

    /// Transform for panning/zooming the graph view
    var transform: TeamGraphTransform

    /// Roles intentionally hidden from the graph (still in team.roles)
    var hiddenRoleIDs: Set<String>

    static let `default` = TeamGraphLayout(
        nodePositions: [
            TeamNodePosition(roleID: "supervisor", x: 300, y: 40),
            TeamNodePosition(roleID: "productManager", x: 300, y: 160),
            TeamNodePosition(roleID: "uxResearcher", x: 150, y: 280),
            TeamNodePosition(roleID: "uxDesigner", x: 450, y: 280),
            TeamNodePosition(roleID: "techLead", x: 300, y: 400),
            TeamNodePosition(roleID: "softwareEngineer", x: 300, y: 520),
            TeamNodePosition(roleID: "codeReviewer", x: 180, y: 640),
            TeamNodePosition(roleID: "sre", x: 420, y: 640),
            TeamNodePosition(roleID: "tpm", x: 300, y: 760),
        ]
    )

    init(
        nodePositions: [TeamNodePosition] = [],
        transform: TeamGraphTransform = .identity,
        hiddenRoleIDs: Set<String> = []
    ) {
        self.nodePositions = nodePositions
        self.transform = transform
        self.hiddenRoleIDs = hiddenRoleIDs
    }

    enum CodingKeys: String, CodingKey {
        case nodePositions
        case transform
        case hiddenRoleIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.nodePositions =
            try c.decodeIfPresent([TeamNodePosition].self, forKey: .nodePositions)
            ?? TeamGraphLayout.default.nodePositions
        self.transform =
            try c.decodeIfPresent(TeamGraphTransform.self, forKey: .transform) ?? .identity
        self.hiddenRoleIDs =
            try c.decodeIfPresent(Set<String>.self, forKey: .hiddenRoleIDs) ?? []
    }

    func position(for roleID: String) -> CGPoint? {
        guard let node = nodePositions.first(where: { $0.roleID == roleID }) else {
            return nil
        }
        return CGPoint(x: node.x, y: node.y)
    }

    mutating func setPosition(for roleID: String, x: CGFloat, y: CGFloat) {
        if let index = nodePositions.firstIndex(where: { $0.roleID == roleID }) {
            nodePositions[index].x = x
            nodePositions[index].y = y
        } else {
            nodePositions.append(TeamNodePosition(roleID: roleID, x: x, y: y))
        }
    }

    /// Hide a role from the graph (remove position, add to hidden set)
    mutating func hideRole(_ roleID: String) {
        hiddenRoleIDs.insert(roleID)
        nodePositions.removeAll { $0.roleID == roleID }
    }

    /// Show a previously hidden role on the graph
    mutating func showRole(_ roleID: String, at position: CGPoint) {
        hiddenRoleIDs.remove(roleID)
        if !nodePositions.contains(where: { $0.roleID == roleID }) {
            nodePositions.append(TeamNodePosition(roleID: roleID, x: position.x, y: position.y))
        }
    }

    /// Clean up hidden role IDs for roles that no longer exist in the team
    mutating func pruneHiddenRoles(existingRoleIDs: Set<String>) {
        hiddenRoleIDs = hiddenRoleIDs.intersection(existingRoleIDs)
    }

    /// Reset transform to identity
    mutating func resetTransform() {
        transform = .identity
    }

    /// Compute a good position for a new node: below the lowest existing node, centred horizontally.
    func nextNodePosition() -> CGPoint {
        guard !nodePositions.isEmpty else {
            return CGPoint(x: 300, y: 100)
        }
        let maxY = nodePositions.map { $0.y }.max() ?? 400
        let avgX = nodePositions.map { $0.x }.reduce(0, +) / CGFloat(nodePositions.count)
        return CGPoint(x: avgX, y: maxY + 120)
    }

    /// Compute a graph layout from artifact dependencies using topological depth.
    /// Algorithm implemented in `TeamGraphLayoutCalculator` (SRP).
    static func autoLayout(for roles: [TeamRoleDefinition]) -> TeamGraphLayout {
        TeamGraphLayoutCalculator.autoLayout(for: roles)
    }
}

// MARK: - Team Node Position

struct TeamNodePosition: Codable, Hashable, Identifiable {
    var id: String { roleID }
    var roleID: String
    var x: CGFloat
    var y: CGFloat

    init(roleID: String, x: CGFloat, y: CGFloat) {
        self.roleID = roleID
        self.x = x
        self.y = y
    }
}
