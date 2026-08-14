import XCTest

@testable import NanoTeams

/// Wave 10 — the error-surface tail of the tool runtime.
///
/// Every target here is a message the model reads verbatim when something goes wrong, and none of
/// them had a test. That matters more than the line count: the runtime's whole recovery contract
/// is that a rejected call explains itself well enough for the next turn to be different, so an
/// error string is production text, not decoration. Two of the four `ToolRuntimeError` arms name
/// a JSON shape the model is supposed to copy.
///
/// Two further candidates were probed and DROPPED rather than tested, which is the more useful
/// half of this file's record:
///
///  - `SandboxPathResolver`'s `.outsideSandbox` throw is unreachable. A relative path carrying
///    `..` is rejected earlier by `.parentTraversalNotAllowed`, and an absolute one is rejected
///    earlier by `.absolutePathNotAllowed`; past both, components are re-appended to the root and
///    can only standardize back inside it. The throw is the correct backstop for a third entry
///    form, not a live path.
///  - `RTFDocumentExtractor`'s type-mismatch arm is unreachable ON macOS 26. Its doc comment says
///    `NSAttributedString` "silently succeeds" when the RTF path is aimed at HTML or plaintext;
///    measured directly, an explicit `.documentType: .rtf` is strict and THROWS for HTML, for
///    plaintext, and for an `.rtfd` package, so the `catch` handles all three and the mismatch
///    branch never runs. It is deliberately left in place: the deployment target is macOS 15,
///    where the looser behaviour the comment describes may still hold, and this checkout cannot
///    measure that. Removing a guard on one OS's behaviour is exactly the cross-version trap
///    CLAUDE.md records for `standardizedFileURL`.
final class ToolErrorSurfaceCoverageTests: XCTestCase {

    // MARK: - ToolRuntimeError

    /// The four `errorDescription` arms are the only rendering of these errors. `ToolRuntime`
    /// funnels them into `toolErrorJSON`'s `message`, so a nil or empty description would ship a
    /// tool result whose failure is unexplained.
    ///
    /// `argumentsNotObject` is the enum's ONLY case (wave 32 deleted three zero-producer
    /// siblings — unknown tools, unparseable JSON and empty keys are all RECOVERED by the
    /// runtime, never thrown, so their messages were dead copy nothing could ever send).
    ///
    /// RED: blank the arm's text → the content assertion fails.
    func testToolRuntimeError_argumentsNotObjectNamesItsFailure() {
        let notObject = ToolRuntimeError.argumentsNotObject.errorDescription ?? ""
        XCTAssertTrue(notObject.contains("must be a JSON object"), "got: \(notObject)")
        XCTAssertTrue(notObject.contains("Expected format"),
                      "the corrective example is what a small model retries from; got: \(notObject)")
    }
}
