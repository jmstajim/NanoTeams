import AppKit
import CoreGraphics
import Foundation

// MARK: - Computer-use finalizer

/// Deferred finalizer for `.computerUse` signals. The handler only validated args + emitted
/// the signal; the real OS work runs here because a detached `ToolHandler` has no reference
/// back to `LLMExecutionService` and thus can't reach the per-step last-capture metadata it
/// needs to convert image-pixels → global points. Mirrors the `.visionAnalysis` pattern.
extension LLMExecutionService {

    func appendComputerUseResult(
        result: ToolExecutionResult,
        toolCallID: UUID,
        stepID: String,
        taskID: Int,
        client: any LLMClient,
        config: LLMConfig,
        networkLogger: NetworkLogger?,
        conversationMessages: inout [ChatMessage],
        tracker: ToolCallTracker?
    ) async {
        guard case .computerUse(let action) = result.signal else { return }
        let key = TaskStepKey(taskID: taskID, stepID: stepID)

        // Input synthesis (click / type / key / scroll) needs Accessibility ("control your
        // computer") — the CGEvents are SILENTLY DROPPED by the OS on an untrusted process.
        // Without this guard the finalizer returned a success envelope for a no-op, so the model
        // saw "done", re-captured, saw nothing changed, and looped. `screen_capture` uses Screen
        // Recording (checked in ScreenCaptureService) — not this permission.
        if requiresAccessibility(action), !InputControlService.hasAccessibility() {
            InputControlService.requestAccessibilityIfNeeded()   // opens System Settings prompt (once)
            await finalizeToolResult(
                envelope: makeErrorEnvelope(code: .computerUseDenied,
                    message: "Accessibility permission is required to control the mouse and keyboard. "
                        + "Grant NanoTeams access in System Settings → Privacy & Security → Accessibility, "
                        + "then try again."),
                isError: true, result: result, toolCallID: toolCallID,
                stepID: stepID, taskID: taskID, conversationMessages: &conversationMessages, tracker: tracker)
            return
        }

        switch action {
        case .capture(let target, let windowTitle):
            await runCapture(
                target: target, windowTitle: windowTitle, key: key,
                client: client, config: config, networkLogger: networkLogger,
                result: result, toolCallID: toolCallID, stepID: stepID, taskID: taskID,
                conversationMessages: &conversationMessages, tracker: tracker)

        case .click(let x, let y, let button, let double, let target):
            // Right-clicks skip the miss warning: opening a context menu on empty background
            // is a legitimate dead-space click.
            await runPointerAction(
                x: x, y: y, target: target, key: key, warnOnMiss: button != "right",
                perform: { point in
                    InputControlService.click(globalPoint: point, button: button == "right" ? .right : .left, double: double)
                    return "Clicked at image (\(x), \(y))."
                },
                result: result, toolCallID: toolCallID, stepID: stepID, taskID: taskID,
                conversationMessages: &conversationMessages, tracker: tracker)

        case .scroll(let x, let y, let dx, let dy, let target):
            // Scroll keeps the element echo but never warns: scrolling legitimately targets
            // areas outside every advertised element (scroll containers aren't actionable).
            await runPointerAction(
                x: x, y: y, target: target, key: key, warnOnMiss: false,
                perform: { point in
                    InputControlService.scroll(globalPoint: point, dx: dx, dy: dy)
                    return "Scrolled (\(dx), \(dy)) at image (\(x), \(y))."
                },
                result: result, toolCallID: toolCallID, stepID: stepID, taskID: taskID,
                conversationMessages: &conversationMessages, tracker: tracker)

        case .typeText(let text, let target):
            await activateTargetAndSettle(target: target)
            InputControlService.typeText(text)
            executionStates[key]?.computerUseActionsSinceCapture += 1
            await finalizeToolResult(
                envelope: makeSuccessEnvelope(data: ["status": "ok", "action": "type"]),
                isError: false, result: result, toolCallID: toolCallID,
                stepID: stepID, taskID: taskID, conversationMessages: &conversationMessages, tracker: tracker)

        case .pressKey(let keys, let target):
            await activateTargetAndSettle(target: target)
            do {
                try InputControlService.pressKeys(keys)
                executionStates[key]?.computerUseActionsSinceCapture += 1
                await finalizeToolResult(
                    envelope: makeSuccessEnvelope(data: ["status": "ok", "action": "key", "keys": keys]),
                    isError: false, result: result, toolCallID: toolCallID,
                    stepID: stepID, taskID: taskID, conversationMessages: &conversationMessages, tracker: tracker)
            } catch {
                await finalizeToolResult(
                    envelope: makeErrorEnvelope(code: .invalidArgs, message: errorText(error)),
                    isError: true, result: result, toolCallID: toolCallID,
                    stepID: stepID, taskID: taskID, conversationMessages: &conversationMessages, tracker: tracker)
            }
        }
    }

    /// True for actions that synthesize input events (need Accessibility). `capture` does not.
    private func requiresAccessibility(_ action: ComputerUseAction) -> Bool {
        if case .capture = action { return false }
        return true
    }

    // MARK: - Main-model vision capability (auto-detected)

    /// Auto-detected replacement for the removed "Main model supports vision"
    /// Settings toggle. Undeterminable probes resolve to `false` — the safe
    /// direction is the vision-model fallback (a described screenshot) rather
    /// than feeding an image to a model that may not parse it.
    func mainModelSeesImages(config: LLMConfig, client: any LLMClient) async -> Bool {
        let key = config.baseURLString + "|" + config.modelName
        if let cached = mainModelVisionCache[key] { return cached }
        guard let verdict = await client.modelSupportsVision(config: config) else { return false }
        mainModelVisionCache[key] = verdict
        return verdict
    }

    // MARK: - Capture

    /// Prompt for the vision-model fallback. The agent aims clicks with the
    /// `ax_elements` list (precise coordinates); the description supplies the
    /// visual context the text-only main model can't see.
    private static let captureDescriptionPrompt = """
        Describe this screenshot for an agent that operates the app without seeing it: \
        overall layout, key controls and their visible states, and any readable text. \
        The agent aims clicks with a separate element list, so describe content — do not \
        estimate coordinates. Be concise.
        """

    private func runCapture(
        target: String, windowTitle: String?, key: TaskStepKey,
        client: any LLMClient, config: LLMConfig, networkLogger: NetworkLogger?,
        result: ToolExecutionResult, toolCallID: UUID, stepID: String, taskID: Int,
        conversationMessages: inout [ChatMessage], tracker: ToolCallTracker?
    ) async {
        let ownBundle = Bundle.main.bundleIdentifier ?? ""
        let captured: CapturedScreen
        do {
            captured = try await ScreenCaptureService.capture(targetSpec: target, windowTitle: windowTitle, ownBundleID: ownBundle)
        } catch is CancellationError {
            return
        } catch {
            await finalizeToolResult(
                envelope: makeErrorEnvelope(code: .commandFailed, message: errorText(error)),
                isError: true, result: result, toolCallID: toolCallID,
                stepID: stepID, taskID: taskID, conversationMessages: &conversationMessages, tracker: tracker)
            return
        }

        // Per-RUN count (survives step/pause boundaries) so the first-capture privacy prompt
        // fires once per run, not once per role. Counts a capture that was actually taken —
        // independent of whether it's ultimately delivered to the model below.
        computerUseCaptureCountByTask[key.taskID, default: 0] += 1

        let collection = await axElements(for: captured, ownBundle: ownBundle)
        let elements = collection.elements
        // Commit the click-coordinate state (capture geometry + its element list + reset
        // staleness) ATOMICALLY, guarded by liveness, and ONLY on the paths that actually
        // DELIVER this capture to the model. Two reasons: (1) the async `axElements` await
        // opens a teardown window — an orphaned resume after Pause/supersede must NOT poison a
        // fresh execution's state under the same TaskStepKey (the `isExecutionLive` write
        // barrier); (2) if delivery fails (no Vision model, Vision error), the model never sees
        // this capture, so clicks must keep resolving against the PREVIOUS one the model DID see
        // — committing here would re-point geometry at a screenshot it never received.
        let commitCaptureState: () -> Void = { [weak self] in
            guard let self, self.isExecutionLive(stepID: stepID, taskID: taskID) else { return }
            self.executionStates[key]?.lastComputerUseCapture = captured
            self.executionStates[key]?.lastComputerUseElements = elements
            self.executionStates[key]?.computerUseActionsSinceCapture = 0
        }
        // Surface "no elements because Accessibility isn't granted" as a warning so the model
        // isn't left with a silently blank element list (→ blind typing / loops).
        var warnings = collection.warnings
        if let note = AccessibilityInspector.emptyElementsNote(
            hasAccessibility: InputControlService.hasAccessibility(), elementCount: elements.count) {
            warnings.append(note)
        }
        // Window resolution now falls back to a window-TITLE match (so `target:"LinkedIn"` finds
        // the Safari tab showing it). The hazard: `target:"Notes"` when Notes isn't running can
        // title-match an unrelated window (a Safari tab "Release Notes"). Signal it so the model
        // doesn't silently operate the wrong app — mirrors windowRank's app-vs-title tiering.
        if let note = ScreenCaptureService.titleOnlyMatchNote(requestedTarget: target, captured: captured) {
            warnings.append(note)
        }
        let envelope = makeSuccessEnvelope(
            data: CaptureEnvelope(captured: captured, elements: elements),
            meta: ToolResultMeta(truncated: elements.count < collection.totalAfterDedup, warnings: warnings))

        // Route the pixels by the MAIN model's (auto-detected) vision capability:
        // vision-capable → the image itself goes into the chat; text-only → the
        // configured Vision model describes it (same engine as `analyze_image`)
        // and the description goes in as text. Clicks aim with `ax_elements`
        // either way, so the description path stays fully operable.
        if await mainModelSeesImages(config: config, client: client) {
            commitCaptureState()
            await appendImageToMainChat(
                envelope: envelope,
                imageBase64: captured.pngBase64, imageMime: "image/png",
                pixelWidth: captured.pixelWidth, pixelHeight: captured.pixelHeight,
                userCaption: "[Screenshot for tool_call \(result.providerID ?? "")] Coordinates are in image pixels; act on what you see here. This capture replaces earlier ones — coordinates from previous screenshots are no longer valid.",
                result: result, toolCallID: toolCallID, stepID: stepID, taskID: taskID,
                conversationMessages: &conversationMessages, tracker: tracker)
            return
        }

        guard let visionConfig = delegate?.visionLLMConfig else {
            await finalizeToolResult(
                envelope: makeErrorEnvelope(code: .computerUseDenied,
                    message: "The main model cannot see images and no Vision model is configured. "
                        + "Enable Vision in Settings → Vision (or use a vision-capable main model) "
                        + "so screenshots can be described."),
                isError: true, result: result, toolCallID: toolCallID,
                stepID: stepID, taskID: taskID, conversationMessages: &conversationMessages, tracker: tracker)
            return
        }

        let description: String
        do {
        // Same interleaver as the `analyze_image` path — see the note there.
        await noteInterleavingCall(label: "vision", config: visionConfig)
            description = try await VisionAnalysisService.analyze(
                prompt: Self.captureDescriptionPrompt,
                imageBase64: captured.pngBase64,
                mimeType: "image/png",
                config: visionConfig,
                client: client,
                logger: networkLogger)
        } catch is CancellationError {
            return
        } catch {
            await finalizeToolResult(
                envelope: makeErrorEnvelope(code: .commandFailed,
                    message: "Screenshot captured, but the Vision model failed to describe it: \(errorText(error))"),
                isError: true, result: result, toolCallID: toolCallID,
                stepID: stepID, taskID: taskID, conversationMessages: &conversationMessages, tracker: tracker)
            return
        }

        commitCaptureState()
        await finalizeToolResult(
            envelope: envelope, isError: false, result: result, toolCallID: toolCallID,
            stepID: stepID, taskID: taskID, conversationMessages: &conversationMessages, tracker: tracker)
        // Text turn instead of the image turn: the description is plain text, so
        // (unlike the base64 image) it persists verbatim and rides the normal
        // stateful chain — no store:false single-send special-casing.
        let descriptionTurn = "[Screenshot description via vision model — coordinates come from ax_elements, "
            + "not this text] \(description)"
        conversationMessages.append(ChatMessage(role: .user, content: descriptionTurn))
        await appendLLMMessage(stepID: stepID, taskID: taskID, role: .user, content: descriptionTurn)
    }

    /// AX element list for the captured target. Window captures use the window's app;
    /// whole-screen captures fall back to the frontmost non-NanoTeams app. The collection
    /// (synchronous AX IPC + web-content settle/retry) runs off the main actor — see
    /// `AccessibilityInspector.collectElements`.
    private func axElements(for captured: CapturedScreen, ownBundle: String) async -> AXCollectionResult {
        var pid = captured.pid
        if pid == nil {
            if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != ownBundle {
                pid = front.processIdentifier
            }
        }
        guard let pid else { return .empty }
        return await AccessibilityInspector.collectElements(AXCollectionRequest(
            pid: pid,
            regionOriginX: captured.originX, regionOriginY: captured.originY,
            regionWidthPt: captured.regionWidthPt, regionHeightPt: captured.regionHeightPt,
            pixelWidth: captured.pixelWidth, pixelHeight: captured.pixelHeight,
            matchWindowToRegion: captured.targetKind == "window"))
    }

    // MARK: - Pointer actions (click / scroll)

    private func runPointerAction(
        x: Int, y: Int, target: String?, key: TaskStepKey, warnOnMiss: Bool,
        perform: (CGPoint) -> String,
        result: ToolExecutionResult, toolCallID: UUID, stepID: String, taskID: Int,
        conversationMessages: inout [ChatMessage], tracker: ToolCallTracker?
    ) async {
        guard let captured = executionStates[key]?.lastComputerUseCapture else {
            await finalizeToolResult(
                envelope: makeErrorEnvelope(code: .computerUseDenied,
                    message: "No screenshot yet — call screen_capture before clicking or scrolling."),
                isError: true, result: result, toolCallID: toolCallID,
                stepID: stepID, taskID: taskID, conversationMessages: &conversationMessages, tracker: tracker)
            return
        }
        guard let point = InputControlService.imagePixelToGlobalPoint(
            imageX: Double(x), imageY: Double(y),
            originX: captured.originX, originY: captured.originY,
            regionWidthPt: captured.regionWidthPt, regionHeightPt: captured.regionHeightPt,
            pixelWidth: captured.pixelWidth, pixelHeight: captured.pixelHeight)
        else {
            await finalizeToolResult(
                envelope: makeErrorEnvelope(code: .invalidArgs,
                    message: "Coordinates (\(x), \(y)) are outside the \(captured.pixelWidth)×\(captured.pixelHeight) screenshot."),
                isError: true, result: result, toolCallID: toolCallID,
                stepID: stepID, taskID: taskID, conversationMessages: &conversationMessages, tracker: tracker)
            return
        }
        await activateTargetAndSettle(target: target ?? captured.bundleID ?? captured.appName)
        // Echo which ADVERTISED element the point falls in — pure containment against the
        // exact ax_elements list shipped with this capture (no live AX IPC on the click path:
        // a hit-test can block the main actor for seconds and contradicts the advertised list
        // in AX-sparse apps). Closes the blind spot where a click into dead space returned a
        // bare ok and the model looped; the warning fires only on positive evidence of a miss.
        let advertised = executionStates[key]?.lastComputerUseElements ?? []
        let hit = AccessibilityInspector.elementContaining(imageX: x, imageY: y, in: advertised)
        // Staleness is measured BEFORE this action runs: the coordinates (and the echo below)
        // were aimed against a capture that N prior actions may have invalidated.
        let actionsSinceCapture = executionStates[key]?.computerUseActionsSinceCapture ?? 0
        let message = perform(point)
        executionStates[key]?.computerUseActionsSinceCapture += 1
        var data = ["status": "ok", "detail": message]
        var warnings: [String] = []
        if let hit {
            // Qualify the echo IN the authoritative slot when the capture is stale — a weak model
            // weights `data` over `meta.warnings`, so an unqualified "element_at_point: Post" reads
            // as confirmation the click landed on Post even when N prior actions changed the UI.
            let suffix = actionsSinceCapture > 0 ? " (from an earlier capture — may be stale)" : ""
            data["element_at_point"] = "\(hit.role) \"\(hit.label)\"\(suffix)"
        }
        if let stale = AccessibilityInspector.staleCaptureWarning(actionsSinceCapture: actionsSinceCapture) {
            warnings.append(stale)
        }
        if warnOnMiss,
           let warning = AccessibilityInspector.clickHitWarning(hit: hit, x: x, y: y, hasElements: !advertised.isEmpty) {
            warnings.append(warning)
        }
        await finalizeToolResult(
            envelope: makeSuccessEnvelope(data: data, meta: ToolResultMeta(warnings: warnings)),
            isError: false, result: result, toolCallID: toolCallID,
            stepID: stepID, taskID: taskID, conversationMessages: &conversationMessages, tracker: tracker)
    }

    /// Activates + raises the target app before acting so input lands there (when the policy
    /// asks), then WAITS for window ordering to settle before returning. Without the settle
    /// wait, the click/type event can race ahead of the async raise and land on whatever window
    /// was previously frontmost. No-op (no wait) when there's no resolvable target to raise.
    private func activateTargetAndSettle(target: String?) async {
        guard delegate?.computerUsePolicy.raiseTargetWindowBeforeClick ?? true else { return }
        guard let spec = target?.trimmingCharacters(in: .whitespacesAndNewlines), !spec.isEmpty,
              spec.caseInsensitiveCompare("screen") != .orderedSame,
              let app = InputControlService.runningApp(matching: spec) else { return }
        InputControlService.activate(app)
        try? await Task.sleep(for: .milliseconds(ComputerUseConstants.activationSettleMilliseconds))
    }

    // MARK: - Shared finalize helpers

    /// Appends the tool_result envelope AND a `.user` image into the main chat (shared with
    /// `analyze_image`'s in-chat branch). The persisted copy stores only a `[screenshot W×H]`
    /// placeholder — the base64 lives only in the in-memory conversation (single send) + the
    /// approval-card stash.
    func appendImageToMainChat(
        envelope: String,
        imageBase64: String, imageMime: String,
        pixelWidth: Int, pixelHeight: Int,
        userCaption: String,
        result: ToolExecutionResult, toolCallID: UUID, stepID: String, taskID: Int,
        conversationMessages: inout [ChatMessage], tracker: ToolCallTracker?
    ) async {
        // The tool-result commit (append tool message, persist [CALL]/[RESULT], update the tool
        // card, record the tracker) is identical to every other computer-use / vision result —
        // reuse `finalizeToolResult` for it.
        await finalizeToolResult(
            envelope: envelope, isError: false, result: result, toolCallID: toolCallID,
            stepID: stepID, taskID: taskID, conversationMessages: &conversationMessages, tracker: tracker)
        // The extra image-bearing turn is what makes this path special: a separate `.user` turn
        // carrying the image so the reasoning model SEES it next iteration. Persist only a
        // REDACTED placeholder for it — never the base64.
        conversationMessages.append(ChatMessage(
            role: .user, content: userCaption,
            imageContent: [ImageContent(base64Data: imageBase64, mimeType: imageMime)]))
        await appendLLMMessage(stepID: stepID, taskID: taskID, role: .user,
                               content: "[screenshot \(pixelWidth)×\(pixelHeight)]")
    }

    /// Appends a plain tool-result envelope (no image) for the action tools + persists + records.
    func finalizeToolResult(
        envelope: String, isError: Bool,
        result: ToolExecutionResult, toolCallID: UUID, stepID: String, taskID: Int,
        conversationMessages: inout [ChatMessage], tracker: ToolCallTracker?
    ) async {
        conversationMessages.append(ChatMessage(role: .tool, content: envelope, toolCallID: result.providerID))
        await appendLLMMessage(stepID: stepID, taskID: taskID, role: .tool, content: """
            [CALL] \(result.toolName)
            Arguments: \(result.argumentsJSON)

            [RESULT]
            \(envelope)
            """)
        await updateToolCallResult(stepID: stepID, taskID: taskID, toolCallID: toolCallID,
            result: ToolExecutionResult(
                providerID: result.providerID, toolName: result.toolName,
                argumentsJSON: result.argumentsJSON, outputJSON: envelope, isError: isError))
        tracker?.record(toolName: result.toolName, argumentsJSON: result.argumentsJSON,
                        resultJSON: envelope, isError: isError)
    }

    private func errorText(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - Envelope shape

private struct CaptureEnvelope: Encodable {
    let coordinate_space: String
    let pixel_width: Int
    let pixel_height: Int
    let region_w_pt: Double
    let region_h_pt: Double
    let origin_x: Double
    let origin_y: Double
    let target: TargetInfo
    let ax_elements: [AXElementInfo]

    struct TargetInfo: Encodable {
        let kind: String
        let app: String?
        let window_title: String?
        let display_id: UInt32?
    }

    init(captured: CapturedScreen, elements: [AXElementInfo]) {
        self.coordinate_space = "image_pixels"
        self.pixel_width = captured.pixelWidth
        self.pixel_height = captured.pixelHeight
        self.region_w_pt = captured.regionWidthPt
        self.region_h_pt = captured.regionHeightPt
        self.origin_x = captured.originX
        self.origin_y = captured.originY
        self.target = TargetInfo(kind: captured.targetKind, app: captured.appName,
                                 window_title: captured.windowTitle, display_id: captured.displayID)
        self.ax_elements = elements
    }
}
