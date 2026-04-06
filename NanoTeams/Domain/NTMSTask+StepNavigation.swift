import Foundation

/// Represents the location of a step within a task's run hierarchy.
struct StepLocation {
    let runIndex: Int
    let stepIndex: Int
}

extension NTMSTask {

    /// Locates a step by ID in the latest run.
    /// - Parameter stepID: The step ID to find.
    /// - Returns: The step location, or nil if not found in the latest run.
    func locateStepInLatestRun(stepID: String) -> StepLocation? {
        guard let runIndex = runs.indices.last else { return nil }
        guard let stepIndex = runs[runIndex].steps.firstIndex(where: { $0.id == stepID }) else {
            return nil
        }
        return StepLocation(runIndex: runIndex, stepIndex: stepIndex)
    }

    /// Locates a step by ID in a specific run.
    /// - Parameters:
    ///   - stepID: The step ID to find.
    ///   - runID: The run ID to search in.
    /// - Returns: The step location, or nil if not found.
    func locateStep(stepID: String, inRun runID: Int) -> StepLocation? {
        guard let runIndex = runs.firstIndex(where: { $0.id == runID }) else { return nil }
        guard let stepIndex = runs[runIndex].steps.firstIndex(where: { $0.id == stepID }) else {
            return nil
        }
        return StepLocation(runIndex: runIndex, stepIndex: stepIndex)
    }

    /// Gets the step at a given location.
    /// - Parameter location: The step location.
    /// - Returns: The step, or nil if the location is invalid.
    func step(at location: StepLocation) -> StepExecution? {
        guard runs.indices.contains(location.runIndex),
            runs[location.runIndex].steps.indices.contains(location.stepIndex)
        else {
            return nil
        }
        return runs[location.runIndex].steps[location.stepIndex]
    }

    /// Gets the latest run, if any.
    var latestRun: Run? {
        runs.last
    }

    /// Gets the latest run index, if any.
    var latestRunIndex: Int? {
        runs.indices.last
    }

    /// Mutates a step at the given location.
    /// - Parameters:
    ///   - location: The step location.
    ///   - mutation: The mutation to apply.
    /// - Returns: A new task with the mutation applied, or self if location is invalid.
    func withStep(at location: StepLocation, mutation: (inout StepExecution) -> Void) -> NTMSTask {
        var copy = self
        guard copy.runs.indices.contains(location.runIndex),
            copy.runs[location.runIndex].steps.indices.contains(location.stepIndex)
        else {
            return self
        }
        mutation(&copy.runs[location.runIndex].steps[location.stepIndex])
        copy.updatedAt = MonotonicClock.shared.now()
        return copy
    }

    /// Mutates a step by ID in the latest run.
    /// - Parameters:
    ///   - stepID: The step ID to mutate.
    ///   - mutation: The mutation to apply.
    /// - Returns: A new task with the mutation applied, or self if step not found.
    func withStep(stepID: String, mutation: (inout StepExecution) -> Void) -> NTMSTask {
        guard let location = locateStepInLatestRun(stepID: stepID) else {
            return self
        }
        return withStep(at: location, mutation: mutation)
    }

    /// Mutates the latest run.
    /// - Parameter mutation: The mutation to apply.
    /// - Returns: A new task with the mutation applied, or self if no runs exist.
    func withLatestRun(mutation: (inout Run) -> Void) -> NTMSTask {
        guard let runIndex = runs.indices.last else { return self }
        var copy = self
        mutation(&copy.runs[runIndex])
        copy.updatedAt = MonotonicClock.shared.now()
        return copy
    }
}

extension Run {

    /// Locates a step by ID in this run.
    /// - Parameter stepID: The step ID to find.
    /// - Returns: The step index, or nil if not found.
    func locateStep(stepID: String) -> Int? {
        steps.firstIndex(where: { $0.id == stepID })
    }

    /// Gets a step by ID.
    /// - Parameter stepID: The step ID to find.
    /// - Returns: The step, or nil if not found.
    func step(id stepID: String) -> StepExecution? {
        steps.first(where: { $0.id == stepID })
    }

    /// Mutates a step by ID.
    /// - Parameters:
    ///   - stepID: The step ID to mutate.
    ///   - mutation: The mutation to apply.
    /// - Returns: A new run with the mutation applied, or self if step not found.
    func withStep(stepID: String, mutation: (inout StepExecution) -> Void) -> Run {
        guard let stepIndex = locateStep(stepID: stepID) else { return self }
        var copy = self
        mutation(&copy.steps[stepIndex])
        copy.updatedAt = MonotonicClock.shared.now()
        return copy
    }
}
