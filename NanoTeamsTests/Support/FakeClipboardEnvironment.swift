import AppKit
import Foundation

@testable import NanoTeams

/// A scriptable stand-in for `NSPasteboard.general`.
///
/// The whole point is that `snapshotItems()` can answer nil ("could not read") independently of
/// `[]` ("read it, and it was empty") — the distinction the real restore path collapsed, and the
/// one that decides whether a ⌃⌥⌘K destroys the user's clipboard.
final class FakePasteboard: PasteboardAccessing, @unchecked Sendable {
    var changeCount: Int = 1
    /// nil models `NSPasteboard.pasteboardItems == nil`.
    var snapshot: [PasteboardItemSnapshot]? = []
    var currentString: String?
    var currentFileURLs: [URL] = []
    /// false models `NSPasteboard.writeObjects` refusing the write.
    var writeSucceeds = true

    private(set) var clearCount = 0
    private(set) var writes: [[PasteboardItemSnapshot]] = []
    private(set) var snapshotReads = 0
    private(set) var changeCountReads = 0

    func snapshotItems() -> [PasteboardItemSnapshot]? {
        snapshotReads += 1
        return snapshot
    }

    func string() -> String? { currentString }
    func fileURLs() -> [URL] { currentFileURLs }

    func clear() {
        clearCount += 1
        changeCount += 1
    }

    func write(_ items: [PasteboardItemSnapshot]) -> Bool {
        writes.append(items)
        changeCount += 1
        return writeSucceeds
    }

    /// What a source app's ⌘C does: bump the change count and publish something.
    func simulateExternalCopy(text: String? = nil, fileURLs: [URL] = []) {
        changeCount += 1
        currentString = text
        currentFileURLs = fileURLs
    }

    /// A ⌘C whose payload we cannot read — an image, or anything published only under a private
    /// type. The change count moves; nothing readable appears.
    func simulateUnreadableCopy() {
        changeCount += 1
        currentString = nil
        currentFileURLs = []
    }

    static func item(_ text: String) -> PasteboardItemSnapshot {
        PasteboardItemSnapshot(dataByType: [.string: Data(text.utf8)])
    }
}

final class FakeFrontmostApplicationProvider: FrontmostApplicationProviding, @unchecked Sendable {
    var app: FrontmostApplication?
    private(set) var reads = 0

    init(app: FrontmostApplication? = FrontmostApplication(
        bundleIdentifier: "com.example.editor", processIdentifier: 4242)) {
        self.app = app
    }

    func frontmostApplication() -> FrontmostApplication? {
        reads += 1
        return app
    }
}

final class FakeAccessibilityTrust: AccessibilityTrustProviding, @unchecked Sendable {
    var isTrusted: Bool
    private(set) var promptCount = 0

    init(isTrusted: Bool = true) { self.isTrusted = isTrusted }

    func promptForTrust() { promptCount += 1 }
}

/// Records the ⌘C and, optionally, performs the pasteboard side effect a real source app would.
final class FakeCopyKeystroke: CopyKeystrokeSynthesizing, @unchecked Sendable {
    private(set) var copies = 0
    var onCopy: (@Sendable () -> Void)?

    func synthesizeCopy() {
        copies += 1
        onCopy?()
    }
}

final class FakeAXSourceReader: AXSourceContextReading, @unchecked Sendable {
    var documentPath: String?
    var selection: AXSelection?

    private(set) var documentPathRequests: [pid_t] = []
    private(set) var selectionRequests: [pid_t] = []

    init(documentPath: String? = nil, selection: AXSelection? = nil) {
        self.documentPath = documentPath
        self.selection = selection
    }

    func focusedDocumentPath(pid: pid_t) -> String? {
        documentPathRequests.append(pid)
        return documentPath
    }

    func focusedSelection(pid: pid_t) -> AXSelection? {
        selectionRequests.append(pid)
        return selection
    }
}

/// The five fakes plus the environment that binds them, so a test states only what it varies.
///
/// `pollIntervalMilliseconds` is 0 so the ten-attempt budget costs scheduler hops instead of the
/// production 500 ms — the poll's own timing is not what any of these tests are about.
struct FakeClipboardEnvironment {
    let pasteboard = FakePasteboard()
    let frontmost = FakeFrontmostApplicationProvider()
    let trust = FakeAccessibilityTrust()
    let copyKeystroke = FakeCopyKeystroke()
    let axSource = FakeAXSourceReader()
    var ownBundleIdentifier: String? = "com.nanoteams.app"

    func make() -> ClipboardCaptureEnvironment {
        ClipboardCaptureEnvironment(
            pasteboard: pasteboard,
            frontmost: frontmost,
            trust: trust,
            copyKeystroke: copyKeystroke,
            axSource: axSource,
            ownBundleIdentifier: ownBundleIdentifier,
            maxPollAttempts: 10,
            pollIntervalMilliseconds: 0)
    }

    /// Wires the ⌘C to publish `text` (and/or `fileURLs`) on the fake pasteboard.
    func armCopy(text: String? = nil, fileURLs: [URL] = []) {
        let board = pasteboard
        copyKeystroke.onCopy = { board.simulateExternalCopy(text: text, fileURLs: fileURLs) }
    }

    /// Wires the ⌘C to bump the change count with nothing readable — the image case.
    func armUnreadableCopy() {
        let board = pasteboard
        copyKeystroke.onCopy = { board.simulateUnreadableCopy() }
    }
}
