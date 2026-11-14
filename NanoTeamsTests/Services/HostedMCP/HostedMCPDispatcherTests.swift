import Foundation
import XCTest
@testable import NanoTeams

final class HostedMCPDispatcherTests: XCTestCase {

    private let testAgent = AgentIdentity(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        label: "Claude Code"
    )

    // MARK: - Helpers

    private func makeHTTPRequest(
        headers: [(String, String)],
        body: String
    ) -> HostedMCPHTTPRequest {
        var headerMap: [String: String] = [:]
        for (name, value) in headers {
            headerMap[name] = value
        }
        return HostedMCPHTTPRequest(
            head: HostedMCPHTTPRequestHead(
                method: "POST",
                rawTarget: "/mcp",
                version: "HTTP/1.1",
                headers: headerMap
            ),
            body: Data(body.utf8)
        )
    }

    private func parseJSONObject(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try XCTUnwrap(raw as? [String: Any], "Expected JSON object", file: file, line: line)
    }

    private func responseHeader(_ response: HostedMCPHTTPResponse, _ name: String) -> String? {
        response.headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    // MARK: - 1. Verbatim 2026-07-28 Spec Examples (O14 — Independent of MCPClient/MCPWire)

    func testModernVerbatimSpecDiscoverAndToolsCallExamples() async throws {
        let stubHost = ClosureHostedMCPToolExecutor { name, _, _, _, _ in
            ToolExecutionResult(
                toolName: name,
                argumentsJSON: "{}",
                outputJSON: #"{"ok":true,"data":{"folder_id":"F-1","echo_name":\#(String(reflecting: name))},"error":null,"next":null,"meta":{"tool":\#(String(reflecting: name))}}"#,
                isError: false
            )
        }
        let dispatcher = HostedMCPDispatcher(
            toolExecutor: stubHost,
            serverVersion: "2.0.0",
            agentTextVersion: "deadbeef12345678"
        )

        // Verbatim 2026-07-28 `server/discover` request frame
        let discoverBody = """
        {
          "jsonrpc": "2.0",
          "id": 1,
          "method": "server/discover",
          "params": {
            "_meta": {
              "io.modelcontextprotocol/protocolVersion": "2026-07-28",
              "io.modelcontextprotocol/clientCapabilities": {},
              "io.modelcontextprotocol/clientInfo": {
                "name": "spec-oracle-client",
                "version": "1.0.0"
              }
            }
          }
        }
        """
        let discoverReq = makeHTTPRequest(
            headers: [
                ("MCP-Protocol-Version", "2026-07-28"),
                ("Mcp-Method", "server/discover"),
            ],
            body: discoverBody
        )
        let discoverResp = await dispatcher.handlePOST(request: discoverReq, agent: testAgent)
        XCTAssertEqual(discoverResp.statusCode, 200)

        let discoverJSON = try parseJSONObject(discoverResp.body)
        XCTAssertEqual(discoverJSON["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(discoverJSON["id"] as? Int, 1)
        let discoverResult = try XCTUnwrap(discoverJSON["result"] as? [String: Any])
        XCTAssertEqual(discoverResult["resultType"] as? String, "complete")
        XCTAssertEqual(discoverResult["protocolVersion"] as? String, "2026-07-28")
        XCTAssertEqual(
            discoverResult["supportedVersions"] as? [String],
            ["2026-07-28", "2025-11-25", "2025-06-18"]
        )
        XCTAssertEqual(discoverResult["instructions"] as? String, HostedMCPInstructions.text)
        XCTAssertEqual(discoverResult["ttlMs"] as? Int, 3_600_000)
        XCTAssertEqual(discoverResult["cacheScope"] as? String, "private")

        let capabilities = try XCTUnwrap(discoverResult["capabilities"] as? [String: Any])
        let toolsCap = try XCTUnwrap(capabilities["tools"] as? [String: Any])
        XCTAssertEqual(toolsCap["listChanged"] as? Bool, false)
        XCTAssertNil(capabilities["resources"])
        XCTAssertNil(capabilities["prompts"])
        XCTAssertNil(capabilities["logging"])

        let meta = try XCTUnwrap(discoverResult["_meta"] as? [String: Any])
        let serverInfo = try XCTUnwrap(meta["io.modelcontextprotocol/serverInfo"] as? [String: Any])
        XCTAssertEqual(serverInfo["name"] as? String, "nanoteams")
        XCTAssertEqual(serverInfo["title"] as? String, "NanoTeams")
        XCTAssertEqual(serverInfo["version"] as? String, "2.0.0")
        XCTAssertEqual(meta["io.nanoteams/agentTextVersion"] as? String, "deadbeef12345678")

        // Verbatim 2026-07-28 `tools/call` request frame
        let callBody = """
        {
          "jsonrpc": "2.0",
          "id": "call-42",
          "method": "tools/call",
          "params": {
            "name": "folder_status",
            "arguments": {},
            "_meta": {
              "io.modelcontextprotocol/protocolVersion": "2026-07-28",
              "io.modelcontextprotocol/clientCapabilities": {},
              "io.modelcontextprotocol/clientInfo": {
                "name": "spec-oracle-client",
                "version": "1.0.0"
              }
            }
          }
        }
        """
        let callReq = makeHTTPRequest(
            headers: [
                ("MCP-Protocol-Version", "2026-07-28"),
                ("Mcp-Method", "tools/call"),
                ("Mcp-Name", "folder_status"),
            ],
            body: callBody
        )
        let callResp = await dispatcher.handlePOST(request: callReq, agent: testAgent)
        XCTAssertEqual(callResp.statusCode, 200)

        let callJSON = try parseJSONObject(callResp.body)
        XCTAssertEqual(callJSON["id"] as? String, "call-42")
        let callResult = try XCTUnwrap(callJSON["result"] as? [String: Any])
        XCTAssertEqual(callResult["resultType"] as? String, "complete")
        XCTAssertEqual(callResult["isError"] as? Bool, false)
        XCTAssertNil(callResult["structuredContent"], "structuredContent must be omitted (§7.3)")
        let content = try XCTUnwrap(callResult["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        let firstContent = try XCTUnwrap(content.first)
        XCTAssertEqual(firstContent["type"] as? String, "text")
        let callMeta = try XCTUnwrap(callResult["_meta"] as? [String: Any])
        XCTAssertNotNil(callMeta["io.modelcontextprotocol/serverInfo"])
        XCTAssertEqual(callMeta["io.nanoteams/agentTextVersion"] as? String, "deadbeef12345678")
    }

    // MARK: - 2. Modern Era Error Matrix (§7.3)

    func testModernEraValidationErrorsAndBase64McpNameSentinel() async throws {
        let stubHost = ClosureHostedMCPToolExecutor { name, _, _, _, _ in
            ToolExecutionResult(toolName: name, argumentsJSON: "{}", outputJSON: #"{"ok":true}"#, isError: false)
        }
        let dispatcher = HostedMCPDispatcher(
            toolExecutor: stubHost,
            serverVersion: "2.0.0",
            agentTextVersion: "deadbeef12345678"
        )

        // 1. Missing MCP-Protocol-Version header when _meta has protocolVersion -> 400 -32020
        let missingHeaderBody = """
        {"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
        """
        let r1 = await dispatcher.handlePOST(
            request: makeHTTPRequest(headers: [("Mcp-Method", "tools/list")], body: missingHeaderBody),
            agent: testAgent
        )
        XCTAssertEqual(r1.statusCode, 400)
        let err1 = try XCTUnwrap(try parseJSONObject(r1.body)["error"] as? [String: Any])
        XCTAssertEqual(err1["code"] as? Int, -32020)

        // 2. Mismatched MCP-Protocol-Version header vs _meta -> 400 -32020
        let r2 = await dispatcher.handlePOST(
            request: makeHTTPRequest(
                headers: [("MCP-Protocol-Version", "2025-11-25"), ("Mcp-Method", "tools/list")],
                body: missingHeaderBody
            ),
            agent: testAgent
        )
        XCTAssertEqual(r2.statusCode, 400)
        let err2 = try XCTUnwrap(try parseJSONObject(r2.body)["error"] as? [String: Any])
        XCTAssertEqual(err2["code"] as? Int, -32020)

        // 3. Unsupported version in _meta (matching header) -> 400 -32022 with data.supported
        let unsupportedVersionBody = """
        {"jsonrpc":"2.0","id":2,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2099-01-01","io.modelcontextprotocol/clientCapabilities":{}}}}
        """
        let r3 = await dispatcher.handlePOST(
            request: makeHTTPRequest(
                headers: [("MCP-Protocol-Version", "2099-01-01"), ("Mcp-Method", "server/discover")],
                body: unsupportedVersionBody
            ),
            agent: testAgent
        )
        XCTAssertEqual(r3.statusCode, 400)
        let err3 = try XCTUnwrap(try parseJSONObject(r3.body)["error"] as? [String: Any])
        XCTAssertEqual(err3["code"] as? Int, -32022)
        let err3Data = try XCTUnwrap(err3["data"] as? [String: Any])
        XCTAssertEqual(
            err3Data["supported"] as? [String],
            ["2026-07-28", "2025-11-25", "2025-06-18"]
        )

        // 4. Missing required _meta key `clientCapabilities` -> 400 -32602
        let missingCapsBody = """
        {"jsonrpc":"2.0","id":3,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}
        """
        let r4 = await dispatcher.handlePOST(
            request: makeHTTPRequest(
                headers: [("MCP-Protocol-Version", "2026-07-28"), ("Mcp-Method", "tools/list")],
                body: missingCapsBody
            ),
            agent: testAgent
        )
        XCTAssertEqual(r4.statusCode, 400)
        let err4 = try XCTUnwrap(try parseJSONObject(r4.body)["error"] as? [String: Any])
        XCTAssertEqual(err4["code"] as? Int, -32602)

        // 5. Modern MCP-Protocol-Version header without _meta -> 400 -32602
        let noMetaBody = """
        {"jsonrpc":"2.0","id":4,"method":"tools/list","params":{}}
        """
        let r5 = await dispatcher.handlePOST(
            request: makeHTTPRequest(
                headers: [("MCP-Protocol-Version", "2026-07-28"), ("Mcp-Method", "tools/list")],
                body: noMetaBody
            ),
            agent: testAgent
        )
        XCTAssertEqual(r5.statusCode, 400)
        let err5 = try XCTUnwrap(try parseJSONObject(r5.body)["error"] as? [String: Any])
        XCTAssertEqual(err5["code"] as? Int, -32602)

        // 6. Mcp-Method mismatch -> 400 -32020
        let r6 = await dispatcher.handlePOST(
            request: makeHTTPRequest(
                headers: [("MCP-Protocol-Version", "2026-07-28"), ("Mcp-Method", "server/discover")],
                body: missingHeaderBody
            ),
            agent: testAgent
        )
        XCTAssertEqual(r6.statusCode, 400)
        let err6 = try XCTUnwrap(try parseJSONObject(r6.body)["error"] as? [String: Any])
        XCTAssertEqual(err6["code"] as? Int, -32020)

        // 7. Mcp-Name mismatch on tools/call -> 400 -32020
        let callBody = """
        {"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"folder_status","arguments":{},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
        """
        let r7 = await dispatcher.handlePOST(
            request: makeHTTPRequest(
                headers: [
                    ("MCP-Protocol-Version", "2026-07-28"),
                    ("Mcp-Method", "tools/call"),
                    ("Mcp-Name", "list_tasks"),
                ],
                body: callBody
            ),
            agent: testAgent
        )
        XCTAssertEqual(r7.statusCode, 400)
        let err7 = try XCTUnwrap(try parseJSONObject(r7.body)["error"] as? [String: Any])
        XCTAssertEqual(err7["code"] as? Int, -32020)

        // 8. Mcp-Name encoded with `=?base64?…?=` sentinel decodes before comparison -> 200 OK
        let b64Name = "=?base64?\(Data("folder_status".utf8).base64EncodedString())?="
        let r8 = await dispatcher.handlePOST(
            request: makeHTTPRequest(
                headers: [
                    ("MCP-Protocol-Version", "2026-07-28"),
                    ("Mcp-Method", "tools/call"),
                    ("Mcp-Name", b64Name),
                ],
                body: callBody
            ),
            agent: testAgent
        )
        XCTAssertEqual(r8.statusCode, 200)

        // 9. Unknown method in Modern Era (including `ping` and `subscriptions/listen`) -> 404 -32601
        for unknownMethod in ["ping", "subscriptions/listen", "resources/list", "unknown/method"] {
            let unknownBody = """
            {"jsonrpc":"2.0","id":9,"method":"\(unknownMethod)","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
            """
            let resp = await dispatcher.handlePOST(
                request: makeHTTPRequest(
                    headers: [
                        ("MCP-Protocol-Version", "2026-07-28"),
                        ("Mcp-Method", unknownMethod),
                    ],
                    body: unknownBody
                ),
                agent: testAgent
            )
            XCTAssertEqual(resp.statusCode, 404, "Modern unknown method \(unknownMethod) must return HTTP 404")
            let errObj = try XCTUnwrap(try parseJSONObject(resp.body)["error"] as? [String: Any])
            XCTAssertEqual(errObj["code"] as? Int, -32601)
        }

        // 10. Modern notification without Mcp-Method -> 202 empty body
        let notifBody = """
        {"jsonrpc":"2.0","method":"notifications/initialized","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}
        """
        let r10 = await dispatcher.handlePOST(
            request: makeHTTPRequest(
                headers: [("MCP-Protocol-Version", "2026-07-28")],
                body: notifBody
            ),
            agent: testAgent
        )
        XCTAssertEqual(r10.statusCode, 202)
        XCTAssertTrue(r10.body.isEmpty)

        // 11. Client response in Modern Era -> 400 -32600 without id
        let clientReplyBody = #"{"jsonrpc":"2.0","id":99,"result":{}}"#
        let r11 = await dispatcher.handlePOST(
            request: makeHTTPRequest(
                headers: [("MCP-Protocol-Version", "2026-07-28")],
                body: clientReplyBody
            ),
            agent: testAgent
        )
        XCTAssertEqual(r11.statusCode, 400)
        let err11JSON = try parseJSONObject(r11.body)
        XCTAssertNil(err11JSON["id"])
        let err11 = try XCTUnwrap(err11JSON["error"] as? [String: Any])
        XCTAssertEqual(err11["code"] as? Int, -32600)
    }

    // MARK: - 3. Legacy Era Matrix (§7.3)

    func testLegacyEraInitializeSessionVersionRulesPingAnd202() async throws {
        let stubHost = ClosureHostedMCPToolExecutor { name, _, _, _, _ in
            ToolExecutionResult(toolName: name, argumentsJSON: "{}", outputJSON: #"{"ok":true}"#, isError: false)
        }
        let dispatcher = HostedMCPDispatcher(
            toolExecutor: stubHost,
            serverVersion: "2.0.0",
            agentTextVersion: "deadbeef12345678"
        )

        // 1. `initialize` is ALWAYS legacy even if `_meta` is present; echoes 2025-06-18 when asked
        let init20250618Body = """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"legacy-client","version":"1.0"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}
        """
        let initResp1 = await dispatcher.handlePOST(
            request: makeHTTPRequest(headers: [], body: init20250618Body),
            agent: testAgent
        )
        XCTAssertEqual(initResp1.statusCode, 200)
        let session1 = try XCTUnwrap(responseHeader(initResp1, "Mcp-Session-Id"))
        XCTAssertFalse(session1.isEmpty)
        let initJSON1 = try parseJSONObject(initResp1.body)
        let initResult1 = try XCTUnwrap(initJSON1["result"] as? [String: Any])
        XCTAssertEqual(initResult1["protocolVersion"] as? String, "2025-06-18")
        XCTAssertEqual(initResult1["instructions"] as? String, HostedMCPInstructions.text)
        XCTAssertNil(initResult1["resultType"], "Legacy initialize must not carry modern resultType")

        // 2. `initialize` with 2025-03-26 (excluded because batch was mandatory) falls back to 2025-11-25
        let init20250326Body = """
        {"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"old-client","version":"1.0"}}}
        """
        let initResp2 = await dispatcher.handlePOST(
            request: makeHTTPRequest(headers: [], body: init20250326Body),
            agent: testAgent
        )
        XCTAssertEqual(initResp2.statusCode, 200)
        let initResult2 = try XCTUnwrap(try parseJSONObject(initResp2.body)["result"] as? [String: Any])
        XCTAssertEqual(initResult2["protocolVersion"] as? String, "2025-11-25")

        // 3. `notifications/initialized` -> 202 empty body
        let notifResp = await dispatcher.handlePOST(
            request: makeHTTPRequest(
                headers: [("Mcp-Session-Id", session1)],
                body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
            ),
            agent: testAgent
        )
        XCTAssertEqual(notifResp.statusCode, 202)
        XCTAssertTrue(notifResp.body.isEmpty)

        // 4. Subsequent legacy request WITHOUT MCP-Protocol-Version header uses session1's remembered version -> 200 OK
        let pingBody = #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#
        let pingResp = await dispatcher.handlePOST(
            request: makeHTTPRequest(headers: [("Mcp-Session-Id", session1)], body: pingBody),
            agent: testAgent
        )
        XCTAssertEqual(pingResp.statusCode, 200)
        let pingResult = try XCTUnwrap(try parseJSONObject(pingResp.body)["result"] as? [String: Any])
        XCTAssertTrue(pingResult.isEmpty)

        // 5. Unknown Mcp-Session-Id WITH valid MCP-Protocol-Version header is accepted as a new session namespace (no 404, D7/E5)
        let unknownSessionResp = await dispatcher.handlePOST(
            request: makeHTTPRequest(
                headers: [
                    ("Mcp-Session-Id", "stale-session-after-app-restart"),
                    ("MCP-Protocol-Version", "2025-11-25"),
                ],
                body: pingBody
            ),
            agent: testAgent
        )
        XCTAssertEqual(unknownSessionResp.statusCode, 200)

        // 6. Subsequent legacy request with NEITHER MCP-Protocol-Version header NOR known session version -> 400 -32022 (E4)
        let noVersionNoSessionResp = await dispatcher.handlePOST(
            request: makeHTTPRequest(
                headers: [("Mcp-Session-Id", "brand-new-unknown-session")],
                body: pingBody
            ),
            agent: testAgent
        )
        XCTAssertEqual(noVersionNoSessionResp.statusCode, 400)
        let errNoVer = try XCTUnwrap(try parseJSONObject(noVersionNoSessionResp.body)["error"] as? [String: Any])
        XCTAssertEqual(errNoVer["code"] as? Int, -32022)

        // 7. Subsequent legacy request with unsupported MCP-Protocol-Version header -> 400 -32022
        let badVerResp = await dispatcher.handlePOST(
            request: makeHTTPRequest(
                headers: [
                    ("Mcp-Session-Id", session1),
                    ("MCP-Protocol-Version", "2025-03-26"),
                ],
                body: pingBody
            ),
            agent: testAgent
        )
        XCTAssertEqual(badVerResp.statusCode, 400)
        let errBadVer = try XCTUnwrap(try parseJSONObject(badVerResp.body)["error"] as? [String: Any])
        XCTAssertEqual(errBadVer["code"] as? Int, -32022)
    }

    // MARK: - 4. Parse Error (-32700) vs Invalid Request (-32600) Without ID (§7.2, §7.3)

    func testMalformedJSONAndBatchReturnDistinctErrorsWithoutID() async throws {
        let stubHost = ClosureHostedMCPToolExecutor { name, _, _, _, _ in
            ToolExecutionResult(toolName: name, argumentsJSON: "{}", outputJSON: #"{"ok":true}"#, isError: false)
        }
        let dispatcher = HostedMCPDispatcher(
            toolExecutor: stubHost,
            serverVersion: "2.0.0",
            agentTextVersion: "deadbeef12345678"
        )

        let badJSONResp = await dispatcher.handlePOST(
            request: makeHTTPRequest(headers: [], body: #"{"jsonrpc":"2.0","id":1"#),
            agent: testAgent
        )
        XCTAssertEqual(badJSONResp.statusCode, 400)
        let badJSONObj = try parseJSONObject(badJSONResp.body)
        XCTAssertNil(badJSONObj["id"])
        let badJSONErr = try XCTUnwrap(badJSONObj["error"] as? [String: Any])
        XCTAssertEqual(badJSONErr["code"] as? Int, -32700)

        let batchResp = await dispatcher.handlePOST(
            request: makeHTTPRequest(
                headers: [],
                body: #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#
            ),
            agent: testAgent
        )
        XCTAssertEqual(batchResp.statusCode, 400)
        let batchObj = try parseJSONObject(batchResp.body)
        XCTAssertNil(batchObj["id"])
        let batchErr = try XCTUnwrap(batchObj["error"] as? [String: Any])
        XCTAssertEqual(batchErr["code"] as? Int, -32600)
    }

    // MARK: - 5. Per-Agent Rate Limiting (§7.2)

    func testRateLimiterReturnsIsErrorEnvelopeForToolsCallAnd429ForOtherMethods() async throws {
        let nowBox = LockedBox(Date(timeIntervalSince1970: 1_700_000_000))
        let stubHost = ClosureHostedMCPToolExecutor { name, _, _, _, _ in
            ToolExecutionResult(toolName: name, argumentsJSON: "{}", outputJSON: #"{"ok":true}"#, isError: false)
        }
        let dispatcher = HostedMCPDispatcher(
            toolExecutor: stubHost,
            serverVersion: "2.0.0",
            agentTextVersion: "deadbeef12345678",
            rateLimitConfig: HostedMCPRateLimitConfiguration(capacity: 2, refillPerSecond: 1.0),
            now: { nowBox.get() }
        )

        let callBody = """
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"folder_status","arguments":{},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
        """
        let callHeaders = [
            ("MCP-Protocol-Version", "2026-07-28"),
            ("Mcp-Method", "tools/call"),
            ("Mcp-Name", "folder_status"),
        ]

        // First 2 requests succeed
        let ok1 = await dispatcher.handlePOST(request: makeHTTPRequest(headers: callHeaders, body: callBody), agent: testAgent)
        let ok2 = await dispatcher.handlePOST(request: makeHTTPRequest(headers: callHeaders, body: callBody), agent: testAgent)
        XCTAssertEqual(ok1.statusCode, 200)
        XCTAssertEqual(ok2.statusCode, 200)
        let ok2Result = try XCTUnwrap(try parseJSONObject(ok2.body)["result"] as? [String: Any])
        XCTAssertEqual(ok2Result["isError"] as? Bool, false)

        // 3rd request is `tools/call` -> HTTP 200 with `isError: true`, `RATE_LIMITED`, `details.retry_after_ms`
        let limitedCall = await dispatcher.handlePOST(request: makeHTTPRequest(headers: callHeaders, body: callBody), agent: testAgent)
        XCTAssertEqual(limitedCall.statusCode, 200)
        let limitedResult = try XCTUnwrap(try parseJSONObject(limitedCall.body)["result"] as? [String: Any])
        XCTAssertEqual(limitedResult["isError"] as? Bool, true)
        let content = try XCTUnwrap(limitedResult["content"] as? [[String: Any]])
        let envelopeText = try XCTUnwrap(content.first?["text"] as? String)
        let envelopeObj = try parseJSONObject(Data(envelopeText.utf8))
        XCTAssertEqual(envelopeObj["ok"] as? Bool, false)
        let errBlock = try XCTUnwrap(envelopeObj["error"] as? [String: Any])
        XCTAssertEqual(errBlock["code"] as? String, "RATE_LIMITED")
        let details = try XCTUnwrap(errBlock["details"] as? [String: String])
        XCTAssertGreaterThan(Int(details["retry_after_ms"] ?? "") ?? 0, 0)
        // The next call is the refused one, after the wait (F6 L1: it carried none).
        let next = try XCTUnwrap(envelopeObj["next"] as? [String: Any], envelopeText)
        XCTAssertEqual(next["suggested_cmd"] as? String, "folder_status")
        XCTAssertTrue((next["reason"] as? String)?.contains("retry_after_ms") == true, "\(next)")
        // One place for the wait: the shared envelope carries no `data` on a refusal and nothing
        // beside `code`/`message`/`details` in `error`.
        XCTAssertTrue(envelopeObj["data"] == nil || envelopeObj["data"] is NSNull)
        XCTAssertEqual(Set(errBlock.keys), ["code", "message", "details"])

        // 4th request is `tools/list` -> HTTP 429 Too Many Requests
        let listBody = """
        {"jsonrpc":"2.0","id":4,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
        """
        let limitedList = await dispatcher.handlePOST(
            request: makeHTTPRequest(
                headers: [("MCP-Protocol-Version", "2026-07-28"), ("Mcp-Method", "tools/list")],
                body: listBody
            ),
            agent: testAgent
        )
        XCTAssertEqual(limitedList.statusCode, 429)

        // Advance injectable clock by 2 seconds -> bucket refills!
        nowBox.set(nowBox.get().addingTimeInterval(2.0))
        let recovered = await dispatcher.handlePOST(
            request: makeHTTPRequest(
                headers: [("MCP-Protocol-Version", "2026-07-28"), ("Mcp-Method", "tools/list")],
                body: listBody
            ),
            agent: testAgent
        )
        XCTAssertEqual(recovered.statusCode, 200)
    }

    /// E1 review R8, RED before 2026-11-12: the rate limit's next named the same tool with no
    /// arguments, so a client that builds the repeat from `suggested_args` sent `task_log` without
    /// its task, its folder or its cursor. Nothing judged the call, so the hint is the call: what it
    /// sent of the arguments that say where it reads, typed as the schema types them.
    func testRateLimitedCall_nextIsTheSameCall_withTheTaskFolderAndCursorItSent() async throws {
        let stubHost = ClosureHostedMCPToolExecutor { name, _, _, _, _ in
            ToolExecutionResult(toolName: name, argumentsJSON: "{}", outputJSON: #"{"ok":true}"#, isError: false)
        }
        let dispatcher = HostedMCPDispatcher(
            toolExecutor: stubHost,
            serverVersion: "2.0.0",
            agentTextVersion: "deadbeef12345678",
            rateLimitConfig: HostedMCPRateLimitConfiguration(capacity: 1, refillPerSecond: 0.001),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let body = """
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"task_log","arguments":{"folder_id":"F-1","task_id":7,"after":3,"limit":20},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
        """
        let headers = [("MCP-Protocol-Version", "2026-07-28"), ("Mcp-Method", "tools/call"), ("Mcp-Name", "task_log")]
        _ = await dispatcher.handlePOST(request: makeHTTPRequest(headers: headers, body: body), agent: testAgent)
        let limited = await dispatcher.handlePOST(request: makeHTTPRequest(headers: headers, body: body), agent: testAgent)

        let result = try XCTUnwrap(try parseJSONObject(limited.body)["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let envelope = try parseJSONObject(Data(text.utf8))
        XCTAssertEqual((envelope["error"] as? [String: Any])?["code"] as? String, "RATE_LIMITED")
        let next = try XCTUnwrap(envelope["next"] as? [String: Any], text)
        XCTAssertEqual(next["suggested_cmd"] as? String, "task_log")
        let args = try XCTUnwrap(next["suggested_args"] as? [String: Any], text)
        XCTAssertEqual(args["task_id"] as? Int, 7, "a number, as the schema types it")
        XCTAssertEqual(args["after"] as? Int, 3)
        XCTAssertEqual(args["folder_id"] as? String, "F-1", "the call's own folder, sent back unjudged")
        XCTAssertNil(args["limit"], "only what says where the call reads")
    }

    // MARK: - 6. SSE Progress & Keep-Alive (0.2s Interval, Strictly Increasing, Never in Final Tick)

    func testSSEProgressWith0Point2SecondIntervalIsStrictlyIncreasingAndNotInFinalTick() async throws {
        let stubHost = ClosureHostedMCPToolExecutor { name, _, _, _, _ in
            try? await Task.sleep(for: .milliseconds(520))
            return ToolExecutionResult(
                toolName: name,
                argumentsJSON: "{}",
                outputJSON: #"{"ok":true,"data":{"folder_id":"F-1"},"error":null,"next":null,"meta":{"tool":"wait_for_events"}}"#,
                isError: false
            )
        }
        let dispatcher = HostedMCPDispatcher(
            toolExecutor: stubHost,
            serverVersion: "2.0.0",
            agentTextVersion: "deadbeef12345678",
            keepAliveInterval: 0.2
        )

        let body = """
        {
          "jsonrpc": "2.0",
          "id": 77,
          "method": "tools/call",
          "params": {
            "name": "wait_for_events",
            "arguments": {
              "timeout_seconds": 10
            },
            "_meta": {
              "progressToken": "prog-77",
              "io.modelcontextprotocol/protocolVersion": "2026-07-28",
              "io.modelcontextprotocol/clientCapabilities": {}
            }
          }
        }
        """
        let request = makeHTTPRequest(
            headers: [
                ("MCP-Protocol-Version", "2026-07-28"),
                ("Mcp-Method", "tools/call"),
                ("Mcp-Name", "wait_for_events"),
            ],
            body: body
        )

        let chunksBox = LockedBox<[Data]>([])
        let headCalledBeforeChunksBox = LockedBox<Bool>(false)
        let outcome = await dispatcher.dispatch(
            request: request,
            agent: testAgent,
            onSSEHead: { headData in
                let headString = String(decoding: headData, as: UTF8.self)
                if headString.contains("Content-Type: text/event-stream\r\n") {
                    headCalledBeforeChunksBox.withValue { $0 = chunksBox.get().isEmpty }
                }
            },
            onSSEChunk: { chunk in
                chunksBox.withValue { $0.append(chunk) }
            }
        )
        let chunks = chunksBox.get()
        XCTAssertTrue(headCalledBeforeChunksBox.get(), "onSSEHead must fire before any SSE body chunk")

        guard case .sse(let headBytes) = outcome else {
            return XCTFail("Expected SSE promotion when progressToken is present")
        }
        let headText = String(decoding: headBytes, as: UTF8.self)
        XCTAssertTrue(headText.contains("Content-Type: text/event-stream\r\n"))
        XCTAssertTrue(headText.contains("X-Accel-Buffering: no\r\n"))

        let allRawSSE = String(decoding: chunks.reduce(Data(), +), as: UTF8.self)
        XCTAssertTrue(allRawSSE.hasPrefix(": connected\n\n"), "Must begin with welcome comment")
        XCTAssertTrue(allRawSSE.contains(": keep-alive\n\n"), "Must emit keep-alive comments")

        // Parse all SSE frames via SSEFrameParser
        var parser = SSEFrameParser()
        var events: [SSEFrameParser.Frame] = []
        for line in allRawSSE.components(separatedBy: "\n") {
            if let ev = try parser.consume(line: line) {
                events.append(ev)
            }
        }
        if let trailing = parser.finish() {
            events.append(trailing)
        }

        // Verify progress notifications are strictly increasing (1, 2, ...) and precede the final result
        var progressValues: [Int] = []
        var finalResultIndex: Int?
        for (idx, ev) in events.enumerated() {
            let json = try parseJSONObject(Data(ev.data.utf8))
            if json["method"] as? String == "notifications/progress" {
                XCTAssertNil(finalResultIndex, "Progress must never be emitted with or after the final response")
                let params = try XCTUnwrap(json["params"] as? [String: Any])
                XCTAssertEqual(params["progressToken"] as? String, "prog-77")
                let step = try XCTUnwrap(params["progress"] as? Int)
                progressValues.append(step)
            } else if json["id"] as? Int == 77 {
                finalResultIndex = idx
            }
        }

        XCTAssertGreaterThanOrEqual(progressValues.count, 2, "0.52s call with 0.2s tick should emit >= 2 progress steps")
        XCTAssertEqual(progressValues, Array(1...progressValues.count), "Progress steps must be strictly increasing 1, 2, ...")
        XCTAssertEqual(finalResultIndex, events.count - 1, "Final response must be the last SSE event")

        // Verify the final chunk contains ONLY the final response event, never bundled with a progress notification in the same tick
        let lastChunkString = String(decoding: try XCTUnwrap(chunks.last), as: UTF8.self)
        XCTAssertFalse(lastChunkString.contains("notifications/progress"), "Progress must not be sent in the same tick as the final response")
    }

    // MARK: - 7. Cancellation Rules by Era (§7.3)

    func testLegacyNotificationsCancelledAndModernStreamCloseCancellation() async throws {
        let cancelStarted = expectation(description: "in-flight legacy call started")
        let wasCancelledBox = ManagedAtomicFlag()

        let stubHost = ClosureHostedMCPToolExecutor { name, _, _, _, isCancelled in
            cancelStarted.fulfill()
            while !isCancelled() && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
            wasCancelledBox.set()
            return ToolExecutionResult(
                toolName: name,
                argumentsJSON: "{}",
                outputJSON: #"{"ok":false,"error":{"code":"cancelled"}}"#,
                isError: true
            )
        }
        let dispatcher = HostedMCPDispatcher(
            toolExecutor: stubHost,
            serverVersion: "2.0.0",
            agentTextVersion: "deadbeef12345678"
        )

        // Initialize two legacy sessions for the same agent
        let initBody = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}"#
        let init1 = await dispatcher.handlePOST(request: makeHTTPRequest(headers: [], body: initBody), agent: testAgent)
        let init2 = await dispatcher.handlePOST(request: makeHTTPRequest(headers: [], body: initBody), agent: testAgent)
        let sessionA = try XCTUnwrap(responseHeader(init1, "Mcp-Session-Id"))
        let sessionB = try XCTUnwrap(responseHeader(init2, "Mcp-Session-Id"))

        // Start a long-running call in sessionA with id 50
        let call50Body = #"{"jsonrpc":"2.0","id":50,"method":"tools/call","params":{"name":"wait_for_events","arguments":{"timeout_seconds":5}}}"#
        let req50A = makeHTTPRequest(
            headers: [("Mcp-Session-Id", sessionA), ("MCP-Protocol-Version", "2025-11-25")],
            body: call50Body
        )
        let agent = testAgent
        let inFlightTaskA = Task {
            await dispatcher.handlePOST(
                request: req50A,
                agent: agent
            )
        }

        await fulfillment(of: [cancelStarted], timeout: 2.0)

        // Sending notifications/cancelled for sessionB (wrong session) does NOT cancel sessionA's request 50
        let cancelWrongSession = await dispatcher.handlePOST(
            request: makeHTTPRequest(
                headers: [("Mcp-Session-Id", sessionB), ("MCP-Protocol-Version", "2025-11-25")],
                body: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":50}}"#
            ),
            agent: testAgent
        )
        XCTAssertEqual(cancelWrongSession.statusCode, 202)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(wasCancelledBox.get(), "Wrong session must not cancel sessionA's request")

        // Sending notifications/cancelled for sessionA cancels sessionA's request 50
        let cancelRightSession = await dispatcher.handlePOST(
            request: makeHTTPRequest(
                headers: [("Mcp-Session-Id", sessionA), ("MCP-Protocol-Version", "2025-11-25")],
                body: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":50}}"#
            ),
            agent: testAgent
        )
        XCTAssertEqual(cancelRightSession.statusCode, 202)
        _ = await inFlightTaskA.value
        XCTAssertTrue(wasCancelledBox.get(), "Matching (agent, session, requestId) must cancel the in-flight request")
    }

    func testAmbiguousLegacyCancellationWithoutSessionIsIgnoredAndDisconnectDoesNotCancelLegacy() async throws {
        let bothStarted = expectation(description: "both in-flight calls started")
        bothStarted.expectedFulfillmentCount = 2
        let releaseGate = ManagedAtomicFlag()
        let cancelledCount = LockedCounter()

        let stubHost = ClosureHostedMCPToolExecutor { name, _, _, _, isCancelled in
            bothStarted.fulfill()
            while !releaseGate.get() && !isCancelled() {
                try? await Task.sleep(for: .milliseconds(10))
            }
            if isCancelled() {
                cancelledCount.increment()
            }
            return ToolExecutionResult(toolName: name, argumentsJSON: "{}", outputJSON: #"{"ok":true}"#, isError: false)
        }
        let dispatcher = HostedMCPDispatcher(
            toolExecutor: stubHost,
            serverVersion: "2.0.0",
            agentTextVersion: "deadbeef12345678"
        )

        let initBody = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}"#
        let initRespS1 = await dispatcher.handlePOST(request: makeHTTPRequest(headers: [], body: initBody), agent: testAgent)
        let initRespS2 = await dispatcher.handlePOST(request: makeHTTPRequest(headers: [], body: initBody), agent: testAgent)
        let s1 = try XCTUnwrap(responseHeader(initRespS1, "Mcp-Session-Id"))
        let s2 = try XCTUnwrap(responseHeader(initRespS2, "Mcp-Session-Id"))

        let callBody = #"{"jsonrpc":"2.0","id":88,"method":"tools/call","params":{"name":"wait_for_events","arguments":{"timeout_seconds":5}}}"#
        let reqS1 = makeHTTPRequest(headers: [("Mcp-Session-Id", s1), ("MCP-Protocol-Version", "2025-11-25")], body: callBody)
        let reqS2 = makeHTTPRequest(headers: [("Mcp-Session-Id", s2), ("MCP-Protocol-Version", "2025-11-25")], body: callBody)
        let agent = testAgent
        let t1 = Task {
            await dispatcher.handlePOST(
                request: reqS1,
                agent: agent
            )
        }
        let t2 = Task {
            await dispatcher.handlePOST(
                request: reqS2,
                agent: agent
            )
        }

        await fulfillment(of: [bothStarted], timeout: 2.0)

        // Ambiguous notifications/cancelled WITHOUT Mcp-Session-Id when two sessions have requestId=88 in flight -> ignored!
        let ambigCancel = await dispatcher.handlePOST(
            request: makeHTTPRequest(
                headers: [("MCP-Protocol-Version", "2025-11-25")],
                body: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":88}}"#
            ),
            agent: testAgent
        )
        XCTAssertEqual(ambigCancel.statusCode, 202)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(cancelledCount.get(), 0, "Ambiguous cancel without sessionID must be ignored")

        releaseGate.set()
        let released1 = await t1.value
        let released2 = await t2.value
        XCTAssertEqual(released1.statusCode, 200, "the ignored cancel left the first session's call to finish")
        XCTAssertEqual(released2.statusCode, 200, "the ignored cancel left the second session's call to finish")
        XCTAssertEqual(cancelledCount.get(), 0)
    }

    func testModernStreamCloseCancelsInFlightReadRequest() async throws {
        let readStarted = expectation(description: "modern read started")
        let observedCancel = expectation(description: "modern read observed cancellation")

        let stubHost = ClosureHostedMCPToolExecutor { name, _, _, _, isCancelled in
            readStarted.fulfill()
            while !isCancelled() && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
            observedCancel.fulfill()
            return ToolExecutionResult(toolName: name, argumentsJSON: "{}", outputJSON: #"{"ok":false}"#, isError: true)
        }
        let dispatcher = HostedMCPDispatcher(
            toolExecutor: stubHost,
            serverVersion: "2.0.0",
            agentTextVersion: "deadbeef12345678"
        )

        let body = """
        {"jsonrpc":"2.0","id":101,"method":"tools/call","params":{"name":"wait_for_events","arguments":{"timeout_seconds":5},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
        """
        let req = makeHTTPRequest(
            headers: [
                ("MCP-Protocol-Version", "2026-07-28"),
                ("Mcp-Method", "tools/call"),
                ("Mcp-Name", "wait_for_events"),
            ],
            body: body
        )
        let agent = testAgent
        let callTask = Task {
            await dispatcher.handlePOST(request: req, agent: agent)
        }
        await fulfillment(of: [readStarted], timeout: 2.0)
        callTask.cancel()
        await fulfillment(of: [observedCancel], timeout: 2.0)
        _ = await callTask.value
    }

    // MARK: - 8. Catalog & Instructions Invariants (§8.1, §8.2)

    func testCatalogExposesEveryToolWithReadOnlyHintsMaxResultSizeOnReadArtifactAndTaskChangesAndDepthAtMost3() throws {
        let tools = HostedMCPCatalog.allTools
        XCTAssertEqual(tools.map(\.name), ExternalAutovisorToolNames.all)
        // Published since 2026-11-13 (decision A3, revised): the person allows it per agent.
        XCTAssertTrue(tools.map(\.name).contains(ToolNames.setWorkFolderContext))

        let expectedReadOnly: Set<String> = [
            ExternalAutovisorToolNames.folderStatus,
            ExternalAutovisorToolNames.listTeams,
            ExternalAutovisorToolNames.listTasks,
            ExternalAutovisorToolNames.taskStatus,
            ExternalAutovisorToolNames.waitForEvents,
            ExternalAutovisorToolNames.taskResult,
            ExternalAutovisorToolNames.readArtifact,
            ExternalAutovisorToolNames.taskLog,
            ExternalAutovisorToolNames.taskChanges,
        ]

        for tool in tools {
            XCTAssertEqual(
                tool.readOnlyHint,
                expectedReadOnly.contains(tool.name),
                "readOnlyHint mismatch on \(tool.name)"
            )
            let wire = tool.wireJSON.objectValue
            let annotations = try XCTUnwrap(wire?["annotations"]?.objectValue)
            XCTAssertEqual(annotations["readOnlyHint"]?.boolValue, expectedReadOnly.contains(tool.name))
            XCTAssertNil(annotations["openWorldHint"], "openWorldHint must not be set (§8.1)")

            if tool.name == ExternalAutovisorToolNames.readArtifact {
                let meta = try XCTUnwrap(wire?["_meta"]?.objectValue)
                XCTAssertEqual(meta["anthropic/maxResultSizeChars"]?.intValue, 500_000)
            } else if tool.name == ExternalAutovisorToolNames.taskChanges {
                let meta = try XCTUnwrap(wire?["_meta"]?.objectValue, "_meta must appear on task_changes")
                XCTAssertEqual(meta["anthropic/maxResultSizeChars"]?.intValue, 250_000)
            } else {
                XCTAssertNil(wire?["_meta"], "_meta must only appear on read_artifact and task_changes")
            }

            // Verify schema nesting depth <= 3 (CLAUDE.md #46)
            for (_, prop) in tool.inputSchema.properties ?? [:] {
                XCTAssertNil(prop.properties, "Nested object properties inside properties would exceed depth 3 on \(tool.name)")
            }
        }

        // Instructions checks (§8.2)
        let instructions = HostedMCPInstructions.text
        XCTAssertLessThanOrEqual(instructions.count, 4096)
        let first512 = String(instructions.prefix(512))
        XCTAssertTrue(first512.contains("folder_status"))
        XCTAssertTrue(first512.contains("folder_id"))
        XCTAssertFalse(instructions.localizedCaseInsensitiveContains("unreachable"))
    }

    @MainActor
    func testToolHostRoutesFolderStatusWithoutFolderAndRefusesOtherToolsWhenNotReady() async throws {
        let orchestrator = TestOrchestrator.make()
        let host = HostedMCPToolHost(orchestrator: orchestrator)

        // `folder_status` without an active folder returns `isError: false` (`ok: true`, `state: "no_folder"`)
        let statusResult = await host.executeTool(
            name: ExternalAutovisorToolNames.folderStatus,
            arguments: [:],
            agent: testAgent,
            sessionID: nil,
            isCancelled: { false }
        )
        XCTAssertFalse(statusResult.isError)
        let statusJSON = try parseJSONObject(Data(statusResult.outputJSON.utf8))
        XCTAssertEqual(statusJSON["ok"] as? Bool, true)
        let statusData = try XCTUnwrap(statusJSON["data"] as? [String: Any])
        let readiness = try XCTUnwrap(statusData["readiness"] as? [String: Any])
        XCTAssertEqual(readiness["state"] as? String, "no_work_folder")

        // `list_teams` without an active folder returns `isError: true` with `COMMAND_FAILED`
        let teamsResult = await host.executeTool(
            name: ExternalAutovisorToolNames.listTeams,
            arguments: [:],
            agent: testAgent,
            sessionID: nil,
            isCancelled: { false }
        )
        XCTAssertTrue(teamsResult.isError)
        let teamsJSON = try parseJSONObject(Data(teamsResult.outputJSON.utf8))
        XCTAssertEqual(teamsJSON["ok"] as? Bool, false)
        let teamsErr = try XCTUnwrap(teamsJSON["error"] as? [String: Any])
        XCTAssertEqual(teamsErr["code"] as? String, "COMMAND_FAILED")

        // Unknown tool returns `isError: true` with `INVALID_ARGS` — an in-app tool the hosted
        // catalog does not publish.
        let unknownResult = await host.executeTool(
            name: ToolNames.updateScratchpad,
            arguments: [:],
            agent: testAgent,
            sessionID: nil,
            isCancelled: { false }
        )
        XCTAssertTrue(unknownResult.isError)
        let unknownJSON = try parseJSONObject(Data(unknownResult.outputJSON.utf8))
        let unknownErr = try XCTUnwrap(unknownJSON["error"] as? [String: Any])
        XCTAssertEqual(unknownErr["code"] as? String, "INVALID_ARGS")

        // Open a real folder and exercise read + write + cancelled paths on HostedMCPToolHost
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolHostTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        await orchestrator.openWorkFolder(tempDir)
        if let nonChat = orchestrator.snapshot?.workFolder.teams.first(where: { !$0.isChatMode && !$0.isHiddenFromPickers }) {
            await orchestrator.mutateWorkFolder { $0.setActiveTeam(nonChat.id) }
        }
        await orchestrator.setAutovisorDriver(.externalAgent)
        await orchestrator.setAutovisorEnabled(true)
        let folderID = try XCTUnwrap(orchestrator.snapshot?.projection.id.uuidString)

        let readyTeams = await host.executeTool(
            name: ExternalAutovisorToolNames.listTeams,
            arguments: ["folder_id": .string(folderID)],
            agent: testAgent,
            sessionID: "s1",
            isCancelled: { false }
        )
        XCTAssertFalse(readyTeams.isError, readyTeams.outputJSON)

        let writeCreate = await host.executeTool(
            name: ExternalAutovisorToolNames.createManagedTask,
            arguments: ["folder_id": .string(folderID), "title": "Hosted Write", "brief": "Brief"],
            agent: testAgent,
            sessionID: "s1",
            isCancelled: { false }
        )
        XCTAssertFalse(writeCreate.isError, writeCreate.outputJSON)

        // Every JSON value the wire carries reaches the orchestrator as the Foundation value its
        // argument helpers read: an `.int` stays an Int, `.null` is NSNull, containers recurse.
        let native = HostedMCPToolHost.toNativeArguments([
            "s": .string("x"), "i": .int(5), "d": .double(1.5), "b": .bool(true),
            "a": .array([.int(1), .string("y")]), "o": .object(["k": .null]), "n": .null,
        ])
        XCTAssertEqual(native["s"] as? String, "x")
        XCTAssertEqual(native["i"] as? Int, 5)
        XCTAssertEqual(native["d"] as? Double, 1.5)
        XCTAssertEqual(native["b"] as? Bool, true)
        let nativeArray = try XCTUnwrap(native["a"] as? [Any])
        XCTAssertEqual(nativeArray.first as? Int, 1)
        XCTAssertEqual(nativeArray.last as? String, "y")
        let nativeObject = try XCTUnwrap(native["o"] as? [String: Any])
        XCTAssertTrue(nativeObject["k"] is NSNull)
        XCTAssertTrue(native["n"] is NSNull)

        // HostedMCPCancellationToken idempotent cancel() and post-cancel onCancel()
        let token = HostedMCPCancellationToken()
        token.cancel()
        token.cancel()
        let firedExp = expectation(description: "fired immediately")
        token.onCancel { firedExp.fulfill() }
        await fulfillment(of: [firedExp], timeout: 1.0)
    }

    func testDispatcherCancelAllAndLegacyToolsListAndCallErrors() async throws {
        let entered = expectation(description: "entered tool")
        let entered2 = expectation(description: "entered tool 2")
        let stubHost = ClosureHostedMCPToolExecutor { name, _, _, _, isCancelled in
            if name == ExternalAutovisorToolNames.waitForEvents {
                entered.fulfill()
                while !isCancelled() && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            } else if name == ExternalAutovisorToolNames.listTasks {
                entered2.fulfill()
                while !isCancelled() && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            return ToolExecutionResult(toolName: name, argumentsJSON: "{}", outputJSON: #"{"ok":true}"#, isError: false)
        }
        let dispatcher = HostedMCPDispatcher(
            toolExecutor: stubHost,
            serverVersion: "2.0.0",
            agentTextVersion: "deadbeef12345678"
        )
        let initBody = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}"#
        let initResp = await dispatcher.handlePOST(request: makeHTTPRequest(headers: [], body: initBody), agent: testAgent)
        let sessionID = try XCTUnwrap(responseHeader(initResp, "Mcp-Session-Id"))

        // Legacy tools/list
        let listResp = await dispatcher.handlePOST(
            request: makeHTTPRequest(
                headers: [("Mcp-Session-Id", sessionID), ("MCP-Protocol-Version", "2025-11-25")],
                body: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
            ),
            agent: testAgent
        )
        XCTAssertEqual(listResp.statusCode, 200)

        // Legacy tools/call missing name -> -32602
        let missingNameResp = await dispatcher.handlePOST(
            request: makeHTTPRequest(
                headers: [("Mcp-Session-Id", sessionID), ("MCP-Protocol-Version", "2025-11-25")],
                body: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{}}"#
            ),
            agent: testAgent
        )
        XCTAssertEqual(missingNameResp.statusCode, 400)
        let missingNameError = try XCTUnwrap(try parseJSONObject(missingNameResp.body)["error"] as? [String: Any])
        XCTAssertEqual(missingNameError["code"] as? Int, -32602)

        // A tools/call naming a tool outside the catalog is not refused by the dispatcher: it is
        // forwarded, and the executor answers it (the orchestrator with an INVALID_ARGS tool error).
        let unknownToolResp = await dispatcher.handlePOST(
            request: makeHTTPRequest(
                headers: [("Mcp-Session-Id", sessionID), ("MCP-Protocol-Version", "2025-11-25")],
                body: #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"no_such_tool","arguments":{}}}"#
            ),
            agent: testAgent
        )
        XCTAssertEqual(unknownToolResp.statusCode, 200)

        // Start in-flight request and cancel via cancelAllRequests(forAgent:)
        let agent = testAgent
        let req1 = makeHTTPRequest(
            headers: [("Mcp-Session-Id", sessionID), ("MCP-Protocol-Version", "2025-11-25")],
            body: #"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"wait_for_events","arguments":{}}}"#
        )
        let t1 = Task { await dispatcher.handlePOST(request: req1, agent: agent) }
        await fulfillment(of: [entered], timeout: 2.0)
        dispatcher.cancelAllRequests(forAgent: agent.id)
        let cancelledForAgent = await t1.value
        XCTAssertEqual(cancelledForAgent.statusCode, 200, "the agent's parked call returned once cancelled")

        // Start another in-flight request and cancel via cancelAllRequests()
        let req2 = makeHTTPRequest(
            headers: [("Mcp-Session-Id", sessionID), ("MCP-Protocol-Version", "2025-11-25")],
            body: #"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"list_tasks","arguments":{}}}"#
        )
        let t2 = Task { await dispatcher.handlePOST(request: req2, agent: agent) }
        await fulfillment(of: [entered2], timeout: 2.0)
        dispatcher.cancelAllRequests()
        let cancelledForAll = await t2.value
        XCTAssertEqual(cancelledForAll.statusCode, 200, "the parked call returned once every request was cancelled")

        // Additional notification, rate-limit, initialize, and tools/call branches
        let notifMismatch = await dispatcher.handlePOST(
            request: makeHTTPRequest(
                headers: [("MCP-Protocol-Version", "2025-11-25")],
                body: #"{"jsonrpc":"2.0","method":"notifications/initialized","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#
            ),
            agent: testAgent
        )
        XCTAssertEqual(notifMismatch.statusCode, 400)

        let notifBadModern = await dispatcher.handlePOST(
            request: makeHTTPRequest(
                headers: [("MCP-Protocol-Version", "2099-01-01")],
                body: #"{"jsonrpc":"2.0","method":"notifications/initialized","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2099-01-01"}}}"#
            ),
            agent: testAgent
        )
        XCTAssertEqual(notifBadModern.statusCode, 400)

        let notifBadLegacy = await dispatcher.handlePOST(
            request: makeHTTPRequest(
                headers: [("MCP-Protocol-Version", "1999-01-01")],
                body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
            ),
            agent: testAgent
        )
        XCTAssertEqual(notifBadLegacy.statusCode, 400)

        let missingVerInit = await dispatcher.handlePOST(
            request: makeHTTPRequest(
                headers: [],
                body: #"{"jsonrpc":"2.0","id":20,"method":"initialize","params":{}}"#
            ),
            agent: testAgent
        )
        XCTAssertEqual(missingVerInit.statusCode, 400)

        // Create a fresh session for legacy unknown method, non-object arguments, omitted arguments, and sessionless single-request cancel
        let initResp2 = await dispatcher.handlePOST(request: makeHTTPRequest(headers: [], body: initBody), agent: testAgent)
        let sessionID2 = try XCTUnwrap(responseHeader(initResp2, "Mcp-Session-Id"))

        let legacyUnknown = await dispatcher.handlePOST(
            request: makeHTTPRequest(
                headers: [("Mcp-Session-Id", sessionID2), ("MCP-Protocol-Version", "2025-11-25")],
                body: #"{"jsonrpc":"2.0","id":21,"method":"unknown/method"}"#
            ),
            agent: testAgent
        )
        XCTAssertEqual(legacyUnknown.statusCode, 400)

        let badArgsCall = await dispatcher.handlePOST(
            request: makeHTTPRequest(
                headers: [("Mcp-Session-Id", sessionID2), ("MCP-Protocol-Version", "2025-11-25")],
                body: #"{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"folder_status","arguments":[1,2]}}"#
            ),
            agent: testAgent
        )
        XCTAssertEqual(badArgsCall.statusCode, 400)

        let omittedArgsCall = await dispatcher.handlePOST(
            request: makeHTTPRequest(
                headers: [("Mcp-Session-Id", sessionID2), ("MCP-Protocol-Version", "2025-11-25")],
                body: #"{"jsonrpc":"2.0","id":23,"method":"tools/call","params":{"name":"folder_status"}}"#
            ),
            agent: testAgent
        )
        XCTAssertEqual(omittedArgsCall.statusCode, 200)

        // Legacy notifications/cancelled without Mcp-Session-Id while exactly one request with that string id is in flight
        let entered3 = expectation(description: "entered tool 3")
        let stubHost3 = ClosureHostedMCPToolExecutor { name, _, _, _, isCancelled in
            entered3.fulfill()
            while !isCancelled() && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return ToolExecutionResult(toolName: name, argumentsJSON: "{}", outputJSON: #"{"ok":true}"#, isError: false)
        }
        let disp3 = HostedMCPDispatcher(toolExecutor: stubHost3, serverVersion: "2.0.0", agentTextVersion: "v")
        let init3 = await disp3.handlePOST(request: makeHTTPRequest(headers: [], body: initBody), agent: testAgent)
        let sid3 = try XCTUnwrap(responseHeader(init3, "Mcp-Session-Id"))
        let req3 = makeHTTPRequest(
            headers: [("Mcp-Session-Id", sid3), ("MCP-Protocol-Version", "2025-11-25")],
            body: #"{"jsonrpc":"2.0","id":"str-req-1","method":"tools/call","params":{"name":"wait_for_events"}}"#
        )
        let t3 = Task { await disp3.handlePOST(request: req3, agent: agent) }
        await fulfillment(of: [entered3], timeout: 2.0)
        let cancelNoSession = await disp3.handlePOST(
            request: makeHTTPRequest(
                headers: [("MCP-Protocol-Version", "2025-11-25")],
                body: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"str-req-1"}}"#
            ),
            agent: testAgent
        )
        XCTAssertEqual(cancelNoSession.statusCode, 202)
        _ = await t3.value

        // Rate-limited initialize and legacy ping
        let zeroRateDisp = HostedMCPDispatcher(
            toolExecutor: stubHost3,
            serverVersion: "2.0.0",
            agentTextVersion: "v",
            rateLimitConfig: HostedMCPRateLimitConfiguration(capacity: 1, refillPerSecond: 0.001)
        )
        let rlInit1 = await zeroRateDisp.handlePOST(request: makeHTTPRequest(headers: [], body: initBody), agent: testAgent)
        let rlSession = try XCTUnwrap(responseHeader(rlInit1, "Mcp-Session-Id"))
        let rlInit2 = await zeroRateDisp.handlePOST(request: makeHTTPRequest(headers: [], body: initBody), agent: testAgent)
        XCTAssertEqual(rlInit2.statusCode, 429)
        let rlPing = await zeroRateDisp.handlePOST(
            request: makeHTTPRequest(
                headers: [("Mcp-Session-Id", rlSession), ("MCP-Protocol-Version", "2025-11-25")],
                body: #"{"jsonrpc":"2.0","id":30,"method":"ping"}"#
            ),
            agent: testAgent
        )
        XCTAssertEqual(rlPing.statusCode, 429)
    }

    func testDecodeSentinelHeaderValue_andBadJSONRPCId() async throws {
        XCTAssertEqual(HostedMCPDispatcher.decodeSentinelHeaderValue(""), "")
        XCTAssertEqual(HostedMCPDispatcher.decodeSentinelHeaderValue("   "), "")
        XCTAssertEqual(HostedMCPDispatcher.decodeSentinelHeaderValue("=?base64?short"), "=?base64?short")
        XCTAssertEqual(HostedMCPDispatcher.decodeSentinelHeaderValue("=?base64??="), "")
        XCTAssertNil(HostedMCPDispatcher.decodeSentinelHeaderValue("=?base64?!!!?="))
        XCTAssertEqual(HostedMCPDispatcher.decodeSentinelHeaderValue("normal string"), "normal string")

        let stubHost = ClosureHostedMCPToolExecutor { name, _, _, _, _ in
            ToolExecutionResult(toolName: name, argumentsJSON: "{}", outputJSON: #"{"ok":true}"#, isError: false)
        }
        let dispatcher = HostedMCPDispatcher(
            toolExecutor: stubHost,
            serverVersion: "2.0.0",
            agentTextVersion: "deadbeef12345678"
        )
        // Call with boolean id (invalid JSON-RPC id):
        let badIdResp = await dispatcher.handlePOST(
            request: makeHTTPRequest(
                headers: [],
                body: #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#
            ),
            agent: testAgent
        )
        XCTAssertEqual(badIdResp.statusCode, 400)
    }
}

private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func get() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) {
        self.value = value
    }

    func get() -> T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: T) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func withValue(_ mutate: (inout T) -> Void) {
        lock.lock()
        mutate(&value)
        lock.unlock()
    }
}
