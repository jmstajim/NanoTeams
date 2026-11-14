import AppKit
import SwiftUI
import XCTest
@testable import NanoTeams

/// The window that opens an external agent's call in full (2026-11-08).
///
/// The point of loading INSIDE the window is the failure path: a call that will not load must
/// say so where the person is looking. The app's error banner cannot — it is cleared while any
/// external call is in flight (`NTMSOrchestrator.externalErrorSuppressionDepth`), and an agent
/// waiting for events always has one — so a tap on a row whose file is gone would have done
/// nothing visible.
@MainActor
final class ExternalAgentCallDetailBodyTests: XCTestCase {

    /// Loads the window body has run, counted on the test case (a captured local cannot be
    /// mutated from the `@MainActor` load closure).
    private var loads: Int!

    override func setUp() async throws {
        try await super.setUp()
        loads = 0
    }

    override func tearDown() async throws {
        loads = nil
        try await super.tearDown()
    }

    private var call: ExternalAutovisorFullCall {
        ExternalAutovisorFullCall(
            id: UUID(uuidString: "6A0C2E64-3D1B-4E4B-9C0D-2F5E7A1B8C90")!,
            arguments: #"{"folder_id":"3A779B43"}"#,
            response: #"{"ok":true,"data":{"goal":"Ship the calculator"}}"#
        )
    }

    func testAMissingCallBecomesTheUnavailableState() async {
        let phase = await ExternalAgentCallDetailBody.phase(after: { nil })
        XCTAssertEqual(phase, .unavailable)
        XCTAssertFalse(ExternalAgentCallDetailBody.unavailableMessage.isEmpty)
    }

    func testALoadedCallIsShownWhole() async {
        let loaded = call
        let phase = await ExternalAgentCallDetailBody.phase(after: { loaded })
        XCTAssertEqual(phase, .loaded(loaded))
    }

    /// The window body mounts, runs its load, and lays out the failure state without a store.
    func testTheBodyMountsAndLoads() async {
        let body = ExternalAgentCallDetailBody(
            toolName: ExternalAutovisorToolNames.folderStatus,
            isError: false,
            createdAt: Date(timeIntervalSince1970: 1_794_200_000),
            load: { [self] in
                loads += 1
                return nil
            }
        )
        let hosting = NSHostingView(rootView: body.frame(width: 480, height: 320))
        hosting.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        for _ in 0..<200 where loads == 0 {
            try? await Task.sleep(for: .milliseconds(10))
            hosting.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(loads, 1, "the window loads its call once, when it appears")
        window.contentView = nil
    }
}
