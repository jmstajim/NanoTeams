import AppKit
import XCTest

@testable import NanoTeams

/// A `NetworkSession` that replies with a scripted status, headers and body.
private struct ScriptedSession: NetworkSession, @unchecked Sendable {
    var status: Int = 200
    var headers: [String: String] = ["Content-Type": "application/json"]
    var body: Data = Data("{}".utf8)
    /// When set, the reply is a non-HTTP `URLResponse` — what a `file:` or `data:` URL, or
    /// some proxies, produce.
    var nonHTTPResponse = false

    func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url ?? URL(string: "https://example.invalid")!
        if nonHTTPResponse {
            return (body, URLResponse(url: url, mimeType: nil,
                                      expectedContentLength: body.count, textEncodingName: nil))
        }
        let response = HTTPURLResponse(url: url, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        return (body, response)
    }

    func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        throw URLError(.unsupportedURL)
    }
}

/// The tail of the Platform layer: single arms and short branches left over after the
/// larger seams in this wave. Each one is small; each one is also the only thing a user
/// sees when the operation behind it fails.
final class PlatformSmallChangeCoverageTests: XCTestCase, @unchecked Sendable {

    // MARK: - AppUpdateChecker error copy

    /// The two status codes with dedicated copy are the two that actually happen: 403 is
    /// GitHub's unauthenticated rate limit (60 requests/hour/IP, reachable by anyone
    /// behind a shared NAT) and 404 is a repository with no releases yet.
    ///
    /// RED: drop the `code == 403` special case → the message becomes "Update check failed
    /// with HTTP 403", which tells the user nothing about waiting an hour.
    func testCheckerError_rateLimitAndMissingReleasesHaveTheirOwnCopy() {
        XCTAssertEqual(AppUpdateChecker.CheckerError.badStatus(403).errorDescription,
                       "GitHub API rate limit reached. Try again in an hour.")
        XCTAssertEqual(AppUpdateChecker.CheckerError.badStatus(404).errorDescription,
                       "No releases published for this repository yet.")
        XCTAssertEqual(AppUpdateChecker.CheckerError.badStatus(500).errorDescription,
                       "Update check failed with HTTP 500.",
                       "an unexpected code must still name itself, or the log says nothing")
    }

    /// The content-type pre-check exists so a captive portal's HTML login page surfaces as
    /// "something is intercepting your requests" rather than a bare `DecodingError` about
    /// an unexpected `<`.
    ///
    /// RED: drop the interpolation of `ct` → the user cannot tell what came back instead.
    func testCheckerError_unexpectedContentTypeNamesWhatArrivedAndWhy() throws {
        let message = try XCTUnwrap(AppUpdateChecker.CheckerError
            .unexpectedContentType("text/html").errorDescription)
        XCTAssertTrue(message.contains("text/html"), message)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("captive portal")
            || message.localizedCaseInsensitiveContains("proxy"),
            "the actionable half is naming the likely cause: \(message)")
    }

    /// RED: swallow `underlying` → the message loses the only clue about which field
    /// GitHub changed.
    func testCheckerError_decodeFailureCarriesTheUnderlyingCause() throws {
        struct Underlying: LocalizedError { var errorDescription: String? { "key 'tag_name' missing" } }
        let message = try XCTUnwrap(AppUpdateChecker.CheckerError
            .decodeFailed(underlying: Underlying()).errorDescription)
        XCTAssertTrue(message.contains("key 'tag_name' missing"), message)
    }


    // MARK: - AppUpdateChecker transport arms

    /// RED: remove the `response as? HTTPURLResponse` guard → the non-HTTP reply falls
    /// through to the status check, which cannot run, and the failure surfaces as
    /// something else entirely.
    @MainActor
    func testFetchLatestRelease_nonHTTPResponse_reportsInvalidResponse() async {
        let checker = AppUpdateChecker(session: ScriptedSession(nonHTTPResponse: true))
        do {
            _ = try await checker.fetchLatestRelease()
            XCTFail("a non-HTTP response cannot be a release")
        } catch let error as AppUpdateChecker.CheckerError {
            guard case .invalidResponse = error else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// RED: remove the content-type guard → the HTML body reaches the decoder and the user
    /// gets a `DecodingError` about character 0 instead of "a proxy may be intercepting".
    @MainActor
    func testFetchLatestRelease_htmlBody_isRejectedBeforeDecoding() async {
        let checker = AppUpdateChecker(session: ScriptedSession(
            headers: ["Content-Type": "text/html; charset=utf-8"],
            body: Data("<html><body>Sign in to WiFi</body></html>".utf8)))
        do {
            _ = try await checker.fetchLatestRelease()
            XCTFail("a captive-portal page is not a release")
        } catch let error as AppUpdateChecker.CheckerError {
            guard case .unexpectedContentType(let ct) = error else {
                return XCTFail("expected unexpectedContentType, got \(error)")
            }
            XCTAssertTrue(ct.contains("text/html"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// RED: relax the `(200..<300)` range → a 403 body is decoded as a release.
    @MainActor
    func testFetchLatestRelease_rateLimited_reportsTheStatus() async {
        let checker = AppUpdateChecker(session: ScriptedSession(status: 403))
        do {
            _ = try await checker.fetchLatestRelease()
            XCTFail("403 is not success")
        } catch let error as AppUpdateChecker.CheckerError {
            guard case .badStatus(let code) = error else {
                return XCTFail("expected badStatus, got \(error)")
            }
            XCTAssertEqual(code, 403)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - QuickCaptureFormState.canSubmit

    /// Chat-mode working shares the answer-mode rules — text OR an attachment OR a clip is
    /// enough. Non-chat working has no composer at all, so submit must be dead there: a
    /// live send button on a loader would queue a message no role will ever read.
    ///
    /// RED: drop the `guard isChatMode else { return false }` → the non-chat assertion
    /// fails.
    @MainActor
    func testCanSubmit_workingMode_followsChatnessNotJustContent() {
        let state = QuickCaptureFormState()
        state.answerText = "queue this"

        XCTAssertTrue(state.canSubmit(mode: .taskWorking(roleName: "r", isChatMode: true)),
                      "chat-mode working can queue the next message")
        XCTAssertFalse(state.canSubmit(mode: .taskWorking(roleName: "r", isChatMode: false)),
                       "a loader has no composer — submit must be dead")
    }

    /// An attachment or a clip alone is submittable in chat-mode working, same as in answer
    /// mode: the user can send a screenshot with no words.
    @MainActor
    func testCanSubmit_workingMode_attachmentOrClipAloneIsEnough() {
        let state = QuickCaptureFormState()
        let chat = QuickCaptureMode.taskWorking(roleName: "r", isChatMode: true)
        XCTAssertFalse(state.canSubmit(mode: chat), "nothing to send yet")

        state.answerClippedTexts = [Clip].minting(["a clip"])
        XCTAssertTrue(state.canSubmit(mode: chat), "a clip alone is a message")

        state.answerClippedTexts = []
        state.answerText = "   "
        XCTAssertFalse(state.canSubmit(mode: chat),
                       "whitespace is not text — otherwise a stray space enables send")
    }

    // MARK: - AnswerTextBuilder clip headers

    /// A clip captured from a project file carries its path and line range, and that has to
    /// reach the prompt HEADER: the attribution is the difference between the model knowing
    /// which file a snippet came from and guessing, and a `// Source:` line left inside the
    /// body reads as the snippet's first line of code.
    ///
    /// Assertions are on whole header LINES, not on substrings. `contains("1 of 2")` and
    /// `contains("Calculator.swift:10-12")` both pass in the plain-header branch too — the
    /// path survives inside the body — so a substring assertion cannot tell the two apart.
    /// That is exactly how the first version of this test passed against the bug.
    ///
    /// RED: parse the TRIMMED clip instead of the raw one (the pre-fix behaviour) → the
    /// headers lose their source and every assertion below fails.
    @MainActor
    func testBuild_multipleSourcedClips_numbersEachAndNamesItsFileInTheHeader() {
        let first = "\u{200B}// Source: Calculator.swift:10-12\nlet a = 1"
        let second = "\u{200B}// Source: Parser.swift:3-4\nlet b = 2"

        let built = AnswerTextBuilder.build(text: "please look",
                                            clips: [first, second],
                                            attachments: [],
                                            embedFiles: false)
        let lines = built.answer.components(separatedBy: "\n")

        XCTAssertTrue(lines.contains("## Clipped Text — 1 of 2, Calculator.swift:10-12"),
                      "header must carry BOTH the ordinal and the source:\n\(built.answer)")
        XCTAssertTrue(lines.contains("## Clipped Text — 2 of 2, Parser.swift:3-4"),
                      built.answer)
        XCTAssertFalse(lines.contains { $0.hasPrefix("// Source:") },
                       "the attribution belongs in the header — left in the body the model "
                           + "reads it as the first line of the code it was asked to change:"
                           + "\n\(built.answer)")
        XCTAssertTrue(lines.contains("let a = 1"), "the body must survive: \(built.answer)")
        XCTAssertFalse(built.answer.contains("\u{200B}"),
                       "the zero-width sentinel is a transport marker and must not ship")
    }

    /// A single sourced clip needs no ordinal — "1 of 1" is noise in a prompt whose token
    /// budget is the binding constraint.
    ///
    /// RED: always emit the numbered form → this fails.
    @MainActor
    func testBuild_singleSourcedClip_namesTheFileAndOmitsTheOrdinal() {
        let clip = "\u{200B}// Source: Calculator.swift:10-12\nlet a = 1"
        let built = AnswerTextBuilder.build(text: "look", clips: [clip],
                                            attachments: [], embedFiles: false)
        let lines = built.answer.components(separatedBy: "\n")

        XCTAssertTrue(lines.contains("## Clipped Text — Calculator.swift:10-12"), built.answer)
        XCTAssertFalse(built.answer.contains("1 of 1"),
                       "an ordinal for a single clip is wasted context: \(built.answer)")
    }

    /// The plain branch must stay plain: a clip with no sentinel gets no invented source.
    /// This is the anti-vacuity partner of the two tests above — it is what makes their
    /// whole-line assertions meaningful rather than tautological.
    @MainActor
    func testBuild_plainClip_getsNoSourceHeader() {
        let built = AnswerTextBuilder.build(text: "look", clips: ["just some text"],
                                            attachments: [], embedFiles: false)
        let lines = built.answer.components(separatedBy: "\n")

        XCTAssertTrue(lines.contains("## Clipped Text"),
                      "an unsourced clip gets the bare header: \(built.answer)")
        XCTAssertFalse(lines.contains { $0.hasPrefix("## Clipped Text — ") },
                       "nothing to attribute, so nothing may be attributed")
    }

    /// Ordering and numbering must span sourced AND plain clips together — they share one
    /// `N of M` sequence in capture order. Two separate lists would renumber from 1 for
    /// each kind and the model could not match a header to what the user picked.
    ///
    /// RED: collect sourced and plain clips into two lists → the ordinals restart and this
    /// fails.
    @MainActor
    func testBuild_mixedClips_shareOneNumberingInCaptureOrder() {
        let built = AnswerTextBuilder.build(
            text: "look",
            clips: ["plain first",
                    "\u{200B}// Source: Calculator.swift:10-12\nlet a = 1",
                    "plain third"],
            attachments: [], embedFiles: false)
        let lines = built.answer.components(separatedBy: "\n")

        XCTAssertTrue(lines.contains("## Clipped Text — 1 of 3"), built.answer)
        XCTAssertTrue(lines.contains("## Clipped Text — 2 of 3, Calculator.swift:10-12"),
                      "the sourced clip keeps its position in the shared sequence:\n\(built.answer)")
        XCTAssertTrue(lines.contains("## Clipped Text — 3 of 3"), built.answer)
    }

    /// A sourced clip whose body is only whitespace has nothing to contribute, and must be
    /// dropped rather than shipped as a header with an empty section — same rule the skill
    /// branch already applies.
    ///
    /// RED: append the clip without the empty-body guard → an orphan header ships.
    @MainActor
    func testBuild_sourcedClipWithEmptyBody_isDropped() {
        let built = AnswerTextBuilder.build(
            text: "look",
            clips: ["\u{200B}// Source: Calculator.swift:10-12\n   \n"],
            attachments: [], embedFiles: false)

        XCTAssertFalse(built.answer.contains("Clipped Text"),
                       "a header with no body is noise: \(built.answer)")
    }

    // MARK: - Residue, deliberately not covered
    //
    // `PasteboardImageExtractor`'s PNG-encode failure arm (3 lines) needs an `NSImage`
    // that survives an `NSPasteboard` round-trip while having no bitmap representation.
    // A bare `NSImage()` does not round-trip at all, so the arm is not reachable through
    // the pasteboard seam the function already exposes, and inventing a second seam for
    // three lines would be worse than leaving them visible in the report.
}
