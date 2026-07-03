import XCTest

@testable import NanoTeams

/// Privacy pin: base64 image payloads must be stripped from the network log so a screenshot
/// the model saw is never written to `network_log.json`.
final class ScreenshotRedactionTests: XCTestCase {

    func testRedact_stripsBase64Image() {
        let body = "{\"input\":[{\"type\":\"image\",\"data_url\":\"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAB118==\"}]}"
        let out = NetworkLogger.redactImageData(body)
        XCTAssertNotNil(out)
        XCTAssertFalse(out!.contains("iVBORw0KGgo"), "raw base64 must not survive")
        XCTAssertTrue(out!.contains("[redacted]"))
    }

    func testRedact_stripsMultipleImages() {
        let body = "a data:image/jpeg;base64,AAAABBBBCCCC b data:image/png;base64,DDDDEEEE c"
        let out = NetworkLogger.redactImageData(body)!
        XCTAssertFalse(out.contains("AAAABBBB"))
        XCTAssertFalse(out.contains("DDDDEEEE"))
    }

    func testRedact_leavesNonImageBodyUnchanged() {
        let body = "{\"input\":\"just some text, no image\"}"
        XCTAssertEqual(NetworkLogger.redactImageData(body), body)
    }

    func testRedact_nilPassesThrough() {
        XCTAssertNil(NetworkLogger.redactImageData(nil))
    }

    func testCreateRequestRecord_redactsImageBody() {
        let json = "{\"data_url\":\"data:image/png;base64,SECRETSECRETSECRET\"}"
        let record = NetworkLogger.createRequestRecord(
            url: URL(string: "http://127.0.0.1:1234/api/v1/chat")!,
            method: "POST", body: json.data(using: .utf8), stepID: "role")
        XCTAssertFalse(record.body?.contains("SECRETSECRETSECRET") ?? true)
    }
}
