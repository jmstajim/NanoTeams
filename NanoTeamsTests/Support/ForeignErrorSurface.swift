@testable import NanoTeams

/// An error surfaced by a task the operation under test never called: one that already exists
/// before the operation starts and puts `message` on the orchestrator's banner when told to —
/// the shape of a SwiftUI `.task`, a timer, or another task's failing write (D-M18, 2026-11-13).
///
/// Built before the operation, so it inherits nothing from it; `fire()` hands the work over and
/// waits until the message is on the banner, so a test can hold it at any suspension point of
/// the operation and know it happened there.
struct ForeignErrorSurface: Sendable {
    private let trigger: AsyncStream<Void>.Continuation
    private let surfaced: AsyncStream<Void>
    private let task: Task<Void, Never>

    @MainActor
    init(_ orchestrator: NTMSOrchestrator, message: String) {
        let (requests, trigger) = AsyncStream<Void>.makeStream()
        let (surfaced, done) = AsyncStream<Void>.makeStream()
        self.trigger = trigger
        self.surfaced = surfaced
        task = Task { @MainActor [weak orchestrator] in
            for await _ in requests {
                orchestrator?.lastErrorMessage = message
                done.yield()
                return
            }
        }
    }

    /// Asks the foreign task to surface its message, and returns once it has.
    func fire() async {
        trigger.yield()
        for await _ in surfaced { return }
    }

    func cancel() {
        task.cancel()
    }
}
