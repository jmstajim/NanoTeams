import XCTest

@testable import NanoTeams

/// What happens to a screenshot after the OS has produced it — `deliverCapture`.
///
/// Two things are decided here, and both are silent when wrong. First, WHICH CHANNEL carries
/// the pixels: a vision-capable main model gets the image in-chat, a text-only one gets a
/// description from the Vision model. Second, and more consequential, whether clicks start
/// resolving against THIS capture. Committing that state on a path where delivery failed would
/// re-point the coordinate space at a screenshot the model never received — every subsequent
/// click aimed at what it last saw would land somewhere else entirely, and the envelope would
/// still say `ok`.
///
/// Producing a real `CapturedScreen` means taking a real screenshot (Screen Recording TCC), so
/// the capture and its element list are constructed directly and only the delivery half runs.
@MainActor
final class ComputerUseCaptureDeliveryTests: XCTestCase, @unchecked Sendable {

    private var sut: LLMExecutionService!
    private var client: ScriptedVisionClient!
    /// `LLMExecutionService.delegate` is WEAK — a locally-created double deallocates before the
    /// first call reads it, and every "no Vision configured" branch fires instead of the one
    /// under test. Held here for the test's lifetime.
    private var delegate: MockLLMExecutionDelegate!

    override func setUp() async throws {
        try await super.setUp()
        sut = LLMExecutionService(repository: NTMSRepository())
        client = ScriptedVisionClient()
    }

    override func tearDown() async throws {
        sut = nil
        client = nil
        delegate = nil
        try await super.tearDown()
    }

    // MARK: - Doubles

    /// Scripts both halves the delivery path asks of a client: whether the MAIN model can see
    /// images, and what the VISION model says when asked to describe one.
    private final class ScriptedVisionClient: LLMClient, @unchecked Sendable {
        nonisolated(unsafe) var mainModelSeesImages: Bool? = false
        nonisolated(unsafe) var visionDescription: String? = "A window with a Post button."
        nonisolated(unsafe) var visionError: Error?

        func modelSupportsVision(config _: LLMConfig) async -> Bool? { mainModelSeesImages }

        func streamChat(
            config _: LLMConfig, messages _: [ChatMessage], tools _: [ToolSchema],
            logger _: NetworkLogger?, stepID _: String?, roleName _: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            let error = visionError
            let text = visionDescription
            return AsyncThrowingStream { continuation in
                if let error {
                    continuation.finish(throwing: error)
                    return
                }
                if let text { continuation.yield(StreamEvent(contentDelta: text)) }
                continuation.finish()
            }
        }

        func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
    }

    private struct VisionUnavailable: Error {}

    /// Installs the module's full-protocol delegate double, retained by the test. Only
    /// `visionLLMConfig` matters here; `nil` means "Vision is not configured".
    private func installDelegate(vision config: LLMConfig?) {
        delegate = MockLLMExecutionDelegate()
        delegate.visionLLMConfig = config
        sut.delegate = delegate
    }

    private func visionConfig() -> LLMConfig {
        LLMConfig(provider: .lmStudio, baseURLString: "http://localhost:1234",
                  modelName: "vision", temperature: nil)
    }

    // MARK: - Fixtures

    // `nonisolated` is load-bearing, not decoration: these are called from DEFAULT ARGUMENT
    // expressions below, and a default argument inherits the enclosing declaration's isolation
    // only under Swift 6 language mode (SE-0411). The mirror's CI still compiles this target with
    // `-swift-version 5`, where default arguments are evaluated NONISOLATED — so without this the
    // call is "main actor-isolated static method in a synchronous nonisolated context" there and
    // legal here, i.e. a build that is green locally and red on CI. Safe by construction: these
    // build only `nonisolated ... Sendable` value types.
    nonisolated private static func makeCapture() -> CapturedScreen {
        CapturedScreen(
            pngBase64: "QUJD", pixelWidth: 100, pixelHeight: 80,
            regionWidthPt: 100, regionHeightPt: 80, originX: 0, originY: 0,
            targetKind: "window", appName: "Safari", bundleID: "com.apple.Safari",
            windowTitle: "Feed | LinkedIn", displayID: nil, pid: nil)
    }

    nonisolated private static func makeElements() -> [AXElementInfo] {
        [AXElementInfo(role: "AXButton", label: "Post", x: 10, y: 10, w: 20, h: 20,
                       cx: 20, cy: 20, web: true)]
    }

    private func collection(
        elements: [AXElementInfo] = makeElements(),
        warnings: [String] = [],
        totalAfterDedup: Int? = nil
    ) -> AXCollectionResult {
        AXCollectionResult(
            elements: elements,
            totalAfterDedup: totalAfterDedup ?? elements.count,
            warnings: warnings)
    }

    private struct Delivery {
        let messages: [ChatMessage]
        var toolEnvelope: String { messages.first(where: { $0.role == .tool })?.content ?? "" }
        var json: [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(toolEnvelope.utf8))) as? [String: Any] ?? [:]
        }
        var ok: Bool { json["ok"] as? Bool ?? false }
        var data: [String: Any] { json["data"] as? [String: Any] ?? [:] }
        var warnings: [String] { (json["meta"] as? [String: Any])?["warnings"] as? [String] ?? [] }
        var imageTurns: [ChatMessage] { messages.filter { !($0.imageContent?.isEmpty ?? true) } }
        var userTurns: [ChatMessage] { messages.filter { $0.role == .user } }
    }

    @discardableResult
    private func deliver(
        captured: CapturedScreen = makeCapture(),
        collection: AXCollectionResult? = nil,
        target: String = "Safari",
        stepID: String = "role-1",
        taskID: Int = 1
    ) async -> Delivery {
        var messages: [ChatMessage] = []
        sut._testRegisterStepTask(stepID: stepID, taskID: taskID)
        await sut.deliverCapture(
            captured: captured, collection: collection ?? self.collection(),
            target: target, key: TaskStepKey(taskID: taskID, stepID: stepID),
            client: client,
            config: LLMConfig(provider: .lmStudio, baseURLString: "http://localhost:1234",
                              modelName: "m1", temperature: nil),
            networkLogger: nil,
            result: ToolExecutionResult(
                providerID: "call-1", toolName: ToolNames.screenCapture,
                argumentsJSON: "{}", outputJSON: "", isError: false),
            toolCallID: UUID(), stepID: stepID, taskID: taskID,
            conversationMessages: &messages, tracker: nil)
        return Delivery(messages: messages)
    }

    // MARK: - The envelope

    /// Coordinates are the whole point of the envelope: the model reasons in image pixels and
    /// the click path converts back through exactly these numbers. A capture that shipped its
    /// region in points while the model aimed in pixels would miss by the Retina factor.
    func testEnvelope_carriesTheCoordinateSpaceAndRegionGeometry() async {
        client.mainModelSeesImages = true
        let d = await deliver()

        XCTAssertTrue(d.ok, d.toolEnvelope)
        XCTAssertEqual(d.data["coordinate_space"] as? String, "image_pixels")
        XCTAssertEqual(d.data["pixel_width"] as? Int, 100)
        XCTAssertEqual(d.data["pixel_height"] as? Int, 80)
        XCTAssertEqual(d.data["region_w_pt"] as? Double, 100)
        XCTAssertEqual(d.data["region_h_pt"] as? Double, 80)
    }

    func testEnvelope_identifiesWhatWasCaptured() async {
        client.mainModelSeesImages = true
        let d = await deliver()
        let target = d.data["target"] as? [String: Any] ?? [:]

        XCTAssertEqual(target["kind"] as? String, "window")
        XCTAssertEqual(target["app"] as? String, "Safari")
        XCTAssertEqual(target["window_title"] as? String, "Feed | LinkedIn")
    }

    /// The element list is what the model aims with. `cx`/`cy` ship; the top-left `x`/`y` does
    /// NOT — it doubles the coordinate tokens per element and is the corner a model once clicked
    /// by mistake. `web` rides only when true so native-app captures pay nothing for it.
    func testEnvelope_shipsCentresNotCornersAndTagsWebElements() async {
        client.mainModelSeesImages = true
        let d = await deliver()
        let first = (d.data["ax_elements"] as? [[String: Any]])?.first ?? [:]

        XCTAssertEqual(first["cx"] as? Int, 20)
        XCTAssertEqual(first["cy"] as? Int, 20)
        XCTAssertEqual(first["label"] as? String, "Post")
        XCTAssertEqual(first["web"] as? Bool, true)
        XCTAssertNil(first["x"], "the top-left corner must not ship")
        XCTAssertNil(first["y"])
    }

    func testEnvelope_nativeAppElement_omitsTheWebFlagEntirely() async {
        client.mainModelSeesImages = true
        let native = [AXElementInfo(role: "AXButton", label: "Save", x: 1, y: 1, w: 10, h: 10,
                                    cx: 6, cy: 6, web: false)]
        let d = await deliver(collection: collection(elements: native))
        let first = (d.data["ax_elements"] as? [[String: Any]])?.first ?? [:]

        XCTAssertNil(first["web"])
    }

    // MARK: - Warnings

    func testCollectionWarnings_areCarriedThrough() async {
        client.mainModelSeesImages = true
        let d = await deliver(collection: collection(warnings: ["walk stopped early"]))

        XCTAssertTrue(d.warnings.contains("walk stopped early"), "got: \(d.warnings)")
    }

    /// A capped element list must say so. Silently shipping a truncated roster reads as "these
    /// are all the controls", and the model concludes the button it wants doesn't exist.
    func testCappedElementList_isReportedAsTruncated() async {
        client.mainModelSeesImages = true
        let d = await deliver(collection: collection(totalAfterDedup: 500))
        let meta = d.json["meta"] as? [String: Any] ?? [:]

        XCTAssertEqual(meta["truncated"] as? Bool, true)
    }

    func testUncappedElementList_isNotReportedAsTruncated() async {
        client.mainModelSeesImages = true
        let d = await deliver()
        let meta = d.json["meta"] as? [String: Any] ?? [:]

        XCTAssertNotEqual(meta["truncated"] as? Bool, true)
    }

    /// Window resolution falls back to a window-TITLE match, so `target: "Notes"` can land on a
    /// Safari tab called "Release Notes" when Notes isn't running. The model must be told, or it
    /// operates the wrong app with perfectly valid-looking coordinates.
    func testTitleOnlyMatch_warnsThatADifferentAppWasCaptured() async {
        client.mainModelSeesImages = true
        let d = await deliver(target: "LinkedIn")

        XCTAssertTrue(d.warnings.contains { $0.contains("LinkedIn") },
                      "a title-only match must be surfaced: \(d.warnings)")
    }

    func testTargetMatchingTheApp_producesNoTitleWarning() async {
        client.mainModelSeesImages = true
        let d = await deliver(target: "Safari")

        XCTAssertFalse(d.warnings.contains { $0.contains("Safari") }, "got: \(d.warnings)")
    }

    // MARK: - Channel routing

    func testVisionCapableMainModel_receivesTheImageInChat() async {
        client.mainModelSeesImages = true

        let d = await deliver()

        XCTAssertEqual(d.imageTurns.count, 1, "the image rides its own user turn")
        XCTAssertEqual(d.imageTurns.first?.imageContent?.first?.base64Data, "QUJD")
        XCTAssertTrue(d.ok)
    }

    /// The caption has to retire the previous screenshot explicitly. Without it the model keeps
    /// mixing coordinates from an older capture into the new one's space.
    func testInChatImage_captionInvalidatesEarlierCaptures() async {
        client.mainModelSeesImages = true

        let d = await deliver()
        let caption = d.imageTurns.first?.content ?? ""

        XCTAssertTrue(caption.contains("no longer valid"), "got: \(caption)")
    }

    /// Text-only main model, Vision configured: the description arrives as an ordinary text turn.
    func testTextOnlyMainModel_receivesAVisionDescriptionAsText() async {
        client.mainModelSeesImages = false
        installDelegate(vision: visionConfig())

        let d = await deliver()

        XCTAssertTrue(d.ok, d.toolEnvelope)
        XCTAssertTrue(d.imageTurns.isEmpty, "a text-only model must not be sent base64")
        XCTAssertTrue(
            d.userTurns.contains { ($0.content ?? "").contains("A window with a Post button.") },
            "got: \(d.userTurns.map { $0.content ?? "" })")
    }

    /// The description turn must say where coordinates come from. Prose describing a screenshot
    /// invites the model to estimate positions from it; the element list is the only source.
    func testVisionDescriptionTurn_pointsCoordinatesAtTheElementList() async {
        client.mainModelSeesImages = false
        installDelegate(vision: visionConfig())

        let d = await deliver()
        let turn = d.userTurns.first { ($0.content ?? "").contains("A window with a Post button.") }?.content ?? ""

        XCTAssertTrue(turn.contains("ax_elements"), "got: \(turn)")
    }

    // MARK: - Delivery failures

    /// Neither channel available. This must be an ERROR envelope naming the remedy, not a
    /// success with an empty screenshot — the model would otherwise "act on what it saw".
    func testTextOnlyMainModelWithNoVisionConfigured_failsAndExplains() async {
        client.mainModelSeesImages = false
        installDelegate(vision: nil)

        let d = await deliver()

        XCTAssertFalse(d.ok)
        XCTAssertTrue(d.toolEnvelope.contains("Vision"), d.toolEnvelope)
    }

    func testVisionModelFailure_reportsThatTheShotWasTakenButNotDescribed() async {
        client.mainModelSeesImages = false
        client.visionError = VisionUnavailable()
        installDelegate(vision: visionConfig())

        let d = await deliver()

        XCTAssertFalse(d.ok)
        XCTAssertTrue(d.toolEnvelope.contains("captured"),
                      "the distinction matters — retrying the capture won't help: \(d.toolEnvelope)")
    }

    // MARK: - Click-coordinate state (the consequential half)

    private func committedCapture(stepID: String = "role-1", taskID: Int = 1) -> CapturedScreen? {
        sut._testLastComputerUseCapture(stepID: stepID, taskID: taskID)
    }

    func testDeliveredCapture_becomesTheClickCoordinateSpace() async {
        client.mainModelSeesImages = true

        await deliver()

        XCTAssertEqual(committedCapture()?.pngBase64, "QUJD")
        XCTAssertEqual(sut._testComputerUseActionsSinceCapture(stepID: "role-1", taskID: 1), 0,
                       "a fresh capture resets staleness")
    }

    /// The one that matters. Delivery failed, so the model never saw this screenshot — clicks
    /// must keep resolving against the last one it DID see. Committing here would silently
    /// re-point the coordinate space at an image the model has no knowledge of.
    func testUndeliveredCapture_doesNotBecomeTheClickCoordinateSpace() async {
        client.mainModelSeesImages = false
        installDelegate(vision: nil)   // no Vision model ⇒ delivery fails

        await deliver()

        XCTAssertNil(committedCapture(),
                     "a capture the model never received must not govern its clicks")
    }

    func testVisionFailure_alsoLeavesTheCoordinateSpaceAlone() async {
        client.mainModelSeesImages = false
        client.visionError = VisionUnavailable()
        installDelegate(vision: visionConfig())

        await deliver()

        XCTAssertNil(committedCapture())
    }

    /// The element list committed alongside the capture is what the click echo resolves against.
    /// A capture whose geometry landed but whose elements didn't would report every click as a
    /// miss.
    func testDeliveredCapture_commitsItsElementListToo() async {
        client.mainModelSeesImages = true

        await deliver()

        XCTAssertEqual(sut._testLastComputerUseElements(stepID: "role-1", taskID: 1)?.count, 1)
    }

    /// A torn-down step must not have its state written: the `axElements` await opens a window in
    /// which Pause can supersede this execution, and a late resume would poison whatever fresh
    /// execution now holds the same `TaskStepKey`.
    func testTornDownStep_isNotWrittenTo() async {
        client.mainModelSeesImages = true
        var messages: [ChatMessage] = []
        // No `_testRegisterStepTask`, so `isExecutionLive` is false for this key.
        await sut.deliverCapture(
            captured: Self.makeCapture(), collection: collection(), target: "Safari",
            key: TaskStepKey(taskID: 9, stepID: "gone"),
            client: client,
            config: LLMConfig(provider: .lmStudio, baseURLString: "u", modelName: "m", temperature: nil),
            networkLogger: nil,
            result: ToolExecutionResult(providerID: "c", toolName: ToolNames.screenCapture,
                                        argumentsJSON: "{}", outputJSON: "", isError: false),
            toolCallID: UUID(), stepID: "gone", taskID: 9,
            conversationMessages: &messages, tracker: nil)

        XCTAssertNil(sut._testLastComputerUseCapture(stepID: "gone", taskID: 9))
    }
}
