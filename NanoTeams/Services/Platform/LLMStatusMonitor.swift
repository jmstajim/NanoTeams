import Foundation

/// Polls the configured LLM server on a background interval and exposes reachability
/// as observable state. Injected into the environment from the app entry point so
/// polling lifecycle is independent of view rendering.
@Observable @MainActor
final class LLMStatusMonitor {
    private(set) var isReachable: Bool = false
    private(set) var lastCheckedAt: Date?

    @ObservationIgnored private var pollTask: Task<Void, Never>?

    /// Starts a background polling loop. `baseURLProvider` is a closure so the monitor
    /// picks up live configuration changes without restart. Runs on the main actor so
    /// the provider can read `@MainActor`-isolated state directly.
    func startMonitoring(
        baseURLProvider: @escaping @MainActor () -> String,
        interval: TimeInterval = 120
    ) {
        stopMonitoring()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let baseURL = baseURLProvider()
                let reachable = await LLMConnectionChecker.check(baseURL: baseURL, timeout: 2.0)
                // Guard after the await: `stopMonitoring` may have fired while the
                // probe was in flight — honor cancellation before publishing stale state.
                guard !Task.isCancelled, let self else { return }
                self.isReachable = reachable
                self.lastCheckedAt = Date()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stopMonitoring() {
        pollTask?.cancel()
        pollTask = nil
    }

    nonisolated deinit {
        pollTask?.cancel()
    }
}
