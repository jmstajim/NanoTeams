import XCTest

@testable import NanoTeams

/// Wave 8 — the tail that had to be PROBED before it could be written.
///
/// At 97.5% unexcluded, what is left is mostly guard arms, and the useful question about a guard
/// arm stops being "how do I reach it" and becomes "can it be reached at all". This file holds
/// the answers, including the negative ones: a branch measured to be unenterable is recorded as
/// such rather than left looking like a test somebody was too lazy to write.
final class ReachabilityProbedTailCoverageTests: XCTestCase {

    // MARK: - A guard that cannot fire

    /// `WorkFolderContextBuilder.buildInput` opens with
    /// `guard let enumerator = fileManager.enumerator(at:…) else { return <empty input> }`, and
    /// that `else` is dead **against `FileManager.default`**: measured on macOS 26,
    /// `enumerator(at:)` returns a NON-nil enumerator for a path that is a regular file AND for
    /// one that does not exist. It reports failure by yielding nothing, not by returning nil.
    ///
    /// Wave 11 addendum: "dead" is a claim about the DEFAULT, not about the arm. `buildInput`
    /// takes a `fileManager:` seam, and an injected one may return nil — see
    /// `testBuildInput_injectedFileManagerReturningNil_takesTheEmptyInputArm` below, which enters
    /// the arm and checks that the hand-written empty value it returns still agrees with the one
    /// the normal exit produces. Both halves are kept in one file on purpose: the reader who
    /// arrives at "the guard is dead" needs the next sentence in the same breath.
    ///
    /// This is a characterization of the platform, not of a choice we made — so it is pinned
    /// rather than "fixed". Two things follow, and both are why it is worth a test:
    ///
    /// 1. The empty result the guard was written to produce is produced anyway, by the loop never
    ///    iterating. Behaviour is identical, which is why nothing has ever noticed.
    /// 2. The guard's comment used to imply the nil case is how a bad root is handled. It is not.
    ///    Anyone who deletes the guard as dead code is right about the branch and wrong about the
    ///    outcome, and this test tells them the outcome is unchanged.
    ///
    /// CHOICE: Foundation could reasonably have signalled an unopenable root either way — nil, or
    /// an enumerator that yields nothing. It picked the second. Neither is a defect; the
    /// alternative would have been for us to stat the root first and report a distinct error, and
    /// this project deliberately treats "no files" and "no such folder" the same at this layer
    /// (the folder picker has already validated it).
    /// FIXTURE: a regular file and a nonexistent path, both handed in as `workFolderRoot`.
    ///
    /// RED: none against production — this pins a platform behaviour the code depends on. If a
    /// future Foundation returns nil, this test fails and the guard becomes live again, which is
    /// exactly the signal wanted.
    func testCharacterization_enumeratorIsNonNilEvenForABadRoot() throws {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("nt-enum-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let regularFile = tmp.appendingPathComponent("plain.txt", isDirectory: false)
        try Data("x".utf8).write(to: regularFile)
        let missing = tmp.appendingPathComponent("no-such-dir", isDirectory: true)

        for root in [regularFile, missing] {
            XCTAssertNotNil(
                fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
                """
                enumerator(at:) returned nil for \(root.lastPathComponent). If this now fails, the \
                `guard let enumerator` arm in WorkFolderContextBuilder.buildInput is LIVE again — \
                re-read its comment before touching it.
                """)
        }

        // And the outcome the dead guard was written to produce happens regardless.
        for root in [regularFile, missing] {
            let input = WorkFolderContextBuilder.buildInput(workFolderRoot: root)
            XCTAssertEqual(input.rootName, root.lastPathComponent)
            XCTAssertTrue(input.fileList.isEmpty, "a bad root must yield no files, by either route")
            XCTAssertTrue(input.excerpts.isEmpty)
        }
    }

    // MARK: - The parser's mid-chunk tag window

    /// `ThinkTagSplitter` — the `<think>` router `OllamaChatStreamParser` feeds — recognises the
    /// opening tag only BEFORE any real content, and re-checks that at the top of every loop pass
    /// rather than once at `feed()` entry. The re-check is what makes the parser's answer
    /// independent of how a server or proxy frames its deltas.
    ///
    /// The already-covered case is the split one (prose in chunk 1, tag in chunk 2). The arm this
    /// test reaches is the coalesced one — both in a SINGLE buffered chunk — which is the shape a
    /// proxy produces and which, if the window were only checked at entry, would silently reroute
    /// a literal `<think>` in prose into the thinking channel. For a Harmony envelope that means
    /// splitting a tool call across two channels mid-JSON.
    ///
    /// RED: move the `if !inThink && hasEmittedContent` check out of the loop and up to `feed()`
    /// entry → the coalesced case routes `<think>later</think>` into `thinking` and this fails.
    func testParser_contentThenTagInOneChunk_keepsTheTagAsContent() {
        var parser = ThinkTagSplitter()

        let coalesced = parser.feed("prose first <think>later</think> tail")
        let flushed = parser.flush()
        let content = coalesced.content + flushed.content
        let thinking = coalesced.thinking + flushed.thinking

        XCTAssertTrue(thinking.isEmpty,
                      "a tag after real content is literal text, not reasoning — got \(thinking.debugDescription)")
        XCTAssertTrue(content.contains("<think>later</think>"),
                      "the literal tag must survive verbatim in content — got \(content.debugDescription)")
    }

    /// The same bytes split across chunk boundaries must give the same answer. Run beside the
    /// coalesced case on purpose: separately, each passes for its own reason and neither shows
    /// that the two agree, which is the actual contract.
    ///
    /// RED: same mutation — the split case keeps working while the coalesced one diverges, so
    /// only the pair catches it.
    func testParser_sameBytesSplitAcrossChunks_agreeWithTheCoalescedResult() {
        let whole = "prose first <think>later</think> tail"

        var coalescedParser = ThinkTagSplitter()
        let a = coalescedParser.feed(whole)
        let aFlush = coalescedParser.flush()

        var splitParser = ThinkTagSplitter()
        var splitContent = "", splitThinking = ""
        for ch in whole {
            let out = splitParser.feed(String(ch))
            splitContent += out.content; splitThinking += out.thinking
        }
        let bFlush = splitParser.flush()
        splitContent += bFlush.content; splitThinking += bFlush.thinking

        XCTAssertEqual(splitContent, a.content + aFlush.content,
                       "framing changed the content the model sees")
        XCTAssertEqual(splitThinking, a.thinking + aFlush.thinking,
                       "framing changed which channel the bytes landed in")
    }

    /// A leading `<think>` — the only position where the tag is real — still routes to thinking
    /// after the loop-top re-check. Without this, the fix for the case above could pass by
    /// disabling tag recognition altogether.
    ///
    /// RED: make the loop-top check unconditional (drop `hasEmittedContent`) → this fails.
    func testParser_leadingTag_stillRoutesToThinking() {
        var parser = ThinkTagSplitter()
        let out = parser.feed("<think>reasoning</think>answer")
        let flushed = parser.flush()

        XCTAssertEqual(out.thinking + flushed.thinking, "reasoning")
        XCTAssertEqual(out.content + flushed.content, "answer")
    }

    // MARK: - SupervisorFeedback's identity

    /// `SupervisorFeedback` is `Hashable` by `id` alone, and its `hash(into:)` had never run —
    /// nothing in the app puts one in a `Set` or uses it as a dictionary key today.
    ///
    /// It is worth pinning rather than deleting because the conformance is what makes the type
    /// safe to collect: two feedbacks for the same role at the same instant, differing only in
    /// comment, must stay DISTINCT (different `id`), while the same record re-read from disk must
    /// collapse. A conformance derived from all stored properties would get the second wrong the
    /// moment `comment` is edited.
    ///
    /// RED: change `hash(into:)` to combine `roleID` instead of `id` → the distinct-ids assertion
    /// still passes but `==`/hash agreement breaks for the same-role pair, and the Set count is 1.
    func testSupervisorFeedback_hashesByIdentityNotContent() {
        let sharedID = UUID()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)

        let original = AcceptanceService.SupervisorFeedback(
            id: sharedID, createdAt: stamp, roleID: "engineer", decision: .accepted, comment: "ship it")
        let sameRecordEditedComment = AcceptanceService.SupervisorFeedback(
            id: sharedID, createdAt: stamp, roleID: "engineer", decision: .accepted, comment: "ship it now")
        let differentRecordSameRole = AcceptanceService.SupervisorFeedback(
            id: UUID(), createdAt: stamp, roleID: "engineer", decision: .accepted, comment: "ship it")

        XCTAssertEqual(original, sameRecordEditedComment, "identity is the id, not the content")
        XCTAssertEqual(original.hashValue, sameRecordEditedComment.hashValue,
                       "equal values must hash equally or Set/Dictionary break")
        XCTAssertNotEqual(original, differentRecordSameRole,
                          "two feedbacks for one role are two records")

        let collected: Set = [original, sameRecordEditedComment, differentRecordSameRole]
        XCTAssertEqual(collected.count, 2,
                       "the edited copy must collapse onto the original; the sibling must not")
    }

    // MARK: - Wave 11 — the guard only an injected FileManager can fire

    /// A nil-returning `FileManager` for `buildInput`'s injected seam.
    ///
    /// The overridable entry point is NOT the Swift-facing
    /// `enumerator(at:includingPropertiesForKeys:options:)`. That one is `@nonobjc` and declared in
    /// an extension of `FileManager`, so an override fails to compile — the same shape as the
    /// `replaceItemAt` finding (CLAUDE.md 2026-08-08). What does work is overriding the `open`
    /// ObjC-imported `__enumerator(...)` the wrapper forwards to: dispatch is dynamic, so the
    /// production call site lands here.
    ///
    /// If a future SDK renames or hides `__enumerator`, this stops COMPILING. That is the right
    /// failure mode — loud, and at the seam — rather than a test that quietly stops covering the arm.
    private final class NilEnumeratorFileManager: FileManager {
        private(set) var enumeratorCalls = 0

        override func __enumerator(
            at url: URL,
            includingPropertiesForKeys keys: [URLResourceKey]?,
            options mask: FileManager.DirectoryEnumerationOptions = [],
            errorHandler handler: ((URL, any Error) -> Bool)? = nil
        ) -> FileManager.DirectoryEnumerator? {
            enumeratorCalls += 1
            return nil
        }
    }

    /// The arm the characterization above measures dead against `FileManager.default`, entered
    /// through the `fileManager:` parameter that exists for exactly this and that nothing had ever
    /// injected.
    ///
    /// Worth covering beyond its six lines: it is the only place that decides what an unenumerable
    /// root returns, and the empty value it builds is written out BY HAND rather than shared with
    /// the normal exit. An edit to the normal return — a new field, a different `rootName`
    /// derivation — would leave this copy behind, and nothing else executes it.
    ///
    /// The fixture directory is deliberately NON-empty. That is the anti-vacuum guard: should the
    /// override ever stop being consulted, the real enumerator walks two files and both assertions
    /// fail, rather than the test passing for the wrong reason.
    ///
    /// RED: change `fileManager.enumerator(at:…)` in `buildInput` to
    /// `FileManager.default.enumerator(at:…)`, i.e. ignore the injected seam → the real enumerator
    /// walks the fixture, `fileList` comes back with two entries and `enumeratorCalls` is 0.
    func testBuildInput_injectedFileManagerReturningNil_takesTheEmptyInputArm() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("nt-nilenum-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data("# readme".utf8).write(to: root.appendingPathComponent("README.md"))
        try Data("import Foundation".utf8).write(to: root.appendingPathComponent("a.swift"))

        let stub = NilEnumeratorFileManager()
        let input = WorkFolderContextBuilder.buildInput(workFolderRoot: root, fileManager: stub)

        XCTAssertEqual(stub.enumeratorCalls, 1,
                       """
                       the injected FileManager was never consulted, so buildInput is not routing \
                       through its `fileManager:` parameter and this test proves nothing about the \
                       guard arm it claims to cover
                       """)
        XCTAssertTrue(input.fileList.isEmpty,
                      "the guard's else arm must return an EMPTY file list; got \(input.fileList)")
        XCTAssertTrue(input.fileTypeCounts.isEmpty)
        XCTAssertTrue(input.excerpts.isEmpty)
        XCTAssertEqual(input.rootName, root.lastPathComponent,
                       "the arm still has to name the root — it is the one field it does not zero")
    }

    /// The claim the characterization above makes in prose — "the empty result the guard was
    /// written to produce is produced anyway, by the loop never iterating" — had never been
    /// checked, because until the stub above existed there was no way to obtain the guard's result
    /// at all. Both routes must agree on every field except the root name.
    ///
    /// RED: same mutation — dropping the injected seam makes the guarded route return the real
    /// walk's file while the empty-walk route stays empty, and the first equality fails.
    func testBuildInput_guardArmAndEmptyWalk_agreeOnEveryFieldButRootName() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("nt-nilenum-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data("# readme".utf8).write(to: root.appendingPathComponent("README.md"))

        let viaGuard = WorkFolderContextBuilder.buildInput(
            workFolderRoot: root, fileManager: NilEnumeratorFileManager())
        let viaEmptyWalk = WorkFolderContextBuilder.buildInput(
            workFolderRoot: root.appendingPathComponent("no-such-dir", isDirectory: true))

        XCTAssertEqual(viaGuard.fileList, viaEmptyWalk.fileList,
                       "the two routes to an empty result must not disagree")
        XCTAssertEqual(viaGuard.fileTypeCounts, viaEmptyWalk.fileTypeCounts)
        XCTAssertEqual(viaGuard.excerpts.count, viaEmptyWalk.excerpts.count)
        XCTAssertNotEqual(viaGuard.rootName, viaEmptyWalk.rootName,
                          "the fixtures are supposed to carry different roots — if these match, "
                              + "the comparison above no longer distinguishes the two routes")
    }

    /// `decodeUTF8TrimmingPartialTail` drops up to three trailing bytes to rescue an excerpt whose
    /// read window fell inside a multi-byte codepoint. Its final `return nil` — budget exhausted,
    /// because the bytes were never UTF-8 to begin with — is the one line of the file's read path
    /// nothing executed: the suite covers the empty read, the whitespace-only read, and both
    /// successful rescues, but never a text-extension file that simply is not text.
    ///
    /// That case is ordinary rather than exotic. Any `.txt` / `.md` / `.json` holding Latin-1,
    /// UTF-16 or a mislabelled binary reaches it, and the contract it enforces is that such a file
    /// stays LISTED — it is a real file the model may want to know exists — while contributing no
    /// excerpt. Substituting a lossy decode would ship U+FFFD mojibake into the work-folder context
    /// prompt, where it costs tokens and teaches the model nothing.
    ///
    /// Fixture measured, not guessed: five 0xFF bytes stay undecodable after dropping one, two and
    /// three trailing bytes, so the loop runs to exhaustion instead of short-circuiting on a lucky
    /// prefix.
    ///
    /// RED: replace the final `return nil` with `return String(decoding: data, as: UTF8.self)` —
    /// the lossy decode — → `binary.txt` gains an excerpt of replacement characters and the third
    /// assertion fails.
    func testBuildInput_undecodableTextFile_isListedButYieldsNoExcerpt() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("nt-badutf8-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
            .write(to: root.appendingPathComponent("binary.txt"))
        try Data("readable".utf8).write(to: root.appendingPathComponent("good.txt"))

        let input = WorkFolderContextBuilder.buildInput(workFolderRoot: root)

        XCTAssertTrue(input.fileList.contains("binary.txt"),
                      "an unreadable file is still a file — it must stay in the listing")
        XCTAssertEqual(input.fileTypeCounts["txt"], 2,
                       "the type census counts files, not readable ones")
        XCTAssertFalse(
            input.excerpts.contains { $0.path == "binary.txt" },
            "non-UTF-8 bytes must yield no excerpt rather than mojibake")
        XCTAssertTrue(input.excerpts.contains { $0.path == "good.txt" },
                      "anti-vacuum: excerpting has to be working at all, or the assertion above "
                          + "passes for the wrong reason")
    }
}
