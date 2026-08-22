import Foundation

// MARK: - Watchtower Timeline Builder

/// Stateless builder for watchtower timeline events.
/// Extracts business logic (event collection, filtering, sorting) from WatchtowerTimeline view.
nonisolated enum WatchtowerTimelineBuilder {

    /// Collect and sort timeline events from a task (newest first).
    static func collectEvents(from task: NTMSTask, roleDefinitions: [TeamRoleDefinition]) -> [TimelineEvent] {
        var events: [TimelineEvent] = []
        let isChatMode = task.isChatMode

        for run in task.runs {
            for step in run.steps {
                let roleDef = findRoleDefinition(for: step, in: roleDefinitions)
                let startedID = TimelineEvent.stableID(taskID: task.id, runID: run.id, stepID: step.id, eventType: .started)

                events.append(TimelineEvent(
                    id: startedID,
                    taskID: task.id,
                    taskTitle: task.title,
                    role: step.role,
                    roleDefinition: roleDef,
                    stepTitle: step.title,
                    eventType: .started,
                    isChatMode: isChatMode,
                    timestamp: step.createdAt
                ))

                if step.status == .done {
                    events.append(TimelineEvent(
                        id: TimelineEvent.stableID(taskID: task.id, runID: run.id, stepID: step.id, eventType: .completed),
                        taskID: task.id,
                        taskTitle: task.title,
                        role: step.role,
                        roleDefinition: roleDef,
                        stepTitle: step.title,
                        eventType: .completed,
                        isChatMode: isChatMode,
                        timestamp: step.completedAt ?? step.updatedAt
                    ))
                } else if step.status == .failed {
                    events.append(TimelineEvent(
                        id: TimelineEvent.stableID(taskID: task.id, runID: run.id, stepID: step.id, eventType: .failed),
                        taskID: task.id,
                        taskTitle: task.title,
                        role: step.role,
                        roleDefinition: roleDef,
                        stepTitle: step.title,
                        eventType: .failed,
                        isChatMode: isChatMode,
                        timestamp: step.completedAt ?? step.updatedAt
                    ))
                }
            }
        }

        return events
    }

    private static func findRoleDefinition(for step: StepExecution, in roles: [TeamRoleDefinition]) -> TeamRoleDefinition? {
        let id = step.effectiveRoleID
        return roles.first(where: { $0.id == id })
            ?? roles.first(where: { $0.systemRoleID == id || $0.name == id })
    }

    /// Cheap change-detector over EVERYTHING `buildTimeline` reads, so the view
    /// can memoize the built timeline instead of rebuilding it per body pass.
    ///
    /// `WatchtowerView` is the DEFAULT detail pane, and `filteredEvents` was a
    /// plain computed property referenced five times from one body pass — each
    /// reference walking every run and every step, allocating a `TimelineEvent`
    /// (with an interpolated id string) per step, sorting, and then filtering
    /// twice more. `store.activeTask` is rewritten on every `mutateTask`, so that
    /// was five full history rebuilds per LLM message.
    ///
    /// Folds every field `collectEvents` and the two filters actually read. A
    /// counts-only key would freeze the timeline on a pure status flip — the trap
    /// `TeamActivityFeedView+Logic.computeRunDataVersion` documents — so `status`,
    /// `completedAt` and `updatedAt` are all in here. Same accepted trade-off as
    /// that sibling: a hash collision costs one missed refresh, not wrong data.
    static func inputsVersion(
        task: NTMSTask?,
        teamID: NTMSID?,
        teamUpdatedAt: Date?,
        taskFilter: Int?,
        clearedUpTo: Date?
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(taskFilter)
        hasher.combine(clearedUpTo)
        hasher.combine(teamID)
        hasher.combine(teamUpdatedAt)
        guard let task else { return hasher.finalize() }
        hasher.combine(task.id)
        hasher.combine(task.title)
        hasher.combine(task.isChatMode)
        hasher.combine(task.runs.count)
        for run in task.runs {
            hasher.combine(run.id)
            hasher.combine(run.steps.count)
            for step in run.steps {
                hasher.combine(step.id)
                hasher.combine(step.effectiveRoleID)
                hasher.combine(step.role)
                hasher.combine(step.title)
                hasher.combine(step.status)
                hasher.combine(step.createdAt)
                hasher.combine(step.completedAt)
                hasher.combine(step.updatedAt)
            }
        }
        return hasher.finalize()
    }

    /// Build a sorted, filtered timeline from a task.
    /// - Parameters:
    ///   - task: The active task (nil = no events).
    ///   - taskFilter: Optional task ID to filter by.
    ///   - clearedUpTo: Optional cutoff date — events at or before this date are hidden.
    /// - Returns: Timeline events sorted newest-first.
    static func buildTimeline(
        task: NTMSTask?,
        roleDefinitions: [TeamRoleDefinition],
        taskFilter: Int?,
        clearedUpTo: Date?
    ) -> [TimelineEvent] {
        guard let task else { return [] }

        var events = collectEvents(from: task, roleDefinitions: roleDefinitions)

        // Sort newest first (MonotonicClock guarantees correct ordering)
        events.sort { $0.timestamp > $1.timestamp }

        // Apply task filter
        if let taskID = taskFilter {
            events = events.filter { $0.taskID == taskID }
        }

        // Apply cleared timestamp filter
        if let cutoff = clearedUpTo {
            events = events.filter { $0.timestamp > cutoff }
        }

        return events
    }
}
