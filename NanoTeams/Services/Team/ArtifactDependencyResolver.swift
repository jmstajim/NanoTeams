import Foundation

// MARK: - Artifact Dependency Resolver

/// Resolves which roles are ready to execute based on artifact dependencies.
/// Create an instance for repeated queries against the same role set (cached graph).
/// Use static methods for one-off queries (backward-compatible API).
struct ArtifactDependencyResolver {

    // MARK: - Role Readiness

    struct RoleReadiness: Equatable {
        let roleID: String
        let isReady: Bool
        let missingArtifacts: [String]
        let satisfiedArtifacts: [String]

        var blockingReason: String? {
            guard !isReady else { return nil }
            if missingArtifacts.isEmpty {
                return nil
            }
            return "Waiting for: \(missingArtifacts.joined(separator: ", "))"
        }
    }

    // MARK: - Cached State

    private let roles: [TeamRoleDefinition]
    /// Artifact name → producing role ID.
    private let producerOf: [String: String]
    /// Role ID → set of role IDs it depends on (via artifacts).
    private let roleDependsOn: [String: Set<String>]
    /// Artifact name → set of role IDs that require it.
    private let consumersOf: [String: Set<String>]

    // MARK: - Init (builds cache)

    init(roles: [TeamRoleDefinition]) {
        self.roles = roles

        var producerOf: [String: String] = [:]
        for role in roles {
            for artifact in role.dependencies.producesArtifacts {
                producerOf[artifact] = role.id
            }
        }

        var roleDependsOn: [String: Set<String>] = [:]
        var consumersOf: [String: Set<String>] = [:]
        for role in roles {
            var deps = Set<String>()
            for required in role.dependencies.requiredArtifacts {
                if let producer = producerOf[required] {
                    deps.insert(producer)
                }
                consumersOf[required, default: []].insert(role.id)
            }
            roleDependsOn[role.id] = deps
        }

        self.producerOf = producerOf
        self.roleDependsOn = roleDependsOn
        self.consumersOf = consumersOf
    }

    // MARK: - Instance Methods (use cached graph)

    /// Computes a valid execution order using cached dependency graph.
    /// Returns nil if there's a circular dependency.
    func getExecutionOrder() -> [String]? {
        var inDegree: [String: Int] = [:]
        for role in roles {
            inDegree[role.id] = roleDependsOn[role.id]?.count ?? 0
        }

        var queue: [String] = []
        for (roleID, degree) in inDegree where degree == 0 {
            queue.append(roleID)
        }

        var order: [String] = []
        while !queue.isEmpty {
            let current = queue.removeFirst()
            order.append(current)

            for role in roles {
                if roleDependsOn[role.id]?.contains(current) == true {
                    inDegree[role.id]? -= 1
                    if inDegree[role.id] == 0 {
                        queue.append(role.id)
                    }
                }
            }
        }

        return order.count == roles.count ? order : nil
    }

    /// Gets all roles that depend (directly or indirectly) on a given role, using cached graph.
    /// Excludes Supervisor from traversal to prevent circular cascades.
    func getDownstreamRoles(of roleID: String) -> Set<String> {
        var downstream = Set<String>()
        var visited = Set([roleID])
        var toProcess = [roleID]

        for role in roles where role.isSupervisor {
            visited.insert(role.id)
        }

        while let current = toProcess.popLast() {
            guard let role = roles.first(where: { $0.id == current }) else { continue }

            for artifact in role.dependencies.producesArtifacts {
                guard let consumers = consumersOf[artifact] else { continue }
                for consumer in consumers {
                    guard !visited.contains(consumer) else { continue }
                    downstream.insert(consumer)
                    visited.insert(consumer)
                    toProcess.append(consumer)
                }
            }
        }

        return downstream
    }

    // MARK: - Static Methods (backward-compatible API)

    /// Finds all roles that have their dependencies satisfied.
    static func findReadyRoles(
        roles: [TeamRoleDefinition],
        producedArtifacts: Set<String>,
        excludeRoleIDs: Set<String> = []
    ) -> [String] {
        var readyRoles: [String] = []

        for role in roles {
            guard !excludeRoleIDs.contains(role.id) else { continue }
            let allSatisfied = role.dependencies.requiredArtifacts.allSatisfy { producedArtifacts.contains($0) }
            if allSatisfied {
                readyRoles.append(role.id)
            }
        }

        return readyRoles
    }

    /// Gets detailed readiness information for a specific role.
    static func getRoleReadiness(
        roleID: String,
        roles: [TeamRoleDefinition],
        producedArtifacts: Set<String>
    ) -> RoleReadiness {
        guard let role = roles.first(where: { $0.id == roleID }) else {
            return RoleReadiness(
                roleID: roleID,
                isReady: false,
                missingArtifacts: [],
                satisfiedArtifacts: []
            )
        }

        var missing: [String] = []
        var satisfied: [String] = []

        for artifact in role.dependencies.requiredArtifacts {
            if producedArtifacts.contains(artifact) {
                satisfied.append(artifact)
            } else {
                missing.append(artifact)
            }
        }

        return RoleReadiness(
            roleID: roleID,
            isReady: missing.isEmpty,
            missingArtifacts: missing,
            satisfiedArtifacts: satisfied
        )
    }

    /// Returns the artifacts that are blocking a role from starting.
    static func getBlockingArtifacts(
        for roleID: String,
        roles: [TeamRoleDefinition],
        producedArtifacts: Set<String>
    ) -> [String] {
        getRoleReadiness(
            roleID: roleID,
            roles: roles,
            producedArtifacts: producedArtifacts
        ).missingArtifacts
    }

    /// Gets readiness information for all roles.
    static func getAllReadinessStates(
        roles: [TeamRoleDefinition],
        producedArtifacts: Set<String>
    ) -> [String: RoleReadiness] {
        var result: [String: RoleReadiness] = [:]

        for role in roles {
            result[role.id] = getRoleReadiness(
                roleID: role.id,
                roles: roles,
                producedArtifacts: producedArtifacts
            )
        }

        return result
    }

    /// Computes a valid execution order for roles based on dependencies.
    /// Returns nil if there's a circular dependency.
    static func getExecutionOrder(roles: [TeamRoleDefinition]) -> [String]? {
        ArtifactDependencyResolver(roles: roles).getExecutionOrder()
    }

    /// Gets all roles that depend (directly or indirectly) on a given role.
    static func getDownstreamRoles(
        of roleID: String,
        roles: [TeamRoleDefinition]
    ) -> Set<String> {
        ArtifactDependencyResolver(roles: roles).getDownstreamRoles(of: roleID)
    }
}
