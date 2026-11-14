/// The errors ONE operation surfaced: those put on `NTMSOrchestrator.lastErrorMessage` by the
/// operation's own task tree while it ran — the op itself, every callee it awaits, and every
/// child task it spawns (an unstructured `Task {}` inherits the scope; `Task.detached` does not,
/// and no detached body in the app writes the banner — they hand their errors back to the
/// awaiting caller, which surfaces them in the op's own task).
///
/// Why a scope and not the process-wide `errorSurfaceCount`: a count sampled before an `await`
/// and compared after it attributes to the operation EVERY error the process surfaced while it
/// was suspended — a SwiftUI loader's switch, another task's failing write, a timer. Live, the
/// board's loader put "Task not found: 22" on the banner while `control_task delete` was
/// suspended in its residency reconcile, and the agent was told the delete failed (D-M18,
/// 2026-11-12). The counter stays: it is the process's record, and tests read it to say
/// "nothing surfaced anywhere". An operation's outcome is read from its scope.
///
/// The same scope carries banner SUPPRESSION for an external agent's call (§8.1, Ш13): its
/// refusals belong in its tool envelope, not on the person's screen. Scoped for the same reason —
/// a process-wide depth cleared the person's own banners for as long as any agent call was in
/// flight, and an agent in `wait_for_events` always has one.
///
/// A scope records only while it is OPEN. A long-lived task spawned inside an operation (an
/// engine's run loop) inherits the scope and outlives it; once the operation returns, that task's
/// errors are no longer the operation's, and no longer suppressed.
@MainActor
final class SurfacedErrorScope {
    /// The scope of the operation the current task is running inside, innermost first.
    @TaskLocal static var current: SurfacedErrorScope?

    private let parent: SurfacedErrorScope?
    private let suppressesBanners: Bool
    private var isOpen = true

    /// The latest error surfaced inside this scope while it was open, or `nil` for none.
    private(set) var surfacedError: String?

    private init(parent: SurfacedErrorScope?, suppressesBanners: Bool) {
        self.parent = parent
        self.suppressesBanners = suppressesBanners
    }

    /// Runs `operation` inside a new scope nested in the current one, and answers with its value
    /// and the scope it ran in (closed by then). An enclosing scope sees every error the nested
    /// one records: the nested operation is part of the enclosing one.
    static func run<T>(
        suppressingBanners: Bool,
        _ operation: () async -> T
    ) async -> (value: T, scope: SurfacedErrorScope) {
        let scope = SurfacedErrorScope(parent: current, suppressesBanners: suppressingBanners)
        let value = await $current.withValue(scope) { await operation() }
        scope.isOpen = false
        return (value, scope)
    }

    /// Records `message` in this scope and every open one around it.
    func record(_ message: String) {
        if isOpen { surfacedError = message }
        parent?.record(message)
    }

    /// True when this scope, or an open one around it, keeps banners off the person's screen.
    var suppressesBannersNow: Bool {
        (isOpen && suppressesBanners) || (parent?.suppressesBannersNow ?? false)
    }
}
