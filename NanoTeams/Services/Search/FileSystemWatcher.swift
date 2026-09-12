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
/// Used by `SearchIndexCoordinator` to trigger an index refresh when the work folder changes.
/// The callback is fired no more than once per `debounce` window even if FSEvents reports a
/// burst of changes.
nonisolated final class FileSystemWatcher: @unchecked Sendable {
    typealias Handler = @Sendable () -> Void

    private let paths: [URL]
    private let excludedPrefixes: [String]
    /// The watched roots, canonicalised and pre-split. Canonicalised for the same reason
    /// `excludedPrefixes` is — FSEvents says `/private/var/…` where the caller said `/var/…`.
    private let canonicalRoots: [WatchRoot]
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
    ///   otherwise wake a walk of the whole tree every `debounce` seconds.
    init(
        paths: [URL],
        excludedPrefixes: [URL] = [],
        debounce: TimeInterval = 2.0,
        onChange: @escaping Handler
    ) {
        self.paths = paths
        self.excludedPrefixes = excludedPrefixes.map { Self.canonicalPath(for: $0) }
        self.canonicalRoots = paths.map { WatchRoot(canonicalPath: Self.canonicalPath(for: $0)) }
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
            //   index walk, so they wake a walk that can only conclude
            //   "nothing changed". With
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
            //   fine here: this signals "re-check the folder", not
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

    /// A watched root, split into path components ONCE.
    ///
    /// Not a bare `String`: making an event path relative to a root by `dropFirst(root.count)`
    /// re-measures the root on every single event, and `String.count` is O(graphemes). The
    /// callback runs per FSEvents batch during a `git checkout` or an `xcodebuild`, which is
    /// exactly when the measurement is least affordable.
    struct WatchRoot: Sendable, Equatable {
        let components: [String]

        init(canonicalPath: String) {
            components = canonicalPath.split(separator: "/").map(String.init)
        }
    }

    /// Whether one event path is worth waking the index for.
    ///
    /// The watcher asks the WALK's own question, because waking the index for a path the walk
    /// will skip buys a guaranteed-empty rebuild. Before 2026-09-11 the only filter was
    /// `excludedPrefixes` (in practice `.nanoteams/internal/`), so a `git status` woke a full
    /// walk of the tree through the debounce window, and an `xcodebuild` kept the indexer busy
    /// continuously — neither of which can change a single token.
    ///
    /// Judged on the path RELATIVE to the watched root: a work folder at
    /// `~/.cache/projects/wf` is the user's choice, and reading `.cache` out of its absolute
    /// path would make every event inside it uninteresting — auto-refresh silently off, with
    /// nothing logged. Static and pure so the rule is testable without an FSEvents stream.
    static func isInteresting(
        path: String, roots: [WatchRoot], excludedPrefixes: [String]
    ) -> Bool {
        if excludedPrefixes.contains(where: { path.hasPrefix($0) }) { return false }
        let components = path.split(separator: "/")
        // The DEEPEST matching root: nested roots would otherwise judge the same event by the
        // outer one's components, which is the same mistake as judging the absolute path.
        var depth: Int?
        for root in roots where root.components.count < components.count {
            guard components.starts(with: root.components, by: { $0 == $1 }) else { continue }
            if root.components.count > (depth ?? -1) { depth = root.components.count }
        }
        // Under no watched root at all: FSEvents should not deliver one, and we have no rule
        // to judge it by. Keep it — a spurious walk is cheaper than a missed change.
        guard let depth else { return true }
        return !components.dropFirst(depth).contains {
            WalkSkipRules.shouldSkip(name: String($0))
        }
    }

    /// One event, as the policy below needs to see it.
    struct Event: Equatable {
        /// `nil` when FSEvents delivered a null path — it does, rarely, and a null is not a
        /// reason to drop the rest of the batch.
        let path: String?
        let isDirectory: Bool
        /// The kernel dropped events it could not queue.
        let mustScanSubDirs: Bool
    }

    /// Whether a batch is worth waking the index for.
    ///
    /// Pure, and separate from the callback, because the callback is C interop — an
    /// `UnsafeMutableRawPointer` of `char *` and a parallel flags array — which no test can
    /// construct without lying about the memory layout. Splitting them makes the POLICY
    /// testable line by line and leaves the callback with nothing but the decode.
    ///
    /// "Drop only if EVERYTHING is uninteresting" — the same contract the excluded-prefix
    /// filter has always had, since one real edit among a hundred log writes is still an edit.
    static func shouldWake(
        _ events: [Event], roots: [WatchRoot], excludedPrefixes: [String]
    ) -> Bool {
        for event in events {
            // We no longer know WHAT changed — only that something did. A wasted walk is
            // cheaper than an index that silently stops tracking the folder.
            if event.mustScanSubDirs { return true }
            guard let path = event.path else { continue }
            // Directory-level events are metadata noise here: when a file inside a subtree is
            // written, FSEvents also fires mtime events on every ancestor directory up to the
            // watched root (including the root itself), whose path doesn't carry the subtree's
            // name. Those aren't "real changes" — let file-level events decide.
            if event.isDirectory { continue }
            if isInteresting(path: path, roots: roots, excludedPrefixes: excludedPrefixes) {
                return true
            }
        }
        return false
    }

    /// FSEvents callback entry point (runs on `queue`). Decodes the default C-array
    /// (`char **`) eventPaths and hands the batch to `shouldWake`.
    fileprivate func handleCallback(
        numEvents: Int,
        eventPaths: UnsafeMutableRawPointer,
        eventFlags: UnsafePointer<FSEventStreamEventFlags>
    ) {
        let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
        let dirFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
        let mustScanFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        let events = (0..<numEvents).map { i in
            Event(path: paths[i].map { String(cString: $0) },
                  isDirectory: (eventFlags[i] & dirFlag) != 0,
                  mustScanSubDirs: (eventFlags[i] & mustScanFlag) != 0)
        }
        guard Self.shouldWake(
            events, roots: canonicalRoots, excludedPrefixes: excludedPrefixes) else { return }
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
