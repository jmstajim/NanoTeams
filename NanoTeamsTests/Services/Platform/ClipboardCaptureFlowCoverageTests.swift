import AppKit
import XCTest

@testable import NanoTeams

/// `ClipboardCaptureService.captureSelection` end-to-end, against the `ClipboardCaptureEnvironment`
/// seam. Nothing here posts a real ⌘C or touches `NSPasteboard.general`.
///
/// This is the file the coverage programme was aiming at: **whether the user's clipboard survives
/// ⌃⌥⌘K** is the single most damaging thing in this codebase that nothing could assert. The
/// snapshot/restore pair had zero coverage, and it shipped two ways of destroying a clipboard.
///
/// The pure arithmetic around it (`lineRange`, `documentURL`, `enrichText`, `SourceContext.parse`)
/// was already extracted and is covered by `ClipboardCaptureServiceCoverageTests`; this file is
/// about the orchestration those pieces hang off.
final class ClipboardCaptureFlowCoverageTests: XCTestCase {

    // MARK: - Restore: the two ways a capture destroyed the clipboard

    /// **Defect.** ⌘C on an image (or on anything published only under a private pasteboard type)
    /// bumps the change count while yielding neither a string nor file URLs, so the poll gives up
    /// and returns nil — and the restore used to live INSIDE `if let captured`. The user's clipboard
    /// was then left holding the source app's payload, with their original gone, from a keystroke
    /// they never pressed.
    ///
    /// Restore is therefore keyed on "did the pasteboard change", not on "did we get something
    /// usable". Those are different questions and only the first one is about the clipboard.
    ///
    /// RED: move `applyRestore` back inside the captured branch → `clearCount == 0`, `writes == []`,
    /// and the fake board still holds the unreadable copy.
    func testCapture_unreadableCopy_stillRestoresTheUsersClipboard() async {
        let env = FakeClipboardEnvironment()
        let original = FakePasteboard.item("the user's original clipboard")
        env.pasteboard.snapshot = [original]
        env.armUnreadableCopy()

        let result = await ClipboardCaptureService.captureSelection(environment: env.make())

        XCTAssertNil(result.text, "sanity: the copy published nothing readable")
        XCTAssertEqual(
            env.pasteboard.writes, [[original]],
            "a ⌘C that changed the pasteboard MUST be undone even when we could not read what it "
                + "produced — otherwise copying an image silently eats the clipboard")
        XCTAssertEqual(env.pasteboard.clearCount, 1)
        XCTAssertFalse(result.restoreFailed)
    }

    /// **Defect.** `restorePasteboard` called `clearContents()` BEFORE its `guard !previous.isEmpty`,
    /// and an unreadable pasteboard (`NSPasteboard.pasteboardItems == nil`) snapshotted as `[]` —
    /// identical to a genuinely empty one. So "we failed to record your clipboard" and "your
    /// clipboard was empty" produced the same, destructive, restore.
    ///
    /// RED: make `snapshotItems()` non-optional again (nil → `[]`) → `clearCount == 1` and the
    /// content we never managed to record is gone.
    func testCapture_unreadableSnapshot_leavesTheClipboardAlone() async {
        let env = FakeClipboardEnvironment()
        env.pasteboard.snapshot = nil   // NSPasteboard.pasteboardItems returned nil
        env.armCopy(text: "selection")

        let result = await ClipboardCaptureService.captureSelection(environment: env.make())

        XCTAssertEqual(result.text, "selection", "the capture itself still succeeds")
        XCTAssertEqual(
            env.pasteboard.clearCount, 0,
            "clearing a clipboard we failed to snapshot destroys content we merely could not read; "
                + "leaving the capture on the board is visible and recoverable")
        XCTAssertTrue(env.pasteboard.writes.isEmpty)
        XCTAssertFalse(
            result.restoreFailed,
            "'nothing to put back' is not a restore FAILURE — reporting it would cry wolf on every "
                + "capture taken while another process owns the pasteboard")
    }

    /// The case the old code got right, and the reason `.rewrite([])` is a distinct state from
    /// `.cannotRestore`: an empty clipboard is faithfully restored by clearing.
    ///
    /// RED: fold `.rewrite([])` into `.cannotRestore` → the capture stays on the board and the user
    /// gets content they never copied.
    func testCapture_genuinelyEmptyClipboard_isRestoredByClearing() async {
        let env = FakeClipboardEnvironment()
        env.pasteboard.snapshot = []    // read successfully; there was nothing on it
        env.armCopy(text: "selection")

        _ = await ClipboardCaptureService.captureSelection(environment: env.make())

        XCTAssertEqual(env.pasteboard.clearCount, 1, "restoring 'empty' means clearing")
        XCTAssertTrue(env.pasteboard.writes.isEmpty, "there is nothing to write back")
    }

    /// No change means nothing of ours is on the board. Writing anyway would clobber whatever
    /// another process put there while we were polling.
    ///
    /// RED: drop the `pasteboardChanged` guard in `restoreAction` → `clearCount == 1` on a ⌘C that
    /// did nothing at all.
    func testCapture_pasteboardNeverChanged_isNotTouched() async {
        let env = FakeClipboardEnvironment()
        env.pasteboard.snapshot = [FakePasteboard.item("someone else's clipboard")]
        // No armCopy: the ⌘C lands somewhere that ignores it.

        let result = await ClipboardCaptureService.captureSelection(environment: env.make())

        XCTAssertNil(result.text)
        XCTAssertEqual(env.pasteboard.clearCount, 0)
        XCTAssertTrue(env.pasteboard.writes.isEmpty)
        XCTAssertFalse(result.restoreFailed)
    }

    /// A refused write leaves the clipboard EMPTY (we cleared first), which is exactly the harm this
    /// wave is about — so it must not be silent. The `@discardableResult` on `NSPasteboard`'s
    /// `writeObjects` is what let it be.
    ///
    /// RED: ignore `pasteboard.write`'s return value → `restoreFailed == false` and the user finds
    /// out at their next ⌘V.
    func testCapture_restoreWriteRefused_isReported() async {
        let env = FakeClipboardEnvironment()
        env.pasteboard.snapshot = [FakePasteboard.item("original")]
        env.pasteboard.writeSucceeds = false
        env.armCopy(text: "selection")

        let result = await ClipboardCaptureService.captureSelection(environment: env.make())

        XCTAssertEqual(result.text, "selection")
        XCTAssertTrue(
            result.restoreFailed,
            "the clipboard is now empty and only this flag can say so")
    }

    func testCapture_restoreWriteRefused_onAnUnreadableCopy_isAlsoReported() async {
        let env = FakeClipboardEnvironment()
        env.pasteboard.snapshot = [FakePasteboard.item("original")]
        env.pasteboard.writeSucceeds = false
        env.armUnreadableCopy()

        let result = await ClipboardCaptureService.captureSelection(environment: env.make())

        XCTAssertNil(result.text, "sanity: no usable capture")
        XCTAssertTrue(
            result.restoreFailed,
            "the failure-to-restore report must not be reachable only via the success path")
    }

    // MARK: - Gates before the keystroke

    /// RED: drop the `trust.isTrusted` guard → a ⌘C is posted into the frontmost app with no
    /// Accessibility permission, and the pasteboard is snapshotted for nothing.
    func testCapture_withoutAccessibilityTrust_doesNothingAtAll() async {
        let env = FakeClipboardEnvironment()
        env.trust.isTrusted = false

        let result = await ClipboardCaptureService.captureSelection(environment: env.make())

        XCTAssertNil(result.text)
        XCTAssertEqual(env.copyKeystroke.copies, 0, "no keystroke is synthesized")
        XCTAssertEqual(env.pasteboard.snapshotReads, 0, "the pasteboard is not even read")
        XCTAssertEqual(env.frontmost.reads, 0)
    }

    /// The user just clicked NanoTeams' own sidebar: ⌘C would copy nothing and we would burn the
    /// full poll budget waiting for it.
    ///
    /// RED: drop the self-bail → `copies == 1` and 10 poll attempts against an unchanged board.
    func testCapture_whenWeAreFrontmost_bailsBeforeTouchingAnything() async {
        var fixture = FakeClipboardEnvironment()
        fixture.ownBundleIdentifier = "com.nanoteams.app"
        fixture.frontmost.app = FrontmostApplication(
            bundleIdentifier: "com.nanoteams.app", processIdentifier: 99)

        let result = await ClipboardCaptureService.captureSelection(environment: fixture.make())

        XCTAssertNil(result.text)
        XCTAssertEqual(fixture.copyKeystroke.copies, 0)
        XCTAssertEqual(
            fixture.pasteboard.snapshotReads, 0,
            "bailing before the snapshot keeps the no-op free")
    }

    /// The bail is `if let frontApp, ... == ours`, not a `guard let` — with NO frontmost app at all
    /// (login window, Mission Control) the capture still proceeds, because the source app may
    /// simply not be reporting. Losing that would silently disable ⌃⌥⌘K in those moments.
    ///
    /// RED: rewrite the bail as `guard let frontApp else { return .empty }` → this fails.
    func testCapture_withNoFrontmostApplication_stillAttemptsTheCapture() async {
        let env = FakeClipboardEnvironment()
        env.frontmost.app = nil
        env.armCopy(text: "still captured")

        let result = await ClipboardCaptureService.captureSelection(environment: env.make())

        XCTAssertEqual(result.text, "still captured")
        XCTAssertEqual(env.copyKeystroke.copies, 1)
    }

    /// A different app being frontmost is the normal path.
    func testCapture_whenAnotherAppIsFrontmost_proceeds() async {
        let env = FakeClipboardEnvironment()
        env.armCopy(text: "from the editor")

        let result = await ClipboardCaptureService.captureSelection(environment: env.make())

        XCTAssertEqual(result.text, "from the editor")
        XCTAssertEqual(env.copyKeystroke.copies, 1)
    }

    /// The frontmost app used to be read TWICE — once for the self-bail and once inside source
    /// detection — and the user can switch apps between them. The `// Source:` header would then
    /// name a document belonging to an app we never captured from.
    ///
    /// RED: re-read the frontmost app inside `detectSourceContext` → `reads == 2`.
    func testCapture_readsTheFrontmostApplicationExactlyOnce() async throws {
        let env = FakeClipboardEnvironment()
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        env.axSource.documentPath = root.appendingPathComponent("App.swift").path
        env.armCopy(text: "let x = 1")

        _ = await ClipboardCaptureService.captureSelection(
            workFolderRoot: root, environment: env.make())

        XCTAssertEqual(
            env.frontmost.reads, 1,
            "two reads of a value that changes under you is a race, not a convenience")
    }

    /// The pid threaded into source detection must be the one we decided NOT to bail on.
    func testCapture_passesTheFrontmostPidToSourceDetection() async throws {
        let env = FakeClipboardEnvironment()
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        env.frontmost.app = FrontmostApplication(bundleIdentifier: "com.example.x", processIdentifier: 777)
        env.axSource.documentPath = root.appendingPathComponent("App.swift").path
        env.armCopy(text: "body")

        _ = await ClipboardCaptureService.captureSelection(
            workFolderRoot: root, environment: env.make())

        XCTAssertEqual(env.axSource.documentPathRequests, [777])
    }

    // MARK: - Enrichment gating

    func testCapture_textInsideWorkFolder_isEnrichedWithASourceHeader() async throws {
        let env = FakeClipboardEnvironment()
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        env.axSource.documentPath = root.appendingPathComponent("Sources/App.swift").path
        env.axSource.selection = AXSelection(
            range: AXTextRange(location: 0, length: 5), text: "a\nb\nc\nd")
        env.armCopy(text: "a\nb")

        let result = await ClipboardCaptureService.captureSelection(
            workFolderRoot: root, environment: env.make())

        let parsed = try XCTUnwrap(SourceContext.parse(XCTUnwrap(result.text)))
        XCTAssertEqual(parsed.source, "Sources/App.swift:1-3")
        XCTAssertEqual(parsed.body, "a\nb")
    }

    /// RED: drop the `let root = workFolderRoot` condition → the AX tree is queried on every
    /// capture, including in default-storage mode where there is no project to relativize against.
    func testCapture_withNoWorkFolderRoot_neverQueriesAccessibility() async {
        let env = FakeClipboardEnvironment()
        env.axSource.documentPath = "/tmp/whatever.swift"
        env.armCopy(text: "plain")

        let result = await ClipboardCaptureService.captureSelection(
            workFolderRoot: nil, environment: env.make())

        XCTAssertEqual(result.text, "plain", "no header")
        XCTAssertTrue(env.axSource.documentPathRequests.isEmpty)
    }

    /// An empty captured string is returned but never enriched — a `// Source:` header on nothing
    /// is a reference to no code.
    func testCapture_emptyText_isNotEnriched() async throws {
        let env = FakeClipboardEnvironment()
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        env.axSource.documentPath = root.appendingPathComponent("App.swift").path
        env.armCopy(text: "")

        let result = await ClipboardCaptureService.captureSelection(
            workFolderRoot: root, environment: env.make())

        XCTAssertEqual(result.text, "")
        XCTAssertNil(SourceContext.parse(""), "sanity")
    }

    /// Files (a Finder selection) carry no text to enrich, and must survive the enrichment branch
    /// untouched.
    func testCapture_fileURLsOnly_areReturnedUnenriched() async throws {
        let env = FakeClipboardEnvironment()
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        env.axSource.documentPath = root.appendingPathComponent("App.swift").path
        let picked = URL(fileURLWithPath: "/tmp/picked.png")
        env.armCopy(fileURLs: [picked])

        let result = await ClipboardCaptureService.captureSelection(
            workFolderRoot: root, environment: env.make())

        XCTAssertNil(result.text)
        XCTAssertEqual(result.fileURLs, [picked])
    }

    // MARK: - requestAccessibilityIfNeeded

    /// RED: drop the `!isTrusted` guard → the TCC dialog is raised on every ⌃⌥⌘K, forever.
    func testRequestAccessibility_whenAlreadyTrusted_doesNotPrompt() {
        let env = FakeClipboardEnvironment()
        env.trust.isTrusted = true

        ClipboardCaptureService.requestAccessibilityIfNeeded(environment: env.make())

        XCTAssertEqual(env.trust.promptCount, 0)
    }

    func testRequestAccessibility_whenUntrusted_prompts() {
        let env = FakeClipboardEnvironment()
        env.trust.isTrusted = false

        ClipboardCaptureService.requestAccessibilityIfNeeded(environment: env.make())

        XCTAssertEqual(env.trust.promptCount, 1)
    }

    // MARK: - detectSourceContext

    /// **The ordering is the contract.** `focusedSelection` pulls the focused element's ENTIRE text
    /// across a process boundary; for a file outside the work folder that answer is discarded, so
    /// asking for it is pure cost paid on every ⌃⌥⌘K in an unrelated app.
    ///
    /// RED: move the `isWithin` check below the selection read → `selectionRequests` is non-empty.
    func testDetectSourceContext_fileOutsideWorkFolder_neverReadsTheSelection() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let ax = FakeAXSourceReader(
            documentPath: "/somewhere/else/Other.swift",
            selection: AXSelection(range: AXTextRange(location: 0, length: 9), text: "irrelevant"))

        let ctx = ClipboardCaptureService.detectSourceContext(pid: 1, workFolderRoot: root, ax: ax)

        XCTAssertNil(ctx)
        XCTAssertTrue(
            ax.selectionRequests.isEmpty,
            "the cheap path check exists precisely so the expensive read is skipped")
    }

    /// A zero-length range is a caret, not a selection. The file is still worth naming; claiming
    /// "lines 12-12" would attach a range the clip does not have.
    ///
    /// RED: drop `selection.range.length > 0` → lineStart/lineEnd become 1/1.
    func testDetectSourceContext_caretWithNoSelection_keepsThePathAndDropsTheLines() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("App.swift").path
        let ax = FakeAXSourceReader(
            documentPath: path,
            selection: AXSelection(range: AXTextRange(location: 12, length: 0), text: "a\nb\nc"))

        let ctx = try XCTUnwrap(
            ClipboardCaptureService.detectSourceContext(pid: 1, workFolderRoot: root, ax: ax))

        XCTAssertEqual(ctx.filePath, path)
        XCTAssertNil(ctx.lineStart)
        XCTAssertNil(ctx.lineEnd)
    }

    /// No selection reported at all behaves the same as a caret.
    func testDetectSourceContext_noSelection_keepsThePath() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("App.swift").path
        let ax = FakeAXSourceReader(documentPath: path, selection: nil)

        let ctx = try XCTUnwrap(
            ClipboardCaptureService.detectSourceContext(pid: 1, workFolderRoot: root, ax: ax))

        XCTAssertEqual(ctx.filePath, path)
        XCTAssertNil(ctx.lineStart)
    }

    func testDetectSourceContext_noFocusedDocument_returnsNil() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let ax = FakeAXSourceReader(documentPath: nil)

        XCTAssertNil(ClipboardCaptureService.detectSourceContext(pid: 1, workFolderRoot: root, ax: ax))
        XCTAssertTrue(ax.selectionRequests.isEmpty)
    }

    /// Editors that report a `file://` URL and editors that report a bare POSIX path must both
    /// work — the bare-path fallback exists because dropping it silently disabled enrichment for a
    /// whole editor with no signal anywhere.
    func testDetectSourceContext_acceptsBothFileURLAndBarePathDocuments() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("App.swift").path

        for raw in [path, URL(fileURLWithPath: path).absoluteString] {
            let ax = FakeAXSourceReader(documentPath: raw)
            let ctx = ClipboardCaptureService.detectSourceContext(pid: 1, workFolderRoot: root, ax: ax)
            XCTAssertEqual(ctx?.filePath, path, "document attribute \(raw)")
        }
    }

    /// A relative document string is not a path — turning it into one would resolve it against the
    /// process's current directory.
    func testDetectSourceContext_relativeDocumentString_returnsNil() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let ax = FakeAXSourceReader(documentPath: "App.swift")

        XCTAssertNil(ClipboardCaptureService.detectSourceContext(pid: 1, workFolderRoot: root, ax: ax))
    }

    func testDetectSourceContext_selectionSpanningLines_reportsTheRange() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("App.swift").path
        let ax = FakeAXSourceReader(
            documentPath: path,
            selection: AXSelection(range: AXTextRange(location: 2, length: 4), text: "a\nb\nc\nd"))

        let ctx = try XCTUnwrap(
            ClipboardCaptureService.detectSourceContext(pid: 1, workFolderRoot: root, ax: ax))

        XCTAssertEqual(ctx.lineStart, 2)
        XCTAssertEqual(ctx.lineEnd, 4)
    }

    // MARK: - The poll

    /// An app using `NSPasteboardItemDataProvider` declares its types (bumping the change count) and
    /// fills the data lazily, so the first tick after the bump legitimately reads empty. Bailing
    /// there would drop those captures entirely.
    ///
    /// RED: change the `continue` to `return nil` → the late text is never seen.
    func testPoll_changeWithNothingReadableYet_keepsPolling() async {
        let late = LateFillingPasteboard(previousChangeCount: 5, fillAfterReads: 3, text: "late")

        let result = await ClipboardCaptureService.pollPasteboardCapture(
            pasteboard: late, previousChangeCount: 5, maxAttempts: 10, intervalMilliseconds: 0)

        XCTAssertEqual(result?.text, "late")
        XCTAssertEqual(late.stringReads, 3, "two empty ticks were survived, not bailed on")
    }

    /// **CHOICE:** a non-nil but EMPTY string counts as a capture. The alternatives are to treat it
    /// as "nothing published" (and keep polling until the budget runs out) or to fold the judgement
    /// in here. It is the source app's own answer — "the selection is empty" — and
    /// `ClipboardStagingPolicy` is the layer that decides an empty clip is not worth staging;
    /// deciding it here would erase the difference between "published nothing" and "published
    /// emptiness", and burn 500 ms doing it.
    /// FIXTURE: a board whose ⌘C publishes `""`.
    func testCharacterization_pollTreatsAnEmptyStringAsACapture() async {
        let board = FakePasteboard()
        board.changeCount = 1
        board.simulateExternalCopy(text: "")

        let result = await ClipboardCaptureService.pollPasteboardCapture(
            pasteboard: board, previousChangeCount: 1, maxAttempts: 3, intervalMilliseconds: 0)

        XCTAssertEqual(result?.text, "")
    }

    func testPoll_fileURLsWithNoText_isACapture() async {
        let board = FakePasteboard()
        board.changeCount = 1
        board.simulateExternalCopy(fileURLs: [URL(fileURLWithPath: "/tmp/a.txt")])

        let result = await ClipboardCaptureService.pollPasteboardCapture(
            pasteboard: board, previousChangeCount: 1, maxAttempts: 3, intervalMilliseconds: 0)

        XCTAssertEqual(result?.fileURLs.count, 1)
        XCTAssertNil(result?.text)
    }

    func testPoll_noChangeWithinBudget_returnsNil() async {
        let board = FakePasteboard()
        board.changeCount = 7

        let result = await ClipboardCaptureService.pollPasteboardCapture(
            pasteboard: board, previousChangeCount: 7, maxAttempts: 4, intervalMilliseconds: 0)

        XCTAssertNil(result)
    }

    func testPoll_changeThatNeverBecomesReadable_returnsNilAfterTheBudget() async {
        let board = FakePasteboard()
        board.changeCount = 1
        board.simulateUnreadableCopy()

        let result = await ClipboardCaptureService.pollPasteboardCapture(
            pasteboard: board, previousChangeCount: 1, maxAttempts: 3, intervalMilliseconds: 0)

        XCTAssertNil(result)
    }

    /// A zero-attempt budget must not read the board at all — the loop bound is the budget.
    func testPoll_zeroAttempts_returnsNilImmediately() async {
        let board = FakePasteboard()
        board.changeCount = 1
        board.simulateExternalCopy(text: "x")

        let result = await ClipboardCaptureService.pollPasteboardCapture(
            pasteboard: board, previousChangeCount: 1, maxAttempts: 0, intervalMilliseconds: 0)

        XCTAssertNil(result)
    }

    // MARK: - The restore decision, directly

    func testRestoreAction_truthTable() {
        typealias Action = ClipboardCaptureService.PasteboardRestoreAction
        let items = [FakePasteboard.item("a")]

        XCTAssertEqual(
            ClipboardCaptureService.restoreAction(snapshot: items, pasteboardChanged: false),
            Action.leaveAlone)
        XCTAssertEqual(
            ClipboardCaptureService.restoreAction(snapshot: nil, pasteboardChanged: false),
            Action.leaveAlone,
            "an unchanged board is left alone whether or not we managed to snapshot it")
        XCTAssertEqual(
            ClipboardCaptureService.restoreAction(snapshot: nil, pasteboardChanged: true),
            Action.cannotRestore)
        XCTAssertEqual(
            ClipboardCaptureService.restoreAction(snapshot: [], pasteboardChanged: true),
            Action.rewrite([]))
        XCTAssertEqual(
            ClipboardCaptureService.restoreAction(snapshot: items, pasteboardChanged: true),
            Action.rewrite(items))
    }

    func testApplyRestore_leaveAloneAndCannotRestore_touchNothingAndReportSuccess() {
        for action in [ClipboardCaptureService.PasteboardRestoreAction.leaveAlone, .cannotRestore] {
            let board = FakePasteboard()
            XCTAssertTrue(ClipboardCaptureService.applyRestore(action, to: board), "\(action)")
            XCTAssertEqual(board.clearCount, 0, "\(action)")
            XCTAssertTrue(board.writes.isEmpty, "\(action)")
        }
    }

    func testApplyRestore_rewriteEmpty_clearsWithoutWriting() {
        let board = FakePasteboard()
        XCTAssertTrue(ClipboardCaptureService.applyRestore(.rewrite([]), to: board))
        XCTAssertEqual(board.clearCount, 1)
        XCTAssertTrue(board.writes.isEmpty)
    }

    func testApplyRestore_rewriteItems_clearsThenWrites() {
        let board = FakePasteboard()
        let items = [FakePasteboard.item("a"), FakePasteboard.item("b")]
        XCTAssertTrue(ClipboardCaptureService.applyRestore(.rewrite(items), to: board))
        XCTAssertEqual(board.clearCount, 1)
        XCTAssertEqual(board.writes, [items])
    }

    func testApplyRestore_refusedWrite_reportsFailure() {
        let board = FakePasteboard()
        board.writeSucceeds = false
        XCTAssertFalse(
            ClipboardCaptureService.applyRestore(.rewrite([FakePasteboard.item("a")]), to: board))
    }

    // MARK: - Wiring

    /// The seams default to the LIVE adapters at exactly one place, so this is the anti-vacuity
    /// check: every test above would still pass if `.system` had been quietly wired to inert fakes.
    func testSystemEnvironment_namesTheLiveAdapters() {
        let env = ClipboardCaptureEnvironment.system
        XCTAssertTrue(env.pasteboard is SystemPasteboard)
        XCTAssertTrue(env.frontmost is SystemFrontmostApplicationProvider)
        XCTAssertTrue(env.trust is SystemAccessibilityTrust)
        XCTAssertTrue(env.copyKeystroke is SystemCopyKeystroke)
        XCTAssertTrue(env.axSource is SystemAXSourceContextReader)
        XCTAssertEqual(env.ownBundleIdentifier, Bundle.main.bundleIdentifier)
        XCTAssertEqual(env.maxPollAttempts, 10)
        XCTAssertEqual(env.pollIntervalMilliseconds, 50, "10 × 50 ms = the documented 500 ms budget")
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// A board that reports a change immediately but only publishes readable content after N reads —
/// the `NSPasteboardItemDataProvider` shape the poll's `continue` exists for.
private final class LateFillingPasteboard: PasteboardAccessing, @unchecked Sendable {
    let changeCount: Int
    private let fillAfterReads: Int
    private let text: String
    private(set) var stringReads = 0

    init(previousChangeCount: Int, fillAfterReads: Int, text: String) {
        self.changeCount = previousChangeCount + 1
        self.fillAfterReads = fillAfterReads
        self.text = text
    }

    func snapshotItems() -> [PasteboardItemSnapshot]? { [] }
    func string() -> String? {
        stringReads += 1
        return stringReads >= fillAfterReads ? text : nil
    }
    func fileURLs() -> [URL] { [] }
    func clear() {}
    func write(_ items: [PasteboardItemSnapshot]) -> Bool { true }
}
