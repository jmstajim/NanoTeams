import Foundation

// MARK: - Team Validation Service

/// Validates team configuration for artifact uniqueness and dependency chains.
enum TeamValidationService {

    // MARK: - Validation Errors

    /// Errors found during team validation
    enum ValidationError: Equatable, Hashable {
        /// Multiple roles produce the same artifact type
        case duplicateProducer(artifact: String, roleIDs: [String])

        /// A role requires an artifact that no other role produces
        case missingProducer(artifact: String, requiredBy: String)

        /// Circular dependency detected in artifact chain
        case circularDependency(roleIDs: [String])

        /// An artifact is produced but never consumed
        case orphanArtifact(artifact: String, producedBy: String)

        var isError: Bool {
            switch self {
            case .duplicateProducer, .missingProducer, .circularDependency:
                return true
            case .orphanArtifact:
                return false  // Warning, not error
            }
        }
    }

    // MARK: - Validation Result

    struct ValidationResult {
        let errors: [ValidationError]
        let warnings: [ValidationError]

        var isValid: Bool { errors.isEmpty }
    }

    // MARK: - Validate Team Configuration

    /// Validates the complete team configuration.
    /// - Parameters:
    ///   - roleDefinitions: All role definitions in the project
    /// - Returns: Validation result with errors and warnings
    static func validate(
        roleDefinitions: [TeamRoleDefinition]
    ) -> ValidationResult {
        var errors: [ValidationError] = []
        var warnings: [ValidationError] = []

        // 1. Check artifact uniqueness
        let uniquenessIssues = validateArtifactUniqueness(roleDefinitions: roleDefinitions)
        errors.append(contentsOf: uniquenessIssues)

        // 2. Check dependency chain
        let chainIssues = validateDependencyChain(roleDefinitions: roleDefinitions)
        errors.append(contentsOf: chainIssues)

        // 3. Check for circular dependencies
        let circularIssues = validateNoCircularDependencies(roleDefinitions: roleDefinitions)
        errors.append(contentsOf: circularIssues)

        // 4. Find orphan artifacts (warning only)
        let orphanIssues = findOrphanArtifacts(roleDefinitions: roleDefinitions)
        warnings.append(contentsOf: orphanIssues)

        return ValidationResult(errors: errors, warnings: warnings)
    }

    // MARK: - Artifact Uniqueness

    /// Validates that each artifact type is produced by at most one role.
    static func validateArtifactUniqueness(roleDefinitions: [TeamRoleDefinition]) -> [ValidationError] {
        var producersByArtifact: [String: [String]] = [:]

        for roleDef in roleDefinitions {
            let deps = roleDef.dependencies

            for artifact in deps.producesArtifacts {
                producersByArtifact[artifact, default: []].append(roleDef.id)
            }
        }

        var errors: [ValidationError] = []
        for (artifact, producers) in producersByArtifact {
            if producers.count > 1 {
                errors.append(.duplicateProducer(artifact: artifact, roleIDs: producers))
            }
        }

        return errors
    }

    // MARK: - Dependency Chain

    /// Validates that every required artifact has a producer.
    static func validateDependencyChain(roleDefinitions: [TeamRoleDefinition]) -> [ValidationError] {
        // Collect all produced artifacts
        var producedArtifacts = Set<String>()
        for roleDef in roleDefinitions {
            let deps = roleDef.dependencies
            producedArtifacts.formUnion(deps.producesArtifacts)
        }

        // Check each role's requirements
        var errors: [ValidationError] = []
        for roleDef in roleDefinitions {
            let deps = roleDef.dependencies

            for required in deps.requiredArtifacts {
                if !producedArtifacts.contains(required) {
                    errors.append(.missingProducer(artifact: required, requiredBy: roleDef.id))
                }
            }
        }

        return errors
    }

    // MARK: - Circular Dependencies

    /// Validates that there are no circular dependencies in the artifact chain.
    static func validateNoCircularDependencies(roleDefinitions: [TeamRoleDefinition]) -> [ValidationError] {
        // Build dependency graph: roleID → [roleIDs it depends on]
        var dependsOn: [String: Set<String>] = [:]
        var producerOf: [String: String] = [:]

        // First pass: map artifacts to producers
        for roleDef in roleDefinitions {
            let deps = roleDef.dependencies
            for artifact in deps.producesArtifacts {
                producerOf[artifact] = roleDef.id
            }
        }

        // Second pass: build dependency edges
        for roleDef in roleDefinitions {
            // Supervisor required artifacts are review requirements, not execution edges.
            if roleDef.isSupervisor {
                dependsOn[roleDef.id] = []
                continue
            }

            let deps = roleDef.dependencies
            var dependencies = Set<String>()

            for required in deps.requiredArtifacts {
                if let producer = producerOf[required] {
                    dependencies.insert(producer)
                }
            }

            dependsOn[roleDef.id] = dependencies
        }

        // Detect cycles using DFS
        var visited = Set<String>()
        var inStack = Set<String>()
        var errors: [ValidationError] = []

        func dfs(_ nodeID: String, path: [String]) -> [String]? {
            if inStack.contains(nodeID) {
                // Found cycle - return path from cycle start
                if let cycleStart = path.firstIndex(of: nodeID) {
                    return Array(path[cycleStart...]) + [nodeID]
                }
                return path + [nodeID]
            }

            if visited.contains(nodeID) {
                return nil
            }

            visited.insert(nodeID)
            inStack.insert(nodeID)

            for dep in dependsOn[nodeID] ?? [] {
                if let cycle = dfs(dep, path: path + [nodeID]) {
                    return cycle
                }
            }

            inStack.remove(nodeID)
            return nil
        }

        for roleDef in roleDefinitions {
            if !visited.contains(roleDef.id) {
                if let cycle = dfs(roleDef.id, path: []) {
                    errors.append(.circularDependency(roleIDs: cycle))
                    break  // Report only first cycle
                }
            }
        }

        return errors
    }

    // MARK: - Orphan Artifacts

    /// Finds artifacts that are produced but never consumed.
    static func findOrphanArtifacts(roleDefinitions: [TeamRoleDefinition]) -> [ValidationError] {
        var producedBy: [String: String] = [:]
        var requiredArtifacts = Set<String>()

        for roleDef in roleDefinitions {
            let deps = roleDef.dependencies

            for artifact in deps.producesArtifacts {
                producedBy[artifact] = roleDef.id
            }

            requiredArtifacts.formUnion(deps.requiredArtifacts)
        }

        var warnings: [ValidationError] = []
        for (artifact, producer) in producedBy {
            if !requiredArtifacts.contains(artifact) {
                warnings.append(.orphanArtifact(artifact: artifact, producedBy: producer))
            }
        }

        return warnings
    }
}
