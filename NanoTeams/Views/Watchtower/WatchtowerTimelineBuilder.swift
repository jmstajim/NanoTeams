import Foundation

// MARK: - Watchtower Timeline Builder

/// Stateless builder for watchtower timeline events.
/// Extracts business logic (event collection, filtering, sorting) from WatchtowerTimeline view.
enum WatchtowerTimelineBuilder {

    /// Collect and sort timeline events from a task (newest first).
    static func collectEvents(from task: NTMSTask, roleDefinitions: [TeamRoleDefinition]) -> [TimelineEvent] {
        var events: [TimelineEvent] = []
        let isChatMode = task.isChatMode

        for run in task.runs {
            for step in run.steps {
                let roleDef = findRoleDefinition(for: step, in: roleDefinitions)
                let startedID = TimelineEvent.stableID(stepID: step.id, eventType: .started)

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
                        id: TimelineEvent.stableID(stepID: step.id, eventType: .completed),
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
                        id: TimelineEvent.stableID(stepID: step.id, eventType: .failed),
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
