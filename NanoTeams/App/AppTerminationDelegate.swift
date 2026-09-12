import AppKit

/// The app's only `NSApplicationDelegate`, and it exists for one reason: ⌘Q must be allowed to
/// finish an `async` shutdown step.
///
/// The search index lives in memory while a folder is open and is written at closing time — the
/// walk is incremental precisely so an ordinary edit costs milliseconds instead of rewriting a
/// megabyte. Closing a folder goes through `tearDownSearchIndexCoordinator`, but quitting with
/// one still open had no path at all: there was no `NSApplicationDelegateAdaptor` anywhere in
/// the app, so the session's vocabulary went with the process and the next launch re-tokenized
/// everything edited since the last full rebuild.
///
/// `willTerminateNotification` — the hook `GlobalHotkeyManager` uses — cannot do this job: it is
/// synchronous, and the work is an `await` into an actor. `applicationShouldTerminate` can:
/// `.terminateLater` suspends the quit, and `reply(toApplicationShouldTerminate:)` resumes it.
///
/// The timeout is not belt-and-braces. A hung volume (an unmounted network share, a spinning
/// external disk) would otherwise make the app unquittable, with no window to close and no
/// error — and the thing being saved is a regenerable cache. It expires and quits.
///
/// **It must never implement `applicationShouldTerminateAfterLastWindowClosed`.** Quick Capture
/// runs off a process-level Carbon hotkey and is expected to keep working after ⌘W closes the
/// main window (`NTMSOrchestrator.pendingNewTeamSheet` reasons about exactly that). Before this
/// type existed the app had no delegate at all, so AppKit's `false` default held by accident;
/// now it holds because this file declines to say otherwise.
@MainActor
final class AppTerminationDelegate: NSObject, NSApplicationDelegate {

    /// How long the quit waits for the save. Generous next to a local write of ~1 MB, short
    /// next to a user deciding the app is wedged.
    static let saveTimeout: Duration = .seconds(5)

    /// The shutdown step, installed by `NanoTeamsApp` once the orchestrator exists.
    ///
    /// `nil` until then — and a quit in that window is not an error: nothing has been opened,
    /// so there is nothing to save.
    var onTerminate: (@MainActor () async -> Void)?

    /// How the delegate answers AppKit. Injected so a test can observe the reply without an
    /// `NSApp` — under XCTest the shared application is the test runner's, and telling it a
    /// termination may proceed is not something a unit test should do.
    var reply: @MainActor (Bool) -> Void = { proceed in
        NSApp.reply(toApplicationShouldTerminate: proceed)
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let onTerminate else { return .terminateNow }
        Task { @MainActor in
            await Self.run(onTerminate, within: Self.saveTimeout)
            // Always `true`: the save is best-effort, and a failed or timed-out one is not a
            // reason to refuse the user's quit. `SearchIndexService` reports the failure
            // through the coordinator, and the index rebuilds on the next launch regardless.
            self.reply(true)
        }
        return .terminateLater
    }

    /// Runs `work`, giving up after `timeout`.
    ///
    /// A race between two unstructured tasks rather than a task group, because a group cannot
    /// express it: the group only returns once every child has finished, and cancelling the
    /// loser does not help — the work is a `Data.write(options: .atomic)` into an actor, which
    /// observes no cancellation. On timeout the save is therefore ABANDONED, not stopped; it
    /// finishes, or doesn't, into a process that is already exiting.
    static func run(
        _ work: @escaping @MainActor () async -> Void, within timeout: Duration
    ) async {
        let gate = Gate()
        Task { @MainActor in
            await work()
            gate.open()
        }
        Task { @MainActor in
            try? await Task.sleep(for: timeout)
            gate.open()
        }
        await gate.wait()
    }

    /// Opens once, for whichever racer gets there first.
    ///
    /// Both racers run on the main actor and `wait()` has no suspension point before it stores
    /// the continuation, so "once" needs no lock and there is no window in which `open()` can
    /// land between the `isOpen` check and the store.
    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func open() {
            guard !isOpen else { return }
            isOpen = true
            continuation?.resume()
            continuation = nil
        }

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation = $0 }
        }
    }
}
