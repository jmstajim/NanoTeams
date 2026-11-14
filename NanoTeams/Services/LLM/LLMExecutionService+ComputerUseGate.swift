import AppKit
import Foundation

// MARK: - Computer-use approval decision

/// A human's verdict on a held computer-use action — plus the case where there is no verdict.
nonisolated enum ComputerUseApprovalDecision: Hashable, Sendable {
    case allow
    case deny
    /// Allow this action AND auto-allow further actions on the same app for the rest of the run.
    case alwaysAllowApp
    /// The hold ended WITHOUT a human answer (Pause / work-folder switch / teardown). Twin of
    /// `BashApprovalDecision.cancelled` — see it for why this is not a `.deny`.
    case cancelled
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
        // The one predicate the schema resolver reads too (`ApprovalPresence`). With no human
        // the resolver has already withheld the whole family under `.manual` and the mutating
        // trio under `.semiAutomatic`, so the no-human arm below is reached in production only
        // by a call the model made against a schema that no longer lists it.
        let humanPresent = approvalHumanPresent(task: task, supervisorMode: supervisorMode)
        let ownBundle = Bundle.main.bundleIdentifier ?? ""
        let key = TaskStepKey(taskID: taskID, stepID: stepID)

        var synthetic: [Int: ToolExecutionResult] = [:]

        for (idx, call) in resolvedToolCalls.enumerated() {
            let canonical = ToolRegistry.resolveToolName(call.name)
            guard computerUseNames.contains(canonical), allowedToolNames.contains(canonical) else { continue }

            // A call that cannot become an action holds no card: the runtime refuses its
            // document (`ToolCallArguments`), or the handler refuses its arguments with the
            // missing one named — through the SAME resolver this gate reads, so nothing runs
            // either way. A denial here would tell the model "do not retry" about a call it
            // only has to complete.
            guard let dispatched = ToolCallArguments.prepare(
                rawJSON: call.argumentsJSON, emittedName: call.name).dispatched
            else { continue }
            let parsed: ComputerUseAction?
            do {
                parsed = try ComputerUseArguments.action(
                    canonicalName: dispatched.toolName, args: dispatched.args)
            } catch {
                continue
            }
            guard let action = parsed else {
                // Unreachable while the caller's `computerUseNames` guard and the resolver's
                // switch agree; fail closed if they ever drift.
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
                    let context = judgeContext(action: action, key: key)
                    let ruling = await askApprovalJudge(label: "computer-use judge", config: config) {
                        await ComputerUseJudgeService.judge(
                            action: action, context: context,
                            policy: policy, config: config, client: client, logger: networkLogger)
                    }
                    switch ruling {
                    case .decided(let verdict) where verdict.allowed:
                        continue
                    case .decided(let verdict):
                        synthetic[idx] = makeComputerUseDeniedResult(call: call, reason: verdict.reason)
                    case .cancelled:
                        // Paused while the judge was being asked, or before it could be — no
                        // refusal. Twin of the `bash` gate's judge arm and of this gate's own
                        // human-hold arm.
                        synthetic[idx] = makeCancelledResult(for: call)
                    }
                } else if humanPresent {
                    let request = approvalRequest(action: action, call: call, stepID: stepID, taskID: taskID, key: key)
                    switch await awaitComputerUseApproval(request: request) {
                    case .allow:
                        continue
                    case .alwaysAllowApp:
                        if let app = resolvedInput.resolvedTargetKey { allowComputerUseAppForRun(taskID: taskID, bundleOrName: app) }
                        continue
                    case .deny:
                        // Third person — the reader is the model, and "you" everywhere else in
                        // this tree means the model. Twin of the `bash` gate's deny arm.
                        synthetic[idx] = makeComputerUseDeniedResult(
                            call: call, reason: "The Supervisor denied this action.")
                    case .cancelled:
                        // Paused / torn down while held — no human refused anything, so this is
                        // a cancellation, not a `COMPUTER_USE_DENIED`. Twin of the `bash` gate.
                        synthetic[idx] = makeCancelledResult(for: call)
                    }
                } else {
                    // Twin of the `bash` gate's no-human arm: not a denial, its own code, no
                    // escalation channel downstream, third person. Its "what runs without
                    // approval" clause is this family's, not bash's: captures and scrolling
                    // are the read-only tier (Semi-automatic); under Manual the first capture
                    // is itself gated, which is why Manual is withheld from the schema instead.
                    synthetic[idx] = makeApprovalUnavailableResult(
                        call: call,
                        reason: "This action needs human approval (\(reason)), and this run has no human to give it. "
                            + "Screen captures and scrolling run without approval; nothing inside the run can approve "
                            + "clicks, typing or key presses — take a different step.")
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

    /// The action the gate judges: the HANDLER's own resolver (`ComputerUseArguments`) over the
    /// runtime's own reading of the arguments (`ToolCallArguments`), so the card shows exactly
    /// what the handler emits. `nil` when the runtime would refuse the document, when the tool
    /// is not a computer-use tool, or when an argument the action needs is missing.
    func parseComputerUseAction(name: String, argsJSON: String) -> ComputerUseAction? {
        ToolCallArguments.prepare(rawJSON: argsJSON, emittedName: name).dispatched
            .flatMap(Self.computerUseAction)
    }

    private nonisolated static func computerUseAction(_ dispatched: ToolCallArguments.Dispatch) -> ComputerUseAction? {
        (try? ComputerUseArguments.action(canonicalName: dispatched.toolName, args: dispatched.args)) ?? nil
    }

    // MARK: - Synthetic result

    func makeComputerUseDeniedResult(call: StepToolCall, reason: String) -> ToolExecutionResult {
        ToolExecutionResult.synthetic(
            for: call,
            outputJSON: makeErrorEnvelope(code: .computerUseDenied, message: reason),
            isError: true)
    }
}
