import AppKit
import Foundation

// MARK: - Computer-use approval decision

/// A human's verdict on a held computer-use action.
nonisolated enum ComputerUseApprovalDecision: Hashable, Sendable {
    case allow
    case deny
    /// Allow this action AND auto-allow further actions on the same app for the rest of the run.
    case alwaysAllowApp
}

// MARK: - The gate

extension LLMExecutionService {

    /// Pre-pass over a turn's resolved tool calls that decides, for each computer-use action,
    /// whether it may execute. Same shape as `gateBashCalls`: returns a sparse `index → synthetic
    /// result` map for the calls it intercepts; indices NOT present pass through to
    /// `executeToolCalls` (→ the handler emits `.computerUse`, the finalizer runs the OS action).
    func gateComputerUseCalls(
        resolvedToolCalls: [StepToolCall],
        allowedToolNames: Set<String>,
        stepID: String,
        taskID: Int,
        supervisorMode: SupervisorMode,
        task: NTMSTask,
        client: any LLMClient,
        config: LLMConfig,
        networkLogger: NetworkLogger?
    ) async -> [Int: ToolExecutionResult] {
        let computerUseNames = ToolHandlerRegistry.computerUseTools
        guard resolvedToolCalls.contains(where: {
            let n = ToolRegistry.resolveToolName($0.name)
            return computerUseNames.contains(n) && allowedToolNames.contains(n)
        }) else { return [:] }

        let policy = delegate?.computerUsePolicy ?? ComputerUsePolicy()
        let humanPresent = (supervisorMode == .manual) && !isUnderAutovisor(task: task)
        let ownBundle = Bundle.main.bundleIdentifier ?? ""
        let key = TaskStepKey(taskID: taskID, stepID: stepID)

        var synthetic: [Int: ToolExecutionResult] = [:]

        for (idx, call) in resolvedToolCalls.enumerated() {
            let canonical = ToolRegistry.resolveToolName(call.name)
            guard computerUseNames.contains(canonical), allowedToolNames.contains(canonical) else { continue }

            guard let action = parseComputerUseAction(name: canonical, argsJSON: call.argumentsJSON) else {
                synthetic[idx] = makeComputerUseDeniedResult(
                    call: call, reason: "Could not parse the action arguments.")
                continue
            }

            let resolvedInput = resolved(action: action, policy: policy, ownBundle: ownBundle, key: key)
            switch ComputerUsePermissionService.evaluate(resolvedInput.evalInput, policy: policy) {
            case .allow:
                continue
            case .deny(let reason):
                synthetic[idx] = makeComputerUseDeniedResult(call: call, reason: reason)
            case .ask(let reason):
                if policy.mode == .auto {
                    // Safety = Off (`restrictionLevel == .off`) never reaches here:
                    // `ComputerUsePermissionService.evaluate` step 8 returns `.allow`
                    // for auto+off before emitting `.ask`. If you add another judge
                    // call site (e.g. a manual-unattended fallback), re-check that
                    // contract — the off-switch lives in the evaluator.
                    let verdict = await ComputerUseJudgeService.judge(
                        action: action, context: judgeContext(action: action, key: key),
                        policy: policy, config: config, client: client, logger: networkLogger)
                    if verdict.allowed { continue }
                    synthetic[idx] = makeComputerUseDeniedResult(call: call, reason: verdict.reason)
                } else if humanPresent {
                    let request = approvalRequest(action: action, call: call, stepID: stepID, taskID: taskID, key: key)
                    switch await awaitComputerUseApproval(request: request) {
                    case .allow:
                        continue
                    case .alwaysAllowApp:
                        if let app = resolvedInput.resolvedTargetKey { allowComputerUseAppForRun(taskID: taskID, bundleOrName: app) }
                        continue
                    case .deny:
                        synthetic[idx] = makeComputerUseDeniedResult(
                            call: call, reason: "You declined to approve this action.")
                    }
                } else {
                    synthetic[idx] = makeComputerUseDeniedResult(
                        call: call,
                        reason: "This action needs human approval (\(reason)), but no human is available. "
                            + "Set Computer Use to Auto in Settings to let the judge decide unattended.")
                }
            }
        }

        return synthetic
    }

    // MARK: - Eligibility resolution (impure — resolves apps + capture metadata)

    /// Wraps `ComputerUseEvalInput` plus the resolved target key (for the session allowlist grant).
    private struct ResolvedEvalInput {
        let evalInput: ComputerUseEvalInput
        let resolvedTargetKey: String?
    }

    private func resolved(
        action: ComputerUseAction, policy: ComputerUsePolicy, ownBundle: String, key: TaskStepKey
    ) -> ResolvedEvalInput {
        let spec = action.appTargetSpec
        let app = spec.flatMap { InputControlService.runningApp(matching: $0) }
        let resolvedBundle = app?.bundleIdentifier
        let resolvedName = app?.localizedName
        var isSelf = (resolvedBundle != nil && resolvedBundle == ownBundle)
            || (spec?.caseInsensitiveCompare("NanoTeams") == .orderedSame)

        let targetKey = (resolvedBundle ?? spec)?.lowercased()
        let allowlist = policy.targetAppAllowlist.map { $0.lowercased() }
        let allowed: Bool
        if allowlist.isEmpty {
            allowed = true
        } else if let bundle = resolvedBundle?.lowercased(), allowlist.contains(bundle) {
            allowed = true
        } else if let name = resolvedName?.lowercased(), allowlist.contains(name) {
            allowed = true
        } else if let s = spec?.lowercased(), allowlist.contains(s) {
            allowed = true
        } else {
            // Whole-screen (spec == nil) with a non-empty allowlist can't be restricted → deny.
            allowed = false
        }

        let session = computerUseSessionAllowedApps[key.taskID] ?? []
        let preApproved = targetKey.map { session.contains($0) } ?? false

        let capture = executionStates[key]?.lastComputerUseCapture
        // Resolve the click/scroll point ONCE — it drives both the in-bounds check and the
        // own-window self-guard below.
        let resolvedPoint = pointerGlobalPoint(action: action, capture: capture)
        let clickInBounds: Bool? = isPointerAction(action)
            ? (capture == nil ? nil : (resolvedPoint != nil))  // unknown until captured; finalizer errors
            : nil
        // Self-guard for untargeted clicks: a whole-display capture filters NanoTeams' own
        // windows OUT of the image, but they're still physically on screen. A click at those
        // pixels would hit the app's own UI (its Allow button, settings). Detect it by resolved
        // global point, not just by a named target.
        if let pt = resolvedPoint, InputControlService.pointInAnyRect(pt, rects: InputControlService.ownWindowFrames()) {
            isSelf = true
        }
        let captureCount = computerUseCaptureCountByTask[key.taskID] ?? 0

        let evalInput = ComputerUseEvalInput(
            action: action,
            isSelfTarget: isSelf,
            targetAllowedByAllowlist: allowed,
            sessionPreApproved: preApproved,
            clickInBounds: clickInBounds,
            captureAlreadyOccurredThisRun: captureCount > 0)
        return ResolvedEvalInput(evalInput: evalInput, resolvedTargetKey: targetKey)
    }

    /// Screen context for the judge, resolved from the SAVED last-capture state only (never a
    /// live AX hit-test — the CLAUDE.md click-aiming gotcha: main-actor freezes + list
    /// contradiction). App/window come from the capture (fallback: the model-declared target);
    /// the element label is the advertised element under a click's coordinates — the same
    /// containment lookup the finalizer echoes AFTER execution, moved BEFORE the verdict.
    private func judgeContext(action: ComputerUseAction, key: TaskStepKey) -> ComputerUseJudgeContext {
        let capture = executionStates[key]?.lastComputerUseCapture
        var element: String?
        if case .click(let x, let y, _, _, _) = action {
            let advertised = executionStates[key]?.lastComputerUseElements ?? []
            if let hit = AccessibilityInspector.elementContaining(imageX: x, imageY: y, in: advertised) {
                element = "\(hit.role) “\(hit.label)”"
            }
        }
        return ComputerUseJudgeContext(
            // The action's own target wins: that is the app the finalizer raises + acts in, so a
            // type/click declaring `target: "Terminal"` must be judged against Terminal even if
            // the last capture was Safari — else the judge rules on the wrong app.
            appName: action.appTargetSpec ?? capture?.appName,
            windowTitle: capture?.windowTitle,
            elementUnderPoint: element,
            actionsSinceCapture: executionStates[key]?.computerUseActionsSinceCapture ?? 0)
    }

    private func isPointerAction(_ action: ComputerUseAction) -> Bool {
        switch action {
        case .click, .scroll: return true
        default: return false
        }
    }

    /// Resolves a click/scroll's image-pixel coordinate to a global display point, or nil when
    /// the action isn't a pointer action, there's no capture yet, or the point is out of bounds.
    private func pointerGlobalPoint(action: ComputerUseAction, capture: CapturedScreen?) -> CGPoint? {
        let coords: (Int, Int)?
        switch action {
        case .click(let x, let y, _, _, _): coords = (x, y)
        case .scroll(let x, let y, _, _, _): coords = (x, y)
        default: coords = nil
        }
        guard let (x, y) = coords, let c = capture else { return nil }
        return InputControlService.imagePixelToGlobalPoint(
            imageX: Double(x), imageY: Double(y),
            originX: c.originX, originY: c.originY,
            regionWidthPt: c.regionWidthPt, regionHeightPt: c.regionHeightPt,
            pixelWidth: c.pixelWidth, pixelHeight: c.pixelHeight)
    }

    // MARK: - Approval request

    private func approvalRequest(
        action: ComputerUseAction, call: StepToolCall, stepID: String, taskID: Int, key: TaskStepKey
    ) -> ComputerUseApprovalRequest {
        let capture = executionStates[key]?.lastComputerUseCapture
        let (tx, ty): (Int?, Int?)
        switch action {
        case .click(let x, let y, _, _, _): (tx, ty) = (x, y)
        case .scroll(let x, let y, _, _, _): (tx, ty) = (x, y)
        default: (tx, ty) = (nil, nil)
        }
        let appSpec = action.appTargetSpec
        return ComputerUseApprovalRequest(
            taskID: taskID, stepID: stepID,
            actionKey: call.id.uuidString,
            // FULL text (not the 60-char `summary`) so the human approves exactly what runs.
            actionSummary: action.detail,
            targetApp: appSpec,
            offerAlways: appSpec != nil,
            screenshotBase64: capture?.pngBase64,
            targetX: tx, targetY: ty,
            createdAt: MonotonicClock.shared.now())
    }

    // MARK: - Parsing

    func parseComputerUseAction(name: String, argsJSON: String) -> ComputerUseAction? {
        let canonical = ToolRegistry.resolveToolName(name)
        let dict: [String: Any] = {
            guard let data = argsJSON.data(using: .utf8),
                  let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return [:] }
            return parsed
        }()

        func target(_ d: [String: Any]) -> String? {
            optionalString(d, "target").flatMap { $0.isEmpty ? nil : $0 }
        }

        switch canonical {
        case ToolNames.screenCapture:
            let t = optionalString(dict, "target").flatMap { $0.isEmpty ? nil : $0 } ?? "screen"
            return .capture(target: t, windowTitle: optionalString(dict, "window_title").flatMap { $0.isEmpty ? nil : $0 })
        case ToolNames.uiClick:
            guard let x = optionalInt(dict, "x"), let y = optionalInt(dict, "y") else { return nil }
            let button = optionalString(dict, "button")?.lowercased() == "right" ? "right" : "left"
            return .click(x: x, y: y, button: button, double: optionalBool(dict, "double"), target: target(dict))
        case ToolNames.uiType:
            let text = optionalString(dict, "text") ?? resolveContentString(dict) ?? ""
            guard !text.isEmpty else { return nil }
            return .typeText(text: text, target: target(dict))
        case ToolNames.uiKey:
            let keys = optionalString(dict, "keys") ?? optionalString(dict, "key") ?? ""
            guard !keys.isEmpty else { return nil }
            return .pressKey(keys: keys, target: target(dict))
        case ToolNames.uiScroll:
            guard let x = optionalInt(dict, "x"), let y = optionalInt(dict, "y") else { return nil }
            return .scroll(x: x, y: y, dx: optionalInt(dict, "dx") ?? 0, dy: optionalInt(dict, "dy") ?? 0, target: target(dict))
        default:
            return nil
        }
    }

    // MARK: - Synthetic result

    func makeComputerUseDeniedResult(call: StepToolCall, reason: String) -> ToolExecutionResult {
        ToolExecutionResult.synthetic(
            for: call,
            outputJSON: makeErrorEnvelope(code: .computerUseDenied, message: reason),
            isError: true)
    }
}
