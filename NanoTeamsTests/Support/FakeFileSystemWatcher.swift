import Foundation

@testable import NanoTeams

/// A `FileSystemWatching` double that opens no FSEvents stream.
///
/// Before the `makeWatcher` seam existed, every `SearchIndexCoordinator` test opened a real
/// `FSEventStream` on its temp directory — roughly twenty of them, none asserting on a single
/// event, each paying a kernel subscription and the watcher's own documented ~1-second warmup.
/// The coordinator's contract with the watcher is two calls wide, so a double is the whole story.
///
/// `startResult` is what makes the failure arm reachable at all: the real watcher only returns
/// `false` for an empty path list (which the coordinator never passes) or a kernel-level
/// `FSEventStreamCreate` failure (which cannot be induced from a test).
final class FakeFileSystemWatcher: FileSystemWatching, @unchecked Sendable {
    private let lock = NSLock()
    private let startResult: Bool
    private var _startCount = 0
    private var _stopCount = 0
    private let onChange: FileSystemWatcher.Handler?

    /// Arguments the coordinator handed the factory. Kept so a test can assert the coordinator
    /// still excludes `.nanoteams/internal/` — the exclusion that stops every tool-call log write
    /// during a run from triggering a signature probe.
    let paths: [URL]
    let excludedPrefixes: [URL]
    let debounce: TimeInterval

    var startCount: Int { lock.withLock { _startCount } }
    var stopCount: Int { lock.withLock { _stopCount } }

    init(
        startResult: Bool = true,
        paths: [URL] = [],
        excludedPrefixes: [URL] = [],
        debounce: TimeInterval = 0,
        onChange: FileSystemWatcher.Handler? = nil
    ) {
        self.startResult = startResult
        self.paths = paths
        self.excludedPrefixes = excludedPrefixes
        self.debounce = debounce
        self.onChange = onChange
    }

    func start() -> Bool {
        lock.withLock { _startCount += 1 }
        return startResult
    }

    func stop() {
        lock.withLock { _stopCount += 1 }
    }

    /// Delivers the change callback the coordinator installed, without FSEvents. Lets a test
    /// drive the watcher-triggered refresh path deterministically instead of writing a file and
    /// hoping the kernel notices within the debounce window.
    func fireChange() {
        onChange?()
    }
}

enum FakeWatcherFactory {
    /// A factory whose watchers start successfully and do nothing — the right default for any
    /// test that is not about the watcher.
    static let inert: FileSystemWatcherFactory = { paths, excluded, debounce, onChange in
        FakeFileSystemWatcher(
            startResult: true,
            paths: paths,
            excludedPrefixes: excluded,
            debounce: debounce,
            onChange: onChange
        )
    }

    /// A factory whose watchers refuse to start, i.e. the kernel-level `FSEventStreamCreate`
    /// failure the coordinator's `lastError` arm exists for.
    static let failing: FileSystemWatcherFactory = { paths, excluded, debounce, onChange in
        FakeFileSystemWatcher(
            startResult: false,
            paths: paths,
            excludedPrefixes: excluded,
            debounce: debounce,
            onChange: onChange
        )
    }

    /// A factory that records every watcher it builds, so a test can reach the double the
    /// coordinator installed. `NSLock`-guarded because the factory type is `@Sendable`.
    static func recording(startResult: Bool = true) -> (FileSystemWatcherFactory, () -> [FakeFileSystemWatcher]) {
        let box = WatcherBox()
        let factory: FileSystemWatcherFactory = { paths, excluded, debounce, onChange in
            let w = FakeFileSystemWatcher(
                startResult: startResult,
                paths: paths,
                excludedPrefixes: excluded,
                debounce: debounce,
                onChange: onChange
            )
            box.append(w)
            return w
        }
        return (factory, { box.all() })
    }

    private final class WatcherBox: @unchecked Sendable {
        private let lock = NSLock()
        private var watchers: [FakeFileSystemWatcher] = []
        func append(_ w: FakeFileSystemWatcher) { lock.withLock { watchers.append(w) } }
        func all() -> [FakeFileSystemWatcher] { lock.withLock { watchers } }
    }
}
