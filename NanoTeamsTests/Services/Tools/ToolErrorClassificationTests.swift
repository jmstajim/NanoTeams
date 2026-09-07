import XCTest

@testable import NanoTeams

/// `ToolErrorHandler.classify` — the one place allowed to look at an error the app did not
/// author, and the reason no handler needs `localizedDescription` any more.
///
/// Three properties, and the third is the one that made the old generic arm a defect rather
/// than a style complaint: the answer must be TYPED (so `ToolErrorNotePolicy` steers by
/// state), STABLE (English, whatever the user's system language is), and free of absolute
/// paths — the leak `SandboxPathError.restrictedPath` is careful to avoid one arm above.
final class ToolErrorClassificationTests: XCTestCase {

    private func classify(_ domain: String, _ code: Int) -> (code: ToolErrorCode, message: String) {
        // `userInfo` carries a localized description on purpose: the point is that it is NOT
        // what comes back.
        ToolErrorHandler.classify(NSError(
            domain: domain, code: code,
            userInfo: [NSLocalizedDescriptionKey: "Не удалось открыть файл «/Users/alex/x.txt»."]))
    }

    // MARK: - The OS's own distinctions, restored

    func testCocoaAndPOSIXFileErrors_mapToDistinctCodes() {
        let cases: [(String, Int, ToolErrorCode, String)] = [
            (NSCocoaErrorDomain, 4, .fileNotFound, "File not found."),
            (NSCocoaErrorDomain, 260, .fileNotFound, "File not found."),
            (NSPOSIXErrorDomain, 2, .fileNotFound, "File not found."),
            (NSCocoaErrorDomain, 257, .permissionDenied, "Permission denied."),
            (NSCocoaErrorDomain, 513, .permissionDenied, "Permission denied."),
            (NSPOSIXErrorDomain, 13, .permissionDenied, "Permission denied."),
            (NSCocoaErrorDomain, 512, .invalidArgs, "The path is not a valid file name."),
            (NSCocoaErrorDomain, 516, .conflict, "A file already exists at that path."),
            (NSCocoaErrorDomain, 640, .commandFailed, "No space left on the volume."),
            (NSPOSIXErrorDomain, 28, .commandFailed, "No space left on the volume."),
            (NSPOSIXErrorDomain, 21, .notAFile, "That path is a directory."),
            (NSCocoaErrorDomain, 3840, .commandFailed, "The file's contents are not valid JSON."),
        ]
        for (domain, code, expectedCode, expectedMessage) in cases {
            let result = classify(domain, code)
            XCTAssertEqual(result.code, expectedCode, "\(domain) \(code)")
            XCTAssertEqual(result.message, expectedMessage, "\(domain) \(code)")
        }
        // The whole point of the table: "no such file" and "no permission" no longer arrive
        // under one code, so the recovery policy can steer them apart.
        XCTAssertNotEqual(classify(NSCocoaErrorDomain, 260).code,
                          classify(NSCocoaErrorDomain, 257).code)
    }

    /// Transport errors reach the wire from the vision, meeting, consultation and judge paths,
    /// and `URLError`'s text is localized like Cocoa's — so the four the model can act on get
    /// stable English, and the rest keep the domain-and-code handle.
    func testTransportErrors_mapToStableEnglish() {
        let cases: [(Int, String)] = [
            (NSURLErrorTimedOut, "The request timed out."),
            (NSURLErrorCannotFindHost, "The server could not be reached."),
            (NSURLErrorCannotConnectToHost, "The server could not be reached."),
            (NSURLErrorNetworkConnectionLost, "The server could not be reached."),
            (NSURLErrorNotConnectedToInternet, "The server could not be reached."),
        ]
        for (code, expected) in cases {
            let result = classify(NSURLErrorDomain, code)
            XCTAssertEqual(result.code, .commandFailed, "\(code)")
            XCTAssertEqual(result.message, expected, "\(code)")
        }
        XCTAssertEqual(classify(NSURLErrorDomain, NSURLErrorBadServerResponse).message,
                       "The tool failed with an unclassified system error (NSURLErrorDomain -1011).")
    }

    func testTextEncodingFailure_isNotReportedAsMissingOrForbidden() {
        let result = classify(NSCocoaErrorDomain, 261)
        XCTAssertEqual(result.code, .commandFailed)
        XCTAssertEqual(result.message,
                       "The file could not be decoded with the requested text encoding.")
    }

    /// The property the table exists for: whatever the OS said, in whatever language, and
    /// wherever the file lives, none of it reaches the model.
    func testClassifiedMessages_carryNoLocalizedTextAndNoAbsolutePath() {
        for (domain, code) in [(NSCocoaErrorDomain, 260), (NSCocoaErrorDomain, 257),
                               (NSPOSIXErrorDomain, 13), (NSCocoaErrorDomain, 9999)] {
            let message = classify(domain, code).message
            XCTAssertFalse(message.contains("/Users/"), "\(domain) \(code): \(message)")
            XCTAssertFalse(message.contains("Не удалось"), "\(domain) \(code): \(message)")
        }
    }

    /// An error nobody anticipated still gets a handle — the domain and code are the only
    /// things a Supervisor reading the card can look up — and it is neither localized nor
    /// path-bearing.
    func testUnknownDomain_namesTheDomainAndCodeAndNothingElse() {
        let result = classify("com.example.Weird", 77)
        XCTAssertEqual(result.code, .commandFailed)
        XCTAssertEqual(result.message,
                       "The tool failed with an unclassified system error (com.example.Weird 77).")
    }

    // MARK: - Decode failures, in the model's terms

    private struct Row: Decodable {
        var name: String
        var count: Int
    }

    private func decodeMessage(_ json: String) -> String {
        do {
            _ = try JSONDecoder().decode(Row.self, from: Data(json.utf8))
            XCTFail("fixture decoded — it must not")
            return ""
        } catch {
            return ToolErrorHandler.classify(error).message
        }
    }

    func testDecodingErrors_nameTheKeyOrTheTypeInsteadOfFoundationsGenericPhrase() {
        let missing = decodeMessage(#"{"count": 1}"#)
        XCTAssertTrue(missing.hasPrefix("Malformed JSON: required key 'name' is missing"), missing)

        let mismatch = decodeMessage(#"{"name": 1, "count": 1}"#)
        XCTAssertTrue(mismatch.hasPrefix("Malformed JSON: expected"), mismatch)

        let null = decodeMessage(#"{"name": null, "count": 1}"#)
        XCTAssertTrue(null.hasPrefix("Malformed JSON: found null where"), null)

        let corrupt = decodeMessage("{not json")
        XCTAssertTrue(corrupt.hasPrefix("Malformed JSON"), corrupt)

        // Foundation's own phrasing must not survive anywhere in the family.
        for m in [missing, mismatch, null, corrupt] {
            XCTAssertFalse(m.contains("couldn’t be read"), m)
            XCTAssertFalse(m.contains("couldn't be read"), m)
        }
    }

    /// `codingPath` is the only part that says WHERE, and it is derived from the DOCUMENT
    /// being decoded rather than from the filesystem — so unlike `localizedDescription` it
    /// cannot carry a path outside the sandbox.
    func testDecodingError_atTopLevel_saysSoInsteadOfPrintingAnEmptyPath() {
        let message = decodeMessage(#"{"count": 1}"#)
        XCTAssertTrue(message.hasSuffix("at the top level."), message)
    }

    func testDecodingError_nestedKey_namesThePath() {
        struct Outer: Decodable { var row: Row }
        do {
            _ = try JSONDecoder().decode(Outer.self, from: Data(#"{"row":{"count":1}}"#.utf8))
            XCTFail("fixture decoded")
        } catch {
            let message = ToolErrorHandler.classify(error).message
            XCTAssertTrue(message.contains("at row."), message)
        }
    }

    // MARK: - App-authored errors pass through

    /// Our own `LocalizedError`s are already English, sandbox-relative and written for this
    /// reader; rewriting them would be the defect in the other direction.
    func testAppAuthoredLocalizedError_passesThroughVerbatim() {
        let result = ToolErrorHandler.classify(
            ToolArgumentError.invalidValue(key: "depth", detail: "must be an integer"))
        XCTAssertEqual(result.message, "Argument 'depth' must be an integer")
        XCTAssertEqual(result.code, .commandFailed)
    }

    // MARK: - ProcessRunnerError

    /// Exhaustive over the enum, including `.cancelled` — which reaches its own arm in
    /// `execute` and is kept here so a new case cannot silently inherit a wrong code.
    func testProcessRunnerErrors_eachGetTheCodeItsRecoveryNeeds() {
        let timeout = ToolErrorHandler.classify(
            processRunnerError: .timeout(30, stdout: "", stderr: ""))
        XCTAssertEqual(timeout.code, .commandTimedOut)

        let launch = ToolErrorHandler.classify(
            processRunnerError: .launchFailed(executable: "/bin/zsh", reason: "boom"))
        XCTAssertEqual(launch.code, .invalidArgs,
                       "the usual cause is `working_directory`, which IS an argument")

        let missing = ToolErrorHandler.classify(
            processRunnerError: .executableNotFound("/usr/bin/nope"))
        XCTAssertEqual(missing.code, .commandFailed)

        let cancelled = ToolErrorHandler.classify(processRunnerError: .cancelled)
        XCTAssertEqual(cancelled.code, .cancelled)
    }
}
