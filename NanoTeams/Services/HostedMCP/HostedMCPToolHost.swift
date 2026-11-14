import Foundation

/// Execution boundary between the `nonisolated` Hosted MCP protocol dispatcher and the
/// `@MainActor` `NTMSOrchestrator` (§7.3, §8.1).
///
/// Cancellation rules (§7.3), pinned by `HostedMCPToolHostTests`:
/// - Read-only tools and `wait_for_events` run in a `@MainActor` task that the caller's
///   cancellation cancels at once, waking `wait_for_events` and releasing its waiter slot.
/// - Write tools (`create_managed_task`, `control_task`, `manage_role`, `answer_task_question`,
///   `message_task`, `schedule_task`, `set_work_folder_context`) run inside an **unstructured**
///   `@MainActor` `Task` that
///   nothing cancels, so request cancellation never propagates into `Task.isCancelled` inside
///   `startRun` / `runLaunchIsStillWanted`. Pre-commit cancellation is observed through the
///   explicit `isCancelled` closure; once a write passes its commit point, it runs to completion
///   and records its outcome in `ExternalAutovisorActivityLog` and `AutovisorEventFeed`.
nonisolated protocol HostedMCPToolExecuting: Sendable {
    func executeTool(
        name: String,
        arguments: [String: JSONValue],
        agent: AgentIdentity,
        sessionID: String?,
        isCancelled: @escaping @Sendable () -> Bool
    ) async -> ToolExecutionResult
}

/// Lightweight closure-backed tool executor for unit tests of `HostedMCPDispatcher`.
nonisolated struct ClosureHostedMCPToolExecutor: HostedMCPToolExecuting {
    private let handler: @Sendable (
        String,
        [String: JSONValue],
        AgentIdentity,
        String?,
        @escaping @Sendable () -> Bool
    ) async -> ToolExecutionResult

    init(
        handler: @escaping @Sendable (
            String,
            [String: JSONValue],
            AgentIdentity,
            String?,
            @escaping @Sendable () -> Bool
        ) async -> ToolExecutionResult
    ) {
        self.handler = handler
    }

    func executeTool(
        name: String,
        arguments: [String: JSONValue],
        agent: AgentIdentity,
        sessionID: String?,
        isCancelled: @escaping @Sendable () -> Bool
    ) async -> ToolExecutionResult {
        await handler(name, arguments, agent, sessionID, isCancelled)
    }
}

/// Thread-safe cancellation token shared between `HostedMCPDispatcher` and `HostedMCPToolHost`.
nonisolated final class HostedMCPCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [@Sendable () -> Void] = []

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        let toInvoke: [@Sendable () -> Void]
        lock.lock()
        if cancelled {
            toInvoke = []
        } else {
            cancelled = true
            toInvoke = handlers
            handlers.removeAll()
        }
        lock.unlock()
        for handler in toInvoke {
            handler()
        }
    }

    func onCancel(_ handler: @escaping @Sendable () -> Void) {
        var fireImmediately = false
        lock.lock()
        if cancelled {
            fireImmediately = true
        } else {
            handlers.append(handler)
        }
        lock.unlock()
        if fireImmediately {
            handler()
        }
    }
}

/// Production `@MainActor` bridge that executes external Autovisor tools against `NTMSOrchestrator`.
nonisolated final class HostedMCPToolHost: HostedMCPToolExecuting {

    private let orchestratorBox: OrchestratorBox
    private let now: @Sendable () -> Date

    @MainActor
    init(
        orchestrator: NTMSOrchestrator,
        now: @escaping @Sendable () -> Date = { MonotonicClock.shared.now() }
    ) {
        self.orchestratorBox = OrchestratorBox(orchestrator)
        self.now = now
    }

    func executeTool(
        name: String,
        arguments: [String: JSONValue],
        agent: AgentIdentity,
        sessionID: String?,
        isCancelled: @escaping @Sendable () -> Bool
    ) async -> ToolExecutionResult {
        let sendableArgs = arguments
        let clockNow = now
        let isReadOnly = HostedMCPCatalog.isReadOnlyTool(name)

        // Write tools run inside an unstructured MainActor Task (§7.3) where `workTask.cancel()`
        // is never called so `Task.isCancelled` stays false inside `startRun` after commit.
        let workTask = Task { @MainActor [orchestratorBox] () -> ToolExecutionResult in
            guard let orchestrator = orchestratorBox.orchestrator else {
                return makeErrorResult(
                    toolName: name,
                    args: [:],
                    code: .commandFailed,
                    message: "NanoTeams orchestrator is no longer available.",
                    next: ExternalNextCall.folderNotReady.hint()
                )
            }
            return await orchestrator.executeExternalAutovisorTool(
                name: name,
                args: Self.toNativeArguments(sendableArgs),
                agent: agent,
                sessionID: sessionID,
                now: clockNow(),
                isCancelled: { isCancelled() || (isReadOnly && Task.isCancelled) }
            )
        }
        guard isReadOnly else {
            return await workTask.value
        }
        return await withTaskCancellationHandler {
            await workTask.value
        } onCancel: {
            workTask.cancel()
        }
    }

    static func toNativeArguments(_ arguments: [String: JSONValue]) -> [String: Any] {
        var result: [String: Any] = [:]
        result.reserveCapacity(arguments.count)
        for (key, value) in arguments {
            result[key] = toNativeValue(value)
        }
        return result
    }

    private static func toNativeValue(_ value: JSONValue) -> Any {
        switch value {
        case .string(let s):
            return s
        case .int(let i):
            return i
        case .double(let d):
            return d
        case .bool(let b):
            return b
        case .array(let arr):
            return arr.map { toNativeValue($0) }
        case .object(let obj):
            var dict: [String: Any] = [:]
            dict.reserveCapacity(obj.count)
            for (k, v) in obj {
                dict[k] = toNativeValue(v)
            }
            return dict
        case .null:
            return NSNull()
        }
    }
}

private nonisolated final class OrchestratorBox: @unchecked Sendable {
    @MainActor weak var orchestrator: NTMSOrchestrator?

    @MainActor
    init(_ orchestrator: NTMSOrchestrator) {
        self.orchestrator = orchestrator
    }
}
