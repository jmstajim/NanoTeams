import Foundation

// MARK: - In-loop human approval for one MCP call

/// A UI-facing request that one MCP tool call is HELD awaiting a person's decision.
///
/// **The arguments ride whole.** Everything else on this card is about the tool; this field is
/// about what is leaving the machine. Summarising it, eliding it, or showing the first line
/// would make the card a decision about a call the decider could not read — and the documented
/// exfiltration route for an external tool is exactly an argument that carries more than the
/// task needs. What is shown is what the server will receive: the call the send path assembles
/// from the model's document (`MCPDynamicTool.preflight`) — its body and, on a modern-era server,
/// the header parameters mirrored from it — not the document as the model wrote it. Until
/// 2026-10-28 the card showed the document, so an envelope around the arguments, a key the
/// runtime drops and one it trims were all shown as written.
///
/// The annotations are carried as the server's CLAIMS, not as facts: `readOnlyHint` here says
/// the server described the tool that way, and the card is the place a person weighs that
/// against what the arguments actually say. They ride whole — every hint, and which of them the
/// server actually stated — so the card reads them exactly as the review sheet does
/// (`MCPAnnotationChips`).
nonisolated struct MCPApprovalRequest: Identifiable, Hashable, Sendable {
    let taskID: Int
    let stepID: String
    /// Identifies this call among the step's holds: the tool and the exact arguments. Two
    /// calls of one tool with different arguments are two decisions, and must be two cards.
    let callKey: String
    /// The model-facing name — what the model wrote and what the feed shows.
    let toolName: String
    let serverSlug: String
    let serverDisplayName: String
    /// The server's own display title for the tool, or its own name for it — cleaned either
    /// way (`MCPToolDescriptor.displayTitle`), because a person reads it to know WHICH tool.
    let toolTitle: String
    /// Full, sanitized, never truncated: the text a person approved when they approved the
    /// tool, shown again beside the call they are approving now.
    let toolDescription: String
    /// The call exactly as it will leave the machine (`MCPDynamicTool.preflight`): the body of
    /// `tools/call` and the `Mcp-Param-*` headers mirrored from it — modern era only — split for
    /// the era of the step's frozen entry, the one the send is assembled for. The document the
    /// model wrote is the hold's identity (`callKey`), never what is shown.
    let outgoing: MCPDynamicTool.OutgoingCall
    /// The tool's annotations as its descriptor holds them. Until 2026-09-24 the request carried
    /// two of the four hints and rebuilt the other two as `false`, so the card never showed
    /// "open world" — the spec's own pessimistic default — while the review sheet did (F31, F54).
    let annotations: MCPToolAnnotations
    let serverTrusted: Bool
    /// The pin this call is being approved under — the text the card showed. An "always"
    /// grant is bound to it: `NTMSOrchestrator.resolveMCPApproval` passes it as the expected
    /// hash, and `MCPServerConnection.setAlwaysAllow` records nothing unless the live tool and
    /// the approval on record are both still this text.
    let pinHash: String
    /// Whether to offer the "Always allow" button — `false` under manual approval mode, where
    /// nothing may persist a standing allow, during a planning phase, where the grant
    /// would take effect after a boundary that discards the transcript it was made in, and on a
    /// cross-server hold, where the hold is about the step's prior server contact rather than the tool alone.
    let offerAlways: Bool
    /// Display names of other MCP servers already contacted during the same step, when this hold
    /// was triggered or accompanied by a cross-server transfer boundary.
    let priorServerNames: [String]
    let createdAt: Date

    init(
        taskID: Int,
        stepID: String,
        callKey: String,
        toolName: String,
        serverSlug: String,
        serverDisplayName: String,
        toolTitle: String,
        toolDescription: String,
        outgoing: MCPDynamicTool.OutgoingCall,
        annotations: MCPToolAnnotations,
        serverTrusted: Bool,
        pinHash: String,
        offerAlways: Bool,
        priorServerNames: [String] = [],
        createdAt: Date
    ) {
        self.taskID = taskID
        self.stepID = stepID
        self.callKey = callKey
        self.toolName = toolName
        self.serverSlug = serverSlug
        self.serverDisplayName = serverDisplayName
        self.toolTitle = toolTitle
        self.toolDescription = toolDescription
        self.outgoing = outgoing
        self.annotations = annotations
        self.serverTrusted = serverTrusted
        self.pinHash = pinHash
        self.offerAlways = offerAlways
        self.priorServerNames = priorServerNames
        self.createdAt = createdAt
    }

    var id: String { "\(taskID):\(stepID):\(callKey)" }

    /// Reader-facing banner warning when approving this call sends arguments to a second MCP
    /// server after the step already used another server.
    var crossServerTransferNote: String? {
        guard !priorServerNames.isEmpty else { return nil }
        let prior = priorServerNames.joined(separator: ", ")
        return "This step already read from \(prior). Approving sends the arguments below to \(serverDisplayName)."
    }

    /// The arguments as the card SHOWS them: `outgoing` laid out (`argumentsText(of:)`), whole,
    /// with every invisible, bidi or tag character spelled out as `\u{XXXX}` and a flag for the
    /// card's warning. A tag-character payload after a harmless word is otherwise invisible in
    /// plain text — and is sent all the same. Only the SHOWING escapes; the call goes out as
    /// `outgoing` holds it.
    ///
    /// The box's text is laid out by the app, so its ONE layout character is the "\n" the app
    /// writes (`MCPTextSanitizer.Layout.appLaidOut`). Every value — in the body and on a header
    /// line alike — is printed through the body's JSON quoting (`JSONValue.prettyJSONString`),
    /// which writes a carriage return, a line feed and a tab as its own escapes (`\r`, `\n`,
    /// `\t`): those read as escapes and are NOT flagged. The printer leaves U+2028, U+2029 and
    /// NEL raw, so one of those in the box came from a value, and it is spelled out as `\u{…}`
    /// and flagged, over the WHOLE box, header lines included: one scan, one warning. Until
    /// 2026-10-28 U+2028 and U+2029 drew as real line breaks, unflagged, and a header value
    /// could forge a second header line.
    var argumentsDisplay: MCPTextSanitizer.EscapedText {
        MCPTextSanitizer.escapeHidden(Self.argumentsText(of: outgoing), layout: .appLaidOut)
    }

    /// The words above the header parameters in the arguments box. "Also": a header mirrors a
    /// value the body above already carries (`MCPArgumentCoercion.coerce`).
    static let headerParametersHeading = "Also sent as request headers:"

    /// What the arguments box reads for `outgoing`, before hidden characters are spelled out: the
    /// body the server receives, laid out one member per line in the canonical order
    /// (`JSONValue.prettyJSONString` — the canonical rendering with whitespace, so the same
    /// members, escapes and numbers as the wire's), then — only when the call carries a header
    /// parameter, which only a modern-era server's schema produces — a blank line,
    /// `headerParametersHeading`, and one `Name: "value"` line per header, sorted by name, each
    /// value as the server decodes it. The body holds those values too; the section says they
    /// ALSO travel as request headers, which every intermediary on the way can read. A
    /// legacy-era call has no header channel, and no such section: its header parameters are
    /// in the body alone.
    ///
    /// **A header's value is printed as a JSON string** — the body's own quoting
    /// (`JSONValue.prettyJSONString`) — so it reads exactly as the body does, and nothing it holds
    /// can pass for layout: a line break or a tab reads as its escape, a quote is escaped, and a
    /// soft wrap of a long value lands visibly inside the quotes. Printed bare, `"alex"`, forty
    /// spaces and `"Mcp-Param-Locale: en"` wrapped into what read as a second header line, with
    /// nothing to warn of it. The header NAME is `Mcp-Param-` and a token
    /// (`MCPHeaderParam.make`) — ASCII by construction — and stays bare. Until 2026-10-28
    /// the value was printed bare.
    static func argumentsText(of outgoing: MCPDynamicTool.OutgoingCall) -> String {
        let body = outgoing.arguments.prettyJSONString()
        guard !outgoing.headerParameters.isEmpty else { return body }
        let headers = outgoing.headerParameters.keys.sorted().map { name in
            "\(name): \(JSONValue.string(outgoing.headerParameters[name] ?? "").prettyJSONString())"
        }
        return ([body, "", headerParametersHeading] + headers).joined(separator: "\n")
    }

    /// The call sends nothing: the server receives no argument, and no header. The card says so
    /// in words rather than drawing "{}" in a box. Read off `outgoing`, the call the send path
    /// assembles, so it is true of what goes out — no document, `null`, `{}`, a key the runtime
    /// drops, an envelope around `{}` — and not of how the document looks. A document the send
    /// path refuses gets no card at all (`MCPDynamicTool.preflight`).
    var hasNoArguments: Bool { outgoing.sendsNothing }

    /// The chips the card shows — the same reading the review sheet shows for the tool.
    var annotationChips: MCPAnnotationChips { annotations.chips }

    /// Whether the card notes that the chips are the server's own claim: only on a server the
    /// person has not marked trusted, and only when the server claimed something — a card for a
    /// tool it said nothing about already says so.
    var marksClaimsAsTheServers: Bool { !serverTrusted && !annotationChips.claimed.isEmpty }

    /// The note the card hands the claimed-chips row — `marksClaimsAsTheServers`, in words.
    var claimNote: String? { marksClaimsAsTheServers ? Self.serversOwnClaimNote : nil }

    static let serversOwnClaimNote = "the server's own claim"
}

extension LLMExecutionService {

    /// The hold key for one call: the tool and the exact arguments. Spelled once so the gate,
    /// the resolver and any test agree on what "the same call" means.
    nonisolated static func mcpCallKey(toolName: String, argumentsJSON: String) -> String {
        toolName + "\u{1}" + argumentsJSON
    }

    /// Suspends the tool loop until a person allows or denies this call — or the step is
    /// cancelled (Pause / teardown), which resolves to `.cancelled` so the await returns
    /// promptly and the call never goes out unapproved.
    func awaitMCPApproval(
        taskID: Int,
        stepID: String,
        call: StepToolCall,
        entry: MCPToolsSnapshot.Entry,
        outgoing: MCPDynamicTool.OutgoingCall,
        offerAlways: Bool,
        priorServerNames: [String] = []
    ) async -> MCPApprovalDecision {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        let callKey = Self.mcpCallKey(toolName: entry.modelFacingName, argumentsJSON: call.argumentsJSON)
        let waiter = mcpApprovalWaiters.register(key, holdKey: callKey)

        // ONE timestamp identifies this hold instance — shared by the published request and
        // the matching `didEnd`, so a late end from a prior hold of the SAME call cannot
        // clear a freshly-republished card.
        let createdAt = MonotonicClock.shared.now()

        delegate?.mcpApprovalDidBegin(
            MCPApprovalRequest(
                taskID: taskID,
                stepID: stepID,
                callKey: callKey,
                toolName: entry.modelFacingName,
                serverSlug: entry.slug.rawValue,
                serverDisplayName: entry.serverDisplayName,
                toolTitle: entry.descriptor.displayTitle,
                toolDescription: entry.descriptor.displayDescription,
                outgoing: outgoing,
                annotations: entry.descriptor.annotations,
                serverTrusted: entry.serverTrusted,
                pinHash: entry.descriptor.pinHash,
                offerAlways: offerAlways,
                priorServerNames: priorServerNames,
                createdAt: createdAt))

        let decision = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<MCPApprovalDecision, Never>) in
                waiter.attach(cont)
            }
        } onCancel: {
            // Pause / work-folder switch cancels the step task. Fail safe — the call never
            // goes out; on resume the step re-runs and re-prompts.
            waiter.resolve(.cancelled)
        }

        mcpApprovalWaiters.release(key, holdKey: callKey)
        delegate?.mcpApprovalDidEnd(
            taskID: taskID, stepID: stepID, callKey: callKey, createdAt: createdAt)
        return decision
    }

    /// Resolves a held MCP approval (called from the orchestrator when the human taps a
    /// button). No-op if no waiter is registered — so a double-tap, or a tap that lands after
    /// Pause, cannot crash on a spent continuation.
    func resolveMCPApproval(
        taskID: Int, stepID: String, callKey: String, decision: MCPApprovalDecision
    ) {
        mcpApprovalWaiters.resolve(
            TaskStepKey(taskID: taskID, stepID: stepID), holdKey: callKey, with: decision)
    }

    /// Resumes every still-pending waiter for a step with `.cancelled` (teardown safety).
    /// Idempotent: an already-settled waiter no-ops, so a person's decision that landed first
    /// is never overwritten by this.
    func failPendingMCPApprovals(stepID: String, taskID: Int) {
        mcpApprovalWaiters.failAll(TaskStepKey(taskID: taskID, stepID: stepID), with: .cancelled)
    }
}
