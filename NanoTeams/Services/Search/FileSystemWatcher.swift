import Foundation
#if canImport(CoreServices)
import CoreServices
#endif

/// The two things `SearchIndexCoordinator` needs from a file-system watcher.
///
/// Narrow on purpose (ISP): the coordinator never reads a path back, never asks
/// whether the stream is running, and never re-arms one — it starts a watcher at
/// `start()` and drops it at `stop()`.
protocol FileSystemWatching: AnyObject, Sendable {
    /// `false` when the stream could not be created. The coordinator turns that into a
    /// user-visible `lastError`, because a dead watcher means the index silently stops
    /// auto-refreshing and only the Rebuild button will move it again.
    func start() -> Bool
    func stop()
}

/// Builds the watcher `SearchIndexCoordinator.start()` installs.
///
/// **Deliberately has no default at any call site**, which is the one design decision here
/// worth arguing. Both defaults are wrong in the way CLAUDE.md #49 describes, just in
/// opposite directions:
///
/// - Defaulting OUTWARD (to the real watcher) is what this seam replaced: ~20 coordinator
///   tests each opened a real `FSEventStream` on a temp directory, paying a kernel resource
///   and a 1-second subscription warmup for a stream not one of them asserts on. Every one of
///   those call sites got there by omitting an argument, never by choosing.
/// - Defaulting INWARD (to an inert watcher) is worse: one forgotten argument in production
///   and the search index stops auto-refreshing, with nothing logged and nothing failing —
///   the app would just quietly serve stale results.
///
/// With no default the compiler asks the question, and there are only five places to answer it.
typealias FileSystemWatcherFactory = @Sendable (
    _ paths: [URL],
    _ excludedPrefixes: [URL],
    _ debounce: TimeInterval,
    _ onChange: @escaping FileSystemWatcher.Handler
) -> any FileSystemWatching

/// Thin wrapper over `FSEventStream` for watching a set of paths.
/// Coalesces bursts via a debounce layer on top of the FSEvents latency.
///
/// Used by `SearchIndexCoordinator` to trigger signature checks when the work
/// folder changes. The callback is fired no more than once per `debounce`
/// window even if FSEvents reports a burst of changes.
nonisolated final class FileSystemWatcher: @unchecked Sendable {
    typealias Handler = @Sendable () -> Void

    private let paths: [URL]
    private let excludedPrefixes: [String]
    private let debounce: TimeInterval
    private let onChange: Handler

    private let queue = DispatchQueue(label: "com.nanoteams.search.fswatch")
    private var stream: FSEventStreamRef?
    private var pendingWorkItem: DispatchWorkItem?
    private var running = false

    /// - Parameter excludedPrefixes: absolute path prefixes (standardized). When
    ///   every path in an FSEvents batch falls under one of these prefixes,
    ///   the batch is dropped before the debounce timer is (re-)armed. Used
    ///   to suppress the self-write storm from `.nanoteams/internal/runs/...`
    ///   during active runs — tool-call and network logs there would
    ///   otherwise trigger a signature probe every `debounce` seconds.
    init(
        paths: [URL],
        excludedPrefixes: [URL] = [],
        debounce: TimeInterval = 2.0,
        onChange: @escaping Handler
    ) {
        self.paths = paths
        self.excludedPrefixes = excludedPrefixes.map { Self.canonicalPath(for: $0) }
        self.debounce = debounce
        self.onChange = onChange
    }

    /// Returns the canonical path used by FSEvents for `url`. FSEvents reports
    /// `/private/var/...` (etc.) even when the caller passed `/var/...`
    /// because `/var`, `/tmp`, and `/etc` are all symlinks to `/private/...`
    /// on macOS. `URL.resolvingSymlinksInPath()` does not always traverse
    /// those root-level symlinks, so we rewrite them explicitly — otherwise
    /// every tempDir-relative exclusion in tests (and any real path whose
    /// ancestors include `/var`, `/tmp`, or `/etc`) would silently miss the
    /// `hasPrefix` check.
    private static func canonicalPath(for url: URL) -> String {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        for (short, canonical) in [
            ("/var/", "/private/var/"),
            ("/tmp/", "/private/tmp/"),
            ("/etc/", "/private/etc/"),
        ] where resolved.hasPrefix(short) {
            return canonical + String(resolved.dropFirst(short.count))
        }
        return resolved
    }

    deinit {
        // nonisolated deinit — perform minimal teardown without capturing self.
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    // MARK: - Lifecycle

    /// True once `start()` has successfully subscribed to FSEvents. Stays
    /// true until `stop()`. Coordinators poll this to surface watcher death
    /// (empty paths, FSEventStreamCreate failure, teardown) instead of
    /// silently printing on console.
    var isRunning: Bool { queue.sync { running } }

    /// Subscribes the watcher. Returns `true` on successful subscription,
    /// `false` when paths are empty or `FSEventStreamCreate` returned nil.
    /// Callers use the return value to surface watcher death to the UI —
    /// previously this was a void method that only `print`ed on failure.
    @discardableResult
    func start() -> Bool {
        var started = false
        queue.sync {
            guard !running, !paths.isEmpty else { return }

            let pathStrings = paths.map { $0.path } as CFArray

            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )

            // Flags (what's intentionally NOT here is as important):
            //
            // - `kFSEventStreamCreateFlagIgnoreSelf` — dropped. Self-writes
            //   land in `.nanoteams/internal/` which is excluded from the
            //   index walk, so they trigger a no-op signature check. With
            //   the flag set, every file emitted by `edit_file`/`write_file`/
            //   `create_artifact` was silently swallowed and the index drifted.
            //
            // - `kFSEventStreamCreateFlagNoDefer` — dropped. With `NoDefer`,
            //   the *first* event after subscription fires immediately and
            //   starts the latency window; ambient bootstrap events inside
            //   the 1.0-s subscription warmup therefore slip past a quick
            //   `stop()` on the watcher (the work item's debounce deadline
            //   lands before `stop` enters the queue). Without the flag,
            //   FSEvents buffers every event for `latency` seconds before
            //   the first callback — any `stop()` inside that window
            //   invalidates the stream and the buffered events are dropped.
            //   Real-world latency of ~1 s extra on a single-file change is
            //   fine here: this signals "re-run a signature probe", not
            //   "render this event to the user".
            //
            // - `kFSEventStreamCreateFlagUseCFTypes` — dropped. Asking
            //   FSEvents to deliver paths as a `CFArray` measurably shifts
            //   event-delivery timing in tests (regressed
            //   `testStop_suppressesFurtherEvents` when tried). We stick
            //   with the default C-array (`char **`) so the delivery
            //   contract matches the test expectations; `handleCallback`
            //   reads the path array directly.
            let flags: FSEventStreamCreateFlags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
            )

            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                { _, info, numEvents, eventPaths, eventFlags, _ in
                    guard let info = info, numEvents > 0 else { return }
                    let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
                    watcher.handleCallback(
                        numEvents: numEvents,
                        eventPaths: eventPaths,
                        eventFlags: eventFlags
                    )
                },
                &context,
                pathStrings,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                1.0, // latency seconds — FSEvents internal coalescing
                flags
            ) else {
                print("[FileSystemWatcher] FSEventStreamCreate returned nil; watcher disabled.")
                return
            }

            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)

            self.stream = stream
            running = true
            started = true
        }
        return started
    }

    func stop() {
        queue.sync {
            guard running, let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            pendingWorkItem?.cancel()
            pendingWorkItem = nil
            running = false
        }
    }

    // MARK: - Private

    /// FSEvents callback entry point (runs on `queue`). Parses the default
    /// C-array (`char **`) eventPaths, drops batches that are entirely
    /// under an excluded prefix, then debounces via `scheduleFire`.
    fileprivate func handleCallback(
        numEvents: Int,
        eventPaths: UnsafeMutableRawPointer,
        eventFlags: UnsafePointer<FSEventStreamEventFlags>
    ) {
        if !excludedPrefixes.isEmpty {
            let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
            var anyFileIncluded = false
            let dirFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
            for i in 0..<numEvents {
                guard let cString = paths[i] else { continue }
                // Directory-level events are metadata noise here: when a file
                // inside an excluded subtree is written, FSEvents also fires
                // mtime events on every ancestor directory up to the watched
                // root (including the root itself), whose path doesn't carry
                // the excluded prefix. Those aren't "real changes" — skip
                // them and let file-level events decide.
                if (eventFlags[i] & dirFlag) != 0 { continue }
                let path = String(cString: cString)
                if !excludedPrefixes.contains(where: { path.hasPrefix($0) }) {
                    anyFileIncluded = true
                    break
                }
            }
            if !anyFileIncluded { return }
        }
        scheduleFire()
    }

    private func scheduleFire() {
        // FSEvents already delivers on `queue`, but be explicit: everything
        // that touches `pendingWorkItem` / `running` must run on `queue`.
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.pendingWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                // This body runs on `queue` (via `asyncAfter(execute:)`),
                // so we can read `running` directly without another hop.
                // Re-check running — teardown between schedule and fire
                // must suppress the callback.
                guard let self, self.running else { return }
                self.onChange()
            }
            self.pendingWorkItem = work
            self.queue.asyncAfter(deadline: .now() + self.debounce, execute: work)
        }
    }
}

extension FileSystemWatcher: FileSystemWatching {}

extension FileSystemWatcher {
    /// The production factory — the only one that opens a real FSEvents stream.
    ///
    /// Named rather than written inline at the call site so the orchestrator's
    /// `SearchIndexCoordinator(...)` reads as a choice ("live watcher") instead of as a
    /// closure literal a reader has to decode, and so a test can assert that production's
    /// factory really is the live one.
    static let live: FileSystemWatcherFactory = { paths, excludedPrefixes, debounce, onChange in
        FileSystemWatcher(
            paths: paths,
            excludedPrefixes: excludedPrefixes,
            debounce: debounce,
            onChange: onChange
        )
    }
}
