import XCTest
@testable import NanoTeams

final class URLOpenerTests: XCTestCase {

    func testFailureMessage_includesHostWhenAvailable() {
        let url = URL(string: "https://github.com/anthropics")!
        let message = URLOpener.failureMessage(for: url)
        XCTAssertTrue(message.contains("github.com"),
                      "expected message to name the URL host, got: \(message)")
    }

    func testFailureMessage_fallsBackToAbsoluteStringWhenHostNil() {
        let url = URL(string: "madeupscheme:payload")!
        XCTAssertNil(url.host, "precondition: host must be nil for this URL")
        let message = URLOpener.failureMessage(for: url)
        XCTAssertTrue(message.contains("madeupscheme:payload"),
                      "expected message to fall back to absoluteString, got: \(message)")
    }

    func testFailureMessage_pointsToSystemSettingsBrowserLocation() {
        let message = URLOpener.failureMessage(for: URL(string: "https://example.com")!)
        XCTAssertTrue(message.contains("System Settings"),
                      "expected guidance toward System Settings, got: \(message)")
        XCTAssertTrue(message.contains("Default web browser"),
                      "expected guidance to name the Default web browser preference, got: \(message)")
    }
}
