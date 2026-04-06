import Foundation

struct TeamHierarchy: Codable, Hashable {
    /// Dictionary: role ID → supervisor role ID (nil = reports to Supervisor/user)
    var reportsTo: [String: String]

    init(reportsTo: [String: String] = [:]) {
        self.reportsTo = reportsTo
    }

    /// Get supervisor for a role ID
    func supervisorID(for roleID: String) -> String? {
        reportsTo[roleID]
    }

    /// Get subordinate IDs for a role ID
    func subordinateIDs(of roleID: String) -> [String] {
        reportsTo.compactMap { (subordinateID, supervisorID) in
            supervisorID == roleID ? subordinateID : nil
        }
    }

    /// Check if role1 reports to role2 (directly or indirectly)
    func doesReport(_ roleID: String, to supervisorRoleID: String) -> Bool {
        var current = roleID
        var visited = Set<String>()
        while let sup = reportsTo[current] {
            if sup == supervisorRoleID { return true }
            if visited.contains(sup) { return false }  // Cycle detection
            visited.insert(sup)
            current = sup
        }
        return false
    }
}
