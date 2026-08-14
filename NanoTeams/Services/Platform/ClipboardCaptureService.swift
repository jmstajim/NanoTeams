import AppKit
import ApplicationServices

/// String value of the CoreFoundation `kAXTrustedCheckOptionPrompt` global,
/// inlined here as a plain `CFString` literal so Swift 6's data-race checker
/// doesn't fire on the AX symbol (it's declared `var` in the headers but is
/// effectively immutable — even reading it via `takeUnretainedValue()` trips
/// "reference to var is not concurrency-safe" with no clean escape hatch under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`). The string value is part of
/// Apple's public ABI and has been stable for ~15+ years.
nonisolated(unsafe) private let _trustedCheckPromptKey: CFString = "AXTrustedCheckOptionPrompt" as CFString

// MARK: - Clipboard Capture Result

/// Result of a smart clipboard capture — may contain text, file URLs, or both.
nonisolated struct ClipboardCaptureResult {
    var text: String?
    var fileURLs: [URL]

    /// The user's previous clipboard could not be put back after the simulated ⌘C.
    ///
    /// Rides on the capture result because the capture is this call's only return channel, and a
    /// restore that quietly fails leaves the user's clipboard holding OUR captured selection (or
    /// nothing) with no signal at all — they discover it at the next ⌘V, by which time the original
    /// is unrecoverable. Cheap to act on once surfaced: re-copy.
    var restoreFailed: Bool = false

    static let empty = ClipboardCaptureResult(text: nil, fileURLs: [])
}

// MARK: - Source Context

/// Metadata about the source location of a clipboard capture from a code editor.
nonisolated struct SourceContext {
    let filePath: String
    let lineStart: Int?
    let lineEnd: Int?

    /// Derived, not stored. It used to be a second stored field set from the same `docURL` the
    /// path came from — two values that had to agree with nothing making them, and after the
    /// header switched to `NTMSPaths.relativePathFromProjectRoot` nothing in production read it
    /// at all. Computing it removes both the dead storage and the possibility of disagreement.
    ///
    /// `NSString.lastPathComponent`, deliberately, NOT `URL(fileURLWithPath:).lastPathComponent`:
    /// the latter resolves an EMPTY path against the process's current directory (measured), so
    /// an empty `filePath` would report the working directory's name as the file's — a plausible
    /// name for a file that does not exist. This is pure string manipulation with no filesystem
    /// semantics, which is all a name needs.
    var fileName: String { (filePath as NSString).lastPathComponent }

    /// Zero-width space sentinel prevents false positives on user code containing `// Source: `.
    private static let headerPrefix = "\u{200B}// Source: "

    /// Splits an enriched clip back into its `// Source: path:start-end` label and its body.
    /// Returns nil if the text doesn't start with the sentinel header, or has no body.
    ///
    /// The split point is the first LINE BREAK, not the first `"\n"`. Swift merges CRLF into a
    /// SINGLE `Character` that is not equal to `"\n"`, so `firstIndex(of: "\n")` finds nothing in
    /// a CRLF-terminated header and the whole clip parses to `nil` — losing the attribution AND
    /// the body, i.e. the card renders as one undifferentiated blob. `Character.isNewline`
    /// matches the cluster (and all seven newline scalars), and `index(after:)` steps past both
    /// units of it, so the `\r` never leaks into the body.
    ///
    /// Not reachable from this file's own writer, which emits a bare LF — but the trap is
    /// invisible in the source and the next person here will reach for `firstIndex(of:)` too.
    /// Same class as `lineRange`'s CRLF counting note above.
    static func parse(_ text: String) -> (source: String, body: String)? {
        guard text.hasPrefix(headerPrefix) else { return nil }
        guard let newlineIndex = text.firstIndex(where: \.isNewline) else { return nil }
        let source = String(text[text.index(text.startIndex, offsetBy: headerPrefix.count)..<newlineIndex])
        let body = String(text[text.index(after: newlineIndex)...])
        guard !body.isEmpty else { return nil }
        return (source: source, body: body)
    }
}

// MARK: - Capture environment seams

/// One pasteboard item's data, keyed by type — everything needed to put it back.
nonisolated struct PasteboardItemSnapshot: Sendable, Equatable {
    let dataByType: [NSPasteboard.PasteboardType: Data]
}

/// The system pasteboard, as an injectable seam.
///
/// `snapshotItems()` returns an OPTIONAL for a load-bearing reason: `NSPasteboard.pasteboardItems`
/// is itself optional, and "the clipboard was empty" and "the clipboard could not be read" demand
/// OPPOSITE restores. Collapsing them (as `[]` did) makes an unreadable pasteboard indistinguishable
/// from an empty one, and the restore then clears content it merely failed to record.
nonisolated protocol PasteboardAccessing: Sendable {
    var changeCount: Int { get }
    /// nil = could not read. `[]` = read successfully, and it was empty.
    func snapshotItems() -> [PasteboardItemSnapshot]?
    func string() -> String?
    func fileURLs() -> [URL]
    func clear()
    /// false = the write did not land, i.e. the user's clipboard is now wrong.
    func write(_ items: [PasteboardItemSnapshot]) -> Bool
}

/// Just the two facts about the frontmost app this file needs, as values — an
/// `NSRunningApplication` cannot be constructed in a fixture.
nonisolated struct FrontmostApplication: Sendable, Equatable {
    let bundleIdentifier: String?
    let processIdentifier: pid_t
}

nonisolated protocol FrontmostApplicationProviding: Sendable {
    func frontmostApplication() -> FrontmostApplication?
}

/// "Nothing is frontmost" — the inert conformance, used where a live read would make a test's
/// answer depend on whichever app the developer happened to have in front.
nonisolated struct NoFrontmostApplicationProvider: FrontmostApplicationProviding {
    func frontmostApplication() -> FrontmostApplication? { nil }
}

nonisolated protocol AccessibilityTrustProviding: Sendable {
    var isTrusted: Bool { get }
    /// Raises the system TCC dialog and opens System Settings.
    func promptForTrust()
}

/// Posts the ⌘C that makes the source app fill the pasteboard. The one irreducibly untestable act
/// in this file — a real key event goes to whatever app is frontmost.
nonisolated protocol CopyKeystrokeSynthesizing: Sendable {
    func synthesizeCopy()
}

/// A focused text selection: the UTF-16 range plus the full text it indexes into.
nonisolated struct AXSelection: Sendable, Equatable {
    let range: AXTextRange
    let text: String
}

/// The two Accessibility facts source enrichment needs from the frontmost editor. Deliberately
/// value-in / value-out rather than the tree-shaped `AXNodeReading`: nothing above this seam
/// traverses, it asks two questions.
nonisolated protocol AXSourceContextReading: Sendable {
    /// Raw `kAXDocumentAttribute` of the focused window — a URL string for most editors, a bare
    /// POSIX path for some (see `documentURL(fromAXDocumentAttribute:)`).
    func focusedDocumentPath(pid: pid_t) -> String?
    func focusedSelection(pid: pid_t) -> AXSelection?
}

/// Everything `captureSelection` touches outside its own arithmetic.
///
/// Bundled rather than passed as five parameters because the call graph threads them through four
/// functions, and because `.system` is then the single place the live adapters are named — the same
/// discipline `SelectionCapturing` applies one layer up.
nonisolated struct ClipboardCaptureEnvironment: Sendable {
    let pasteboard: any PasteboardAccessing
    let frontmost: any FrontmostApplicationProviding
    let trust: any AccessibilityTrustProviding
    let copyKeystroke: any CopyKeystrokeSynthesizing
    let axSource: any AXSourceContextReading
    /// This process's bundle id, so the "don't capture from ourselves" bail is a decision and not a
    /// hidden `Bundle.main` read.
    let ownBundleIdentifier: String?
    let maxPollAttempts: Int
    let pollIntervalMilliseconds: UInt64

    static let system = ClipboardCaptureEnvironment(
        pasteboard: SystemPasteboard(),
        frontmost: SystemFrontmostApplicationProvider(),
        trust: SystemAccessibilityTrust(),
        copyKeystroke: SystemCopyKeystroke(),
        axSource: SystemAXSourceContextReader(),
        ownBundleIdentifier: Bundle.main.bundleIdentifier,
        maxPollAttempts: 10,
        pollIntervalMilliseconds: 50)
}

// MARK: - Clipboard Capture Service

/// Captures selected content from the frontmost application by simulating Cmd+C.
/// Returns file URLs (e.g. from Finder) and/or text depending on what the source app places on the pasteboard.
nonisolated enum ClipboardCaptureService {

    /// Captures the currently selected content from the frontmost application.
    /// When `workFolderRoot` is provided and the source file is within that directory,
    /// the captured text is enriched with a `// Source:` header containing the relative path and line numbers.
    /// - Parameter workFolderRoot: The project's working directory. Pass `nil` to skip source enrichment.
    /// - Returns: A result containing captured text and/or file URLs.
    static func captureSelection(
        workFolderRoot: URL? = nil,
        environment: ClipboardCaptureEnvironment = .system
    ) async -> ClipboardCaptureResult {
        guard environment.trust.isTrusted else { return .empty }

        // Read the frontmost app ONCE and thread its pid down. Reading it a second time inside
        // source detection raced the user: the app could change between the two reads, and then the
        // `// Source:` header would name a document belonging to an app we never captured from.
        let frontApp = environment.frontmost.frontmostApplication()

        // Skip capture if NanoTeams itself is frontmost (e.g. user just clicked sidebar) —
        // Cmd+C would have nothing to copy and we'd waste 500 ms polling.
        if let frontApp, frontApp.bundleIdentifier == environment.ownBundleIdentifier {
            return .empty
        }

        let pasteboard = environment.pasteboard
        let previousChangeCount = pasteboard.changeCount
        let previousContents = pasteboard.snapshotItems()

        // Detect source BEFORE simulating copy (source app is still frontmost).
        var sourceContext: SourceContext?
        if let root = workFolderRoot, let pid = frontApp?.processIdentifier {
            sourceContext = detectSourceContext(
                pid: pid, workFolderRoot: root, ax: environment.axSource)
        }

        environment.copyKeystroke.synthesizeCopy()

        var captured = await pollPasteboardCapture(
            pasteboard: pasteboard,
            previousChangeCount: previousChangeCount,
            maxAttempts: environment.maxPollAttempts,
            intervalMilliseconds: environment.pollIntervalMilliseconds)

        // Restore is keyed on "did the pasteboard change", NOT on "did we get a usable capture".
        // Those differ, and the gap destroyed clipboards: ⌘C on an image (or on anything whose only
        // representation is a private type) bumps the change count while yielding neither a string
        // nor file URLs, so the poll returns nil — and the old code restored ONLY in the `if let
        // captured` branch. The user's clipboard was left holding the source app's payload with the
        // original gone, from a keystroke they never pressed.
        let restore = restoreAction(
            snapshot: previousContents,
            pasteboardChanged: pasteboard.changeCount != previousChangeCount)
        let restored = applyRestore(restore, to: pasteboard)

        guard captured != nil else {
            return ClipboardCaptureResult(text: nil, fileURLs: [], restoreFailed: !restored)
        }

        // Enrich text with source context (path check already done in detectSourceContext)
        if let text = captured?.text, !text.isEmpty,
           let ctx = sourceContext, let root = workFolderRoot {
            captured?.text = enrichText(text, with: ctx, relativeTo: root)
        }
        captured?.restoreFailed = !restored
        return captured ?? .empty
    }

    /// Prompts the user for Accessibility permissions if not already granted.
    /// Opens System Settings automatically.
    static func requestAccessibilityIfNeeded(environment: ClipboardCaptureEnvironment = .system) {
        guard !environment.trust.isTrusted else { return }
        environment.trust.promptForTrust()
    }

    // MARK: - Source Context Detection

    /// Which source file the frontmost editor has focused, and which lines the selection covers —
    /// or nil when the file is not inside `workFolderRoot`.
    ///
    /// **The path check runs BEFORE the selection read, and that ordering is the contract.**
    /// `focusedSelection` pulls the focused element's ENTIRE text across a process boundary; for a
    /// file outside the work folder that answer is thrown away, so asking for it is pure cost paid
    /// on every ⌃⌥⌘K in an unrelated app.
    ///
    /// A zero-length range is a CARET, not a selection: the user pressed ⌃⌥⌘K with nothing
    /// highlighted, and reporting "lines 12-12" would attach a line reference the clip does not
    /// have. The file is still worth naming, so the path survives and the lines go nil.
    static func detectSourceContext(
        pid: pid_t, workFolderRoot: URL, ax: any AXSourceContextReading
    ) -> SourceContext? {
        guard let raw = ax.focusedDocumentPath(pid: pid),
              let docURL = documentURL(fromAXDocumentAttribute: raw) else { return nil }
        let filePath = docURL.path

        guard SandboxPathResolver.isWithin(
            candidate: URL(fileURLWithPath: filePath), container: workFolderRoot) else { return nil }

        guard let selection = ax.focusedSelection(pid: pid), selection.range.length > 0 else {
            return SourceContext(filePath: filePath, lineStart: nil, lineEnd: nil)
        }
        let lines = lineRange(
            inUTF16Text: selection.text,
            location: selection.range.location, length: selection.range.length)
        return SourceContext(filePath: filePath, lineStart: lines.start, lineEnd: lines.end)
    }

    /// A `CFRange` of UTF-16 offsets → 1-based `(start, end)` line numbers.
    ///
    /// Split out of `detectLineRange` because everything above it is AX-gated and posts a real
    /// Cmd+C, so this arithmetic — the part that can actually be wrong — was unreachable from a
    /// test. NSString is used deliberately: `CFRange` counts UTF-16 code units, and indexing the
    /// Swift `String` by Character would misplace the offsets for any non-BMP text.
    ///
    /// **Both ends are clamped, and the end is derived from the CLAMPED start.** Deriving it from
    /// the raw location let two things through:
    ///   • `location == kCFNotFound` (-1) — a value some AX providers really do return — computed
    ///     `startLine` from a clamped 0 but `endLine` from -1, so the `// Source: path:start-end`
    ///     header handed to the LLM named a range the snippet does not occupy.
    ///   • any `location + length < 0` produced a NEGATIVE offset for `substring(to:)`, which
    ///     takes an `NSUInteger` — the negative `Int` bridges to a huge unsigned value and
    ///     `NSRangeException` is raised. That is an ObjC exception, not a Swift error, so nothing
    ///     catches it and Ctrl+Opt+Cmd+K aborts the app.
    ///
    /// Lines are counted over UTF-16 CODE UNITS, not `Character`s. Swift merges CRLF into a
    /// SINGLE grapheme cluster, and that cluster is not equal to `"\n"` — so the previous
    /// `filter { $0 == "\n" }` over Characters counted ZERO newlines in any CRLF document and
    /// reported every selection as line 1. Counting `0x0A` in UTF-16 is right for both LF and
    /// CRLF (a CRLF is two units, exactly one of which is `0x0A`).
    ///
    /// A classic-Mac CR-only document still reports every line as 1 — a known limit, kept
    /// deliberately: counting CR as well would double-count CRLF, and no editor this feature
    /// captures from writes CR-only.
    nonisolated static func lineRange(
        inUTF16Text text: String, location: Int, length: Int
    ) -> (start: Int, end: Int) {
        let nsText = text as NSString
        let safeLocation = min(max(location, 0), nsText.length)
        // The end is the clamped START plus the length — NOT the raw `location + length`. Adding
        // to the raw location is what let a garbage location leak into one endpoint while the
        // other was clamped, so the two disagreed about where the selection began. A negative
        // length is equally garbage and collapses the range instead of inverting it; because both
        // operands are now >= 0, `safeEnd >= safeLocation` holds by construction rather than by a
        // floor bolted on afterwards.
        let (sum, overflow) = safeLocation.addingReportingOverflow(max(length, 0))
        let safeEnd = overflow ? nsText.length : min(sum, nsText.length)

        let utf16 = Array(text.utf16)
        // `NSString.length` and the UTF-16 view agree by construction, but clamp anyway rather
        // than index a slice out of bounds if they ever don't.
        func lineNumber(atUTF16Offset offset: Int) -> Int {
            let end = min(max(offset, 0), utf16.count)
            return utf16[0..<end].reduce(into: 1) { count, unit in
                if unit == 0x0A { count += 1 }
            }
        }

        return (start: lineNumber(atUTF16Offset: safeLocation),
                end: lineNumber(atUTF16Offset: safeEnd))
    }

    // MARK: - Text Enrichment

    /// Interprets whatever an editor put in `kAXDocumentAttribute`.
    ///
    /// The attribute is documented as a URL string and most editors do send `file:///…`, but it
    /// carries whatever the app decided to put there, and some report a BARE POSIX PATH. Those
    /// used to be dropped: `URL(string: "/Users/a/x.swift")` succeeds — as a scheme-less relative
    /// URL — so the old `docURL.isFileURL` test returned false and source enrichment switched
    /// itself off for that editor entirely, with no signal anywhere. The user just never saw a
    /// `// Source:` header and had no way to tell it was supposed to appear.
    ///
    /// The bare-path fallback requires a LEADING SLASH so a relative string can never be turned
    /// into a path (which `URL(fileURLWithPath:)` would silently resolve against the process's
    /// current directory — measured, and the reason `enrichText` guards its empty case too).
    nonisolated static func documentURL(fromAXDocumentAttribute raw: String) -> URL? {
        if let url = URL(string: raw), url.isFileURL { return url }
        guard raw.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: raw)
    }

    /// Prepends a `// Source:` header with relative path and line numbers to the captured text.
    ///
    /// Split out of `captureSelection` for the same reason as `lineRange` above: everything that
    /// reaches it is AX-gated and posts a real Cmd+C, so the one part that can actually be wrong —
    /// the path the LLM is handed — was unreachable from a test.
    ///
    /// **Relativization goes through `NTMSPaths.relativePathFromProjectRoot`, never a raw
    /// `hasPrefix` on `.path`.** The gate that lets us get here (`SandboxPathResolver.isWithin` in
    /// `detectSourceContext`) compares STANDARDIZED path components, so it accepts a path the raw
    /// string prefix then rejects — `..` segments always, and a `/private/tmp`-vs-`/tmp` root
    /// whenever the file exists. Every such disagreement silently downgraded the header to the
    /// bare file name, i.e. `<root>/App.swift` for a file that really lives at
    /// `<root>/Sources/App.swift`; the model copies that verbatim into `read_file` and gets
    /// FILE_NOT_FOUND with no hint that the reference was fabricated.
    ///
    /// A genuine miss therefore emits the ABSOLUTE path, not the bare name — an honest absolute
    /// path preserves the file's provenance and `SandboxPathResolver` accepts it, whereas a
    /// truncated one manufactures a plausible path that never existed.
    nonisolated static func enrichText(
        _ text: String, with ctx: SourceContext, relativeTo root: URL
    ) -> String {
        // An empty `filePath` is reachable — `URL(string: "file://")` IS a file URL and its `.path`
        // is "" — and `URL(fileURLWithPath: "")` silently resolves to the process's CURRENT
        // DIRECTORY, so it must never reach the relativizer.
        let relative = ctx.filePath.isEmpty ? "" : NTMSPaths(workFolderRoot: root)
            .relativePathFromProjectRoot(for: URL(fileURLWithPath: ctx.filePath))
        let relativePath = relative.isEmpty ? ctx.filePath : relative

        let lineInfo: String
        if let start = ctx.lineStart, let end = ctx.lineEnd, end > start {
            lineInfo = ":\(start)-\(end)"
        } else if let start = ctx.lineStart {
            lineInfo = ":\(start)"
        } else {
            lineInfo = ""
        }

        return "\u{200B}// Source: \(relativePath)\(lineInfo)\n\(text)"
    }

    // MARK: - Polling

    /// Waits for the ⌘C to land, then reads whatever the source app published.
    ///
    /// **Polling continues after a change count bump that yielded nothing readable**, deliberately:
    /// an app using `NSPasteboardItemDataProvider` declares its types (bumping the count) and only
    /// fills the data lazily, so the first tick after the bump legitimately reads empty. Bailing on
    /// the first unreadable tick would drop those captures.
    ///
    /// A non-nil but EMPTY string counts as a capture. That is the source app's answer — "the
    /// selection is empty" — and `ClipboardStagingPolicy` is the layer that decides an empty clip is
    /// not worth staging; folding that judgement in here would hide the difference between "the app
    /// published nothing" and "the app published emptiness".
    static func pollPasteboardCapture(
        pasteboard: any PasteboardAccessing,
        previousChangeCount: Int,
        maxAttempts: Int,
        intervalMilliseconds: UInt64
    ) async -> ClipboardCaptureResult? {
        for _ in 0..<maxAttempts {
            try? await Task.sleep(for: .milliseconds(intervalMilliseconds))

            if pasteboard.changeCount != previousChangeCount {
                let text = pasteboard.string()
                let fileURLs = pasteboard.fileURLs()
                guard text != nil || !fileURLs.isEmpty else { continue }
                return ClipboardCaptureResult(text: text, fileURLs: fileURLs)
            }
        }
        return nil
    }

    // MARK: - Snapshot / restore

    /// What to do with the pasteboard once the capture attempt is over.
    nonisolated enum PasteboardRestoreAction: Equatable {
        /// Nothing we did changed the pasteboard, so nothing of ours is on it. Writing here could
        /// only destroy content someone else put there while we were polling.
        case leaveAlone
        /// The snapshot could not be taken, so there is nothing to put back — and clearing would
        /// destroy content we merely failed to record. Leave the capture on the board: visible and
        /// recoverable beats silently empty.
        case cannotRestore
        /// Put these back. An EMPTY array is a real answer — the clipboard was genuinely empty
        /// before, so clearing is the faithful restore.
        case rewrite([PasteboardItemSnapshot])
    }

    static func restoreAction(
        snapshot: [PasteboardItemSnapshot]?, pasteboardChanged: Bool
    ) -> PasteboardRestoreAction {
        guard pasteboardChanged else { return .leaveAlone }
        guard let snapshot else { return .cannotRestore }
        return .rewrite(snapshot)
    }

    /// Returns whether the clipboard ended up in the state the action asked for. `.leaveAlone` and
    /// `.cannotRestore` are both "as good as it gets" and report success; only a rewrite can fail.
    @discardableResult
    static func applyRestore(
        _ action: PasteboardRestoreAction, to pasteboard: any PasteboardAccessing
    ) -> Bool {
        guard case .rewrite(let items) = action else { return true }
        pasteboard.clear()
        guard !items.isEmpty else { return true }
        return pasteboard.write(items)
    }
}

// MARK: - Live conformances

nonisolated struct SystemPasteboard: PasteboardAccessing {
    var changeCount: Int { NSPasteboard.general.changeCount }

    func snapshotItems() -> [PasteboardItemSnapshot]? {
        guard let items = NSPasteboard.general.pasteboardItems else { return nil }
        return items.map { item in
            var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dataByType[type] = data }
            }
            return PasteboardItemSnapshot(dataByType: dataByType)
        }
    }

    func string() -> String? { NSPasteboard.general.string(forType: .string) }

    func fileURLs() -> [URL] {
        (NSPasteboard.general.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: NSNumber(value: true)]) as? [URL]) ?? []
    }

    func clear() { NSPasteboard.general.clearContents() }

    func write(_ items: [PasteboardItemSnapshot]) -> Bool {
        NSPasteboard.general.writeObjects(items.map { snapshot in
            let item = NSPasteboardItem()
            for (type, data) in snapshot.dataByType { item.setData(data, forType: type) }
            return item
        })
    }
}

nonisolated struct SystemFrontmostApplicationProvider: FrontmostApplicationProviding {
    func frontmostApplication() -> FrontmostApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontmostApplication(
            bundleIdentifier: app.bundleIdentifier, processIdentifier: app.processIdentifier)
    }
}

nonisolated struct SystemAccessibilityTrust: AccessibilityTrustProviding {
    var isTrusted: Bool { AXIsProcessTrusted() }

    func promptForTrust() {
        _ = AXIsProcessTrustedWithOptions([_trustedCheckPromptKey: true] as CFDictionary)
    }
}

nonisolated struct SystemCopyKeystroke: CopyKeystrokeSynthesizing {
    func synthesizeCopy() {
        let source = CGEventSource(stateID: .hidSystemState)
        // Key code 8 = 'c'
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
        else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

/// Reuses `SystemAXNodeReader` rather than re-issuing raw `AXUIElementCopyAttributeValue` calls:
/// one live Accessibility adapter for the whole Platform layer, two shapes of question asked of it.
nonisolated struct SystemAXSourceContextReader: AXSourceContextReading {
    private let reader = SystemAXNodeReader()

    func focusedDocumentPath(pid: pid_t) -> String? {
        let app = reader.applicationNode(pid: pid)
        guard let window = reader.element(kAXFocusedWindowAttribute as String, of: app) else { return nil }
        return reader.string(kAXDocumentAttribute as String, of: window)
    }

    func focusedSelection(pid: pid_t) -> AXSelection? {
        let app = reader.applicationNode(pid: pid)
        guard let focused = reader.element(kAXFocusedUIElementAttribute as String, of: app),
              let range = reader.selectedRange(of: focused),
              let text = reader.string(kAXValueAttribute as String, of: focused) else { return nil }
        return AXSelection(range: range, text: text)
    }
}
