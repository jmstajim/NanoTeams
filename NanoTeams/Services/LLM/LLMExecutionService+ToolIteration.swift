import Foundation

// The single-iteration tool-loop orchestrator. Extracted from the core; it
// delegates to the focused +Streaming / +StepFlowControl / +ToolExecution /
// +ToolResultProcessing / +ToolLoopState methods.
extension LLMExecutionService {

    // MARK: - LLM Tool Iteration

    /// Run exactly one assistant generation + optional tool execution pass.
    ///
    /// This method orchestrates a single LLM iteration by delegating to focused methods:
    /// - `applyPlanningPhase` — authorizes the iteration's toolset for the planning phase
    /// - `performStreamingCall` — executes the LLM streaming call and collects tokens
    /// - `processStreamingResult` — appends the assistant turn to the wire and the log
    /// - `handleNoToolCalls` — handles missing tool calls (learning + retry)
    /// - `executeToolCalls` — executes tools through `ToolRuntime`
    /// - `processToolResults` — processes results (teammate, meeting, scratchpad, errors)
    /// - `handleSupervisorAutoAnswer` — auto-answers Supervisor questions in autonomous mode
    /// - `checkAndInjectLoopWarning` — detects and warns about looping patterns
    func runOneLLMToolIteration(
        stepID: String,
        roleForMessage: Role,
        client: any LLMClient,
        config: LLMConfig,
        tools: [ToolSchema],
        runtime: ToolRuntime,
        task: NTMSTask,
        runIndex: Int,
        stepIndex: Int,
        supervisorMode: SupervisorMode,
        conversationMessages: inout [ChatMessage],
        tracker: ToolCallTracker,
        memoryStore: MemoryTagStore,
        cumulativeUsage: inout TokenUsage,
        networkLogger: NetworkLogger? = nil,
        toolObserver: (([StepToolCall], [ToolExecutionResult]) -> Void)? = nil
    ) async throws -> LLMStepStop {
        guard let delegate else { return .toolFailure(message: "Delegate not available") }

        // Refresh the task snapshot so every downstream read this iteration sees
        // the state just committed through `delegate.mutateTask`.
        let task = Self.refreshedTaskSnapshot(task, delegate: delegate)
        let resolvedTeam = resolveTeam(task: task)
        let step = task.runs[runIndex].steps[stepIndex]
        let roleDefinition = resolvedTeam?.findRole(byIdentifier: step.effectiveRoleID)

        // 2. Apply the planning phase. It returns an AUTHORIZATION, not a tool
        // array: the wire always advertises the full catalog (narrowing it would
        // change the system prompt, which is where the catalog is rendered, and
        // break the prompt-prefix cache), and the phase is enforced at the
        // runtime layer below instead.
        let authorization = await applyPlanningPhase(
            stepID: stepID,
            taskID: task.id,
            tools: tools,
            step: step,
            team: resolvedTeam,
            conversationMessages: &conversationMessages,
            roleDefinition: roleDefinition
        )

        // 2a. Consume any queued Supervisor message targeted at this role (or the
        // untargeted Team queue). Appends a user turn to `conversationMessages`
        // for this iteration's request.
        //
        // Delivered IMMEDIATELY, including mid-planning — a human writing "you're looking in the
        // wrong place, check the parser" has to reach the model on its next turn, which is the
        // whole point of the queue. From the planning phase only the original task statement and
        // the recorded scratchpad survive the boundary, so a turn appended during it IS destroyed
        // there; `applyPlanningPhase` re-queues it at the head instead of letting the slice eat
        // it (`consumeQueuedSupervisorMessage` pops destructively, so the alternative is losing
        // it outright). Cost of this ordering: the model sees such a message twice — once during
        // the exploration it was meant to steer, once in the implementation phase.
        if isExecutionLive(stepID: stepID, taskID: task.id) {
            let deliveredExternalInformation = await injectQueuedSupervisorMessage(
                stepID: stepID,
                taskID: task.id,
                roleID: step.effectiveRoleID,
                conversationMessages: &conversationMessages
            )
            // Opens a new information epoch for the repetition detector: the model is
            // about to decide knowing something no tool call of its own produced, so a
            // repeat that straddles this point is a REACTION, not a loop. The marker
            // rides the next recorded call — see `ToolCallTracker`.
            if deliveredExternalInformation { tracker.noteExternalInformationArrived() }
        }

        // 2b. Stream LLM response. Every call sends the FULL conversation — the
        // provider reuses its prompt-prefix cache on the byte-identical prefix.
        let messagesToSend = conversationMessages

        // Rendered ONCE per iteration and shared by both measurement surfaces below. It walks
        // every registered tool and is the largest text this app builds (CLAUDE.md: ~60% of the
        // first wire payload), so re-deriving it per consumer costs main-thread time on the hot
        // path — and, worse, duplicates the append rule (empty tools AND already-inline) that
        // keeps the two surfaces pricing and fingerprinting the SAME request. Never goes on the
        // wire: `performStreamingCall` gets `tools`, and each provider's `buildRequest` renders
        // its own copy — which for a role step it does NOT, because `PromptBuilder` already put
        // the catalog in the system message, which is why `messages` decides the answer.
        let toolSchemaText = NativeLMStudioClient.toolSchemaTextForMeasurement(
            tools: tools, messages: messagesToSend)

        // 2b-bis. Fingerprint what we are about to send against what this step sent last, so a
        // silent prompt-prefix (KV) cache miss can be attributed. Recorded BEFORE the send: the
        // server's own numbers only arrive at stream end, and combining the two is what
        // separates "we broke our own prefix" from "the server dropped it". The record also
        // PRICES the request (one fused walk), which is what the budget warning below consumes.
        let prefixObservation = await prefixLedger.record(
            baseURL: config.baseURLString,
            model: config.modelName,
            owner: .step(taskID: task.id, stepID: stepID),
            messages: messagesToSend,
            toolSchemaText: toolSchemaText)

        // 2b-ter. An overflowing prompt is not rejected — it is truncated from the START,
        // dropping the system prompt and tool catalog, and answered HTTP 200. Warn before
        // sending so the user can tell "the model ignored its instructions" from "the model
        // never received them".
        await warnIfContextBudgetExceeded(
            stepID: stepID, taskID: task.id, client: client, config: config,
            promptTokens: prefixObservation.totalPromptTokens)

        let streamResult = try await performStreamingCall(
            stepID: stepID,
            taskID: task.id,
            roleForMessage: roleForMessage,
            client: client,
            config: config,
            tools: tools,
            conversationMessages: messagesToSend,
            networkLogger: networkLogger,
            roleName: roleForMessage.displayName.isEmpty ? nil : roleForMessage.displayName
        )

        if let usage = streamResult.tokenUsage { cumulativeUsage.accumulate(usage) }

        // Did the server silently truncate what we just sent? Ordered before the cache report so
        // the overflow latch suppresses the less severe banner for this same request.
        //
        // `serverPrefill?.promptTokens` is preferred but can be absent even when the count is
        // known: `ServerPrefillReport.isEmpty` deliberately ignores `promptTokens` (a denominator,
        // not a signal), so a report carrying only the count is dropped at the decoder. The same
        // number reaches us on `tokenUsage`, which is built independently.
        await confirmContextTruncation(
            stepID: stepID, taskID: task.id, config: config,
            appendedTokens: prefixObservation.appendedTokens,
            serverPromptTokens: streamResult.serverPrefill?.promptTokens
                ?? streamResult.tokenUsage?.inputTokens)

        await reportPrefixCacheMissIfAny(
            stepID: stepID, taskID: task.id, runID: task.runs.last?.id,
            config: config, observation: prefixObservation,
            serverPrefill: streamResult.serverPrefill,
            clientResidency: streamResult.clientResidency)

        // Images are single-use: drop them from the in-memory conversation once sent
        // so the (otherwise byte-identical) prefix on the next iteration carries no
        // base64 payload. The model saw the screenshot exactly once.
        let sentImages = messagesToSend.contains { !($0.imageContent?.isEmpty ?? true) }
        if sentImages {
            for i in conversationMessages.indices where !(conversationMessages[i].imageContent?.isEmpty ?? true) {
                conversationMessages[i].imageContent = nil
            }
        }
        // Remembered so the NEXT iteration does not report the strip's own divergence.
        executionStates[TaskStepKey(taskID: task.id, stepID: stepID)]?
            .lastRequestCarriedImages = sentImages

        // 2c. Top-level thinking-loop break: the stream was aborted + the looping
        // generation discarded (no anchor in `conversationMessages`, nothing in
        // `step.messages`). Recover via `LoopRecoveryPolicy` — clean retry or a
        // mode-aware terminal — BEFORE `processStreamingResult`. Any clean stream
        // completion (no signal) resets the consecutive-break counter.
        if let loopSignal = streamResult.thinkingLoopSignal {
            return await handleStreamLoopBreak(
                stepID: stepID, signal: loopSignal, task: task,
                roleForMessage: roleForMessage, supervisorMode: supervisorMode,
                conversationMessages: &conversationMessages)
        }
        resetThinkingLoopBreakCount(stepID: stepID, taskID: task.id)

        // 3. Append the assistant turn (and any tool calls) to the wire and the log.
        await processStreamingResult(
            streamResult, stepID: stepID, taskID: task.id,
            conversationMessages: &conversationMessages)

        // 4. If no tool calls, handle accordingly
        if streamResult.resolvedToolCalls.isEmpty {
            return await handleNoToolCalls(
                stepID: stepID,
                result: streamResult,
                roleForMessage: roleForMessage,
                task: task,
                runIndex: runIndex,
                stepIndex: stepIndex,
                tracker: tracker,
                roleDefinition: roleDefinition,
                // Same set `executeToolCalls` authorizes against below (narrowed
                // during the planning phase), so a nudge can only name a tool this
                // iteration would actually accept.
                allowedToolNames: authorization.allowed,
                // Computed once by `applyPlanningPhase` from the scans it already paid for;
                // the two later consumers must not rescan the wire (CLAUDE.md #106).
                wireIsMidPlanning: authorization.wireIsMidPlanning,
                runtime: runtime,
                conversationMessages: &conversationMessages
            )
        }

        // 5. Execute tool calls (authorization + identical-write guard)
        // Reset drift + Harmony parse-failure counters: the model is acting and
        // produced a parseable tool call. Centralized so a refactor that drops
        // the call here is also detected by `LLMExecutionServiceParseFailureCapTests`
        // (regression: T1 — the helper-only reset was not exercising this prod path).
        resetCountersOnParseableToolCall(stepID: stepID, taskID: task.id)
        // `ask_supervisor` doesn't qualify as productive under autonomous supervisor
        // mode — it gets auto-answered, and the model can ping itself in a loop with
        // it forever without doing any real work. So a turn whose only tool calls are
        // `ask_supervisor` is treated the same as a no-tool-call turn for the purposes
        // of the advisory no-tool backstop (incremented in `handleNoToolCalls`).
        let toolNamesThisTurn = Set(streamResult.resolvedToolCalls.map(\.name))
        let isAskSupervisorOnly = toolNamesThisTurn == [ToolNames.askSupervisor]
        if isAskSupervisorOnly {
            // Non-productive turn: ask_supervisor gets auto-answered in autonomous mode,
            // so the model can ping itself in a loop with it forever. Treat it as a
            // no-tool-call turn for the advisory no-tool-backstop counter.
            if let stop = await noteNonProductiveTurn(
                stepID: stepID, taskID: task.id, roleDefinition: roleDefinition)
            {
                return stop
            }
        }
        // The no-tool counter is deliberately NOT reset here — see step 6a below.
        // Emitting a call is not acting, and the results aren't known yet.
        let allowedToolNames = authorization.allowed

        // 5a. Bash permission gate (pre-pass): intercept shell commands that must
        // be denied or judged (Auto) BEFORE they reach `executeToolCalls`. Returns
        // synthetic results (carrying each call's providerID — no orphan tool_call)
        // for the calls it handles; everything else passes through to
        // `executeToolCalls`. With a human present, an `.ask` command is HELD and the
        // gate awaits the human's Allow/Deny in-loop (bypassing the model) — not
        // surfaced as a supervisor question; with no human it is denied.
        var gateResults = await gateBashCalls(
            resolvedToolCalls: streamResult.resolvedToolCalls,
            allowedToolNames: allowedToolNames,
            isPlanningPhase: authorization.isPlanningPhase,
            stepID: stepID,
            taskID: task.id,
            supervisorMode: supervisorMode,
            task: task,
            client: client,
            config: config,
            networkLogger: networkLogger
        )
        // 5a-bis. Computer-use gate (second pre-pass): intercept screenshot / click / type /
        // key / scroll actions per `ComputerUsePolicy` (deny / judge / human Allow-Deny) BEFORE
        // they reach `executeToolCalls`. Disjoint indices from the bash gate (different tools),
        // so the merge is collision-free.
        let computerUseGateResults = await gateComputerUseCalls(
            resolvedToolCalls: streamResult.resolvedToolCalls,
            allowedToolNames: allowedToolNames,
            stepID: stepID,
            taskID: task.id,
            supervisorMode: supervisorMode,
            task: task,
            client: client,
            config: config,
            networkLogger: networkLogger
        )
        gateResults.merge(computerUseGateResults) { _, cu in cu }
        let callsToExecute = streamResult.resolvedToolCalls.enumerated()
            .filter { gateResults[$0.offset] == nil }
            .map(\.element)
        let executedResults = await executeToolCalls(
            resolvedToolCalls: callsToExecute,
            allowedToolNames: allowedToolNames,
            phaseWithheldToolNames: authorization.withheldByPhase,
            isPlanningPhase: authorization.isPlanningPhase,
            runtime: runtime,
            tracker: tracker,
            task: task,
            runIndex: runIndex,
            roleID: step.effectiveRoleID
        )
        // Merge gate synthetics back into the original emit order so
        // `processToolResults` can `zip(resolvedToolCalls, results)` by index.
        var toolResults: [ToolExecutionResult] = []
        toolResults.reserveCapacity(streamResult.resolvedToolCalls.count)
        var executedIdx = 0
        for (idx, _) in streamResult.resolvedToolCalls.enumerated() {
            if let synth = gateResults[idx] {
                toolResults.append(synth)
            } else if executedIdx < executedResults.count {
                toolResults.append(executedResults[executedIdx])
                executedIdx += 1
            }
        }

        toolObserver?(streamResult.resolvedToolCalls, toolResults)

        // 6. Process tool results (teammate, meeting, scratchpad, errors, learning)
        let outcome = await processToolResults(
            resolvedToolCalls: streamResult.resolvedToolCalls,
            results: toolResults,
            stepID: stepID,
            roleForMessage: roleForMessage,
            task: task,
            runIndex: runIndex,
            stepIndex: stepIndex,
            assistantContent: streamResult.assistantContent,
            client: client,
            config: config,
            tracker: tracker,
            memoryStore: memoryStore,
            wireIsMidPlanning: authorization.wireIsMidPlanning,
            conversationMessages: &conversationMessages,
            networkLogger: networkLogger
        )

        // 6a. Productivity accounting — the sole writer of the no-tool ceiling's reset.
        // The rule lives in `ToolTurnProductivity`; see it for why an all-rejected batch
        // must NOT re-arm the ceiling.
        //
        // Runs AFTER `processToolResults` so the `.tool` turns are already appended —
        // a terminal taken here leaves a well-formed conversation for the next replay,
        // instead of an assistant turn whose tool calls have no results.
        //
        // Reads `outcome.effectiveResults`, NOT `toolResults`: every deferred signal's entry in
        // the latter still carries the synchronous `{"status":"pending"}` placeholder's
        // `isError: false`, so a turn whose every call actually failed re-armed the ceiling this
        // switch exists to enforce.
        switch ToolTurnProductivity.classify(
            isAskSupervisorOnly: isAskSupervisorOnly, toolResults: outcome.effectiveResults)
        {
        case .productive:
            executionStates[TaskStepKey(taskID: task.id, stepID: stepID)]?
                .consecutiveNonProductiveTurns = 0
        case .nonProductive:
            if let stop = await noteNonProductiveTurn(
                stepID: stepID, taskID: task.id, roleDefinition: roleDefinition)
            {
                return stop
            }
        case .alreadyCounted:
            break
        }

        // 6b. Handle Supervisor question BEFORE artifact completeness — if the LLM both
        // completed all artifacts AND asked a supervisor question in one batch, the question
        // must not be silently dropped.
        if let autoAnswerStop = await handleSupervisorAutoAnswer(
            outcome: outcome,
            stepID: stepID,
            supervisorMode: supervisorMode,
            task: task,
            runIndex: runIndex,
            stepIndex: stepIndex,
            client: client,
            config: config,
            conversationMessages: &conversationMessages
        ) {
            return autoAnswerStop
        }

        if outcome.shouldStopForSupervisor, let q = outcome.supervisorQuestion {
            return .needsSupervisorInput(question: q)
        }

        // 7. Check if all expected artifacts have been created → auto-complete
        if let artifactStop = checkArtifactCompleteness(stepID: stepID, taskID: task.id) {
            return artifactStop
        }

        // 8. Check for looping patterns
        await checkAndInjectLoopWarning(
            stepID: stepID,
            taskID: task.id,
            tracker: tracker,
            allowedToolNames: allowedToolNames,
            conversationMessages: &conversationMessages
        )

        return .continueLoop
    }

    // MARK: - Context Budget

    /// Fires the context-overflow banner at most once per step.
    ///
    /// Once per step, not once per iteration: the banner is a single coalescing slot, and a
    /// prompt that overflows on iteration N overflows on every later one too (the
    /// conversation only grows), so re-posting would clobber every other message the user
    /// needs to see for the rest of the step.
    ///
    /// Takes the ALREADY-RENDERED `toolSchemaText` rather than `[ToolSchema]`: the caller shares
    /// one render with `prefixLedger.record`, and the append rule (empty tools, and a system
    /// prompt that already carries the catalog) has a single owner in
    /// `NativeLMStudioClient.toolSchemaTextForMeasurement`. Re-deriving it here is how the two
    /// measurement surfaces came to carry independent copies of the same wire-mirroring gate.
    func warnIfContextBudgetExceeded(
        stepID: String,
        taskID: Int,
        client: any LLMClient,
        config: LLMConfig,
        promptTokens estimate: Int
    ) async {
        let stepKey = TaskStepKey(taskID: taskID, stepID: stepID)
        // A missing entry means the step is not executing — `?.` yields nil, which fails
        // this comparison, so a torn-down step never probes or warns.
        guard executionStates[stepKey]?.didWarnContextOverflow == false else { return }

        let cacheKey = "\(config.baseURLString.normalizedBaseURL)|\(config.modelName)"
        // Memoize only a REAL answer. The old code cached `nil` for the service's
        // lifetime on the rationale that "a server which doesn't report a window won't
        // start mid-run" — true of `/api/show`, false of `/api/ps`, which reports
        // nothing precisely while the model is cold. That is the state of the first
        // probe of every session, so caching it is what left the net permanently
        // unarmed. Re-probe at most once per step instead: the latch below fires on the
        // first warning anyway, so a step pays at most one extra round-trip.
        let contextLength: Int?
        if let cached = probedContextLengths[cacheKey], let value = cached {
            contextLength = value
        } else if executionStates[stepKey]?.probedContextKeys.contains(cacheKey) == true {
            contextLength = nil
        } else {
            executionStates[stepKey]?.probedContextKeys.insert(cacheKey)
            contextLength = await client.modelContextLength(config: config)
            if contextLength != nil { probedContextLengths[cacheKey] = contextLength }
        }

        // No window → the verdict below can only ever be `.unknown`.
        // The estimate arrives precomputed: it is `PromptPrefixLedger.record`'s
        // `totalPromptTokens`, priced in the same walk that fingerprints the
        // request — this function no longer re-walks the conversation.
        guard let contextLength else { return }

        guard case .exceeded(let promptTokens, let window) =
            ContextBudgetPolicy.verdict(promptTokens: estimate, contextLength: contextLength)
        else { return }

        executionStates[stepKey]?.didWarnContextOverflow = true
        delegate?.setLastErrorMessageForUI(
            ContextBudgetPolicy.warningMessage(
                modelName: config.modelName,
                promptTokens: promptTokens,
                contextLength: window,
                provider: config.provider))
    }

    /// Post-send counterpart to `warnIfContextBudgetExceeded`, for the case that surface is
    /// structurally blind to: the window probe FAILED, so nothing warned before sending, and the
    /// server quietly truncated the prompt.
    ///
    /// This is the single most common real misconfiguration on a stock Ollama install — its
    /// runtime window is `OLLAMA_CONTEXT_LENGTH` (~4096) regardless of what the architecture
    /// supports, `modelContextLength` deliberately returns nil rather than overstating it, and an
    /// oversized prompt comes back HTTP 200 with the head silently dropped. The head is segment 0:
    /// the system prompt and tool catalog the prefix cache keys on. So the cache misses on every
    /// single turn while the ledger — which fingerprints what we SENT — reports `.reused` and the
    /// user sees only "the model ignores its instructions, and it's slow".
    ///
    /// Measured, never manufactured: the evidence is the server's own token count. The nil-probe
    /// rule in `ContextBudgetPolicy.verdict` is untouched.
    ///
    /// Runs BEFORE `reportPrefixCacheMissIfAny` so the latch it sets suppresses the strictly less
    /// severe cache banner for this same request (exemption 3) — a prompt whose head is being
    /// dropped has no cache to reason about.
    func confirmContextTruncation(
        stepID: String,
        taskID: Int,
        config: LLMConfig,
        appendedTokens: Int,
        serverPromptTokens: Int?
    ) async {
        let stepKey = TaskStepKey(taskID: taskID, stepID: stepID)
        guard executionStates[stepKey]?.didWarnContextOverflow == false else { return }

        // Remember this request's count for the next comparison regardless of the verdict — the
        // signal is a DELTA, so a request that says nothing still has to leave its baseline.
        let previous = executionStates[stepKey]?.lastServerPromptTokens
        if let serverPromptTokens, serverPromptTokens > 0 {
            executionStates[stepKey]?.lastServerPromptTokens = serverPromptTokens
        }

        // Only when the pre-send probe had no answer. A successful probe already owns this case
        // and warns before the tokens are spent, which is strictly better.
        let cacheKey = "\(config.baseURLString.normalizedBaseURL)|\(config.modelName)"
        if let cached = probedContextLengths[cacheKey], cached != nil { return }

        guard let processed = ContextBudgetPolicy.shouldReportTruncation(
            appendedTokens: appendedTokens,
            serverPromptTokens: serverPromptTokens,
            previousServerPromptTokens: previous)
        else { return }

        // Deliberately NOT memoized into `probedContextLengths`: the reported count is not the
        // window (measured at about half of it), and writing a wrong window there would make the
        // pre-send `verdict` produce confidently wrong `.exceeded` claims for every later step on
        // this model. One honest banner per step beats a fabricated window.
        executionStates[stepKey]?.didWarnContextOverflow = true
        delegate?.setLastErrorMessageForUI(
            ContextBudgetPolicy.truncationMessage(
                modelName: config.modelName,
                serverPromptTokens: processed,
                provider: config.provider))
    }

    // MARK: - Prompt-prefix (KV) cache

    /// Record that a self-contained call ran against `config`'s (server, model) — a judge
    /// verdict, the Supervisor auto-answer, a work-folder context generation.
    ///
    /// These have no prefix of their own to lose, so they are never victims. They are recorded
    /// because they are the only way `serverDroppedCache` can name WHO else was using the model
    /// when a step's cached prefix went missing, which is the difference between an actionable
    /// report and "something happened".
    func noteInterleavingCall(label: String, config: LLMConfig) async {
        _ = await prefixLedger.record(
            baseURL: config.baseURLString,
            model: config.modelName,
            owner: .oneShot(label: label),
            messages: [],
            toolSchemaText: "")
    }

    /// Combines what we know we sent with what the server said it did, applies the exemptions,
    /// and reports a genuine miss.
    ///
    /// Every exemption here is a DELIBERATE reset. They have to be named positively: a missed one
    /// becomes a permanent false positive on a surface that is always on, and a warning nobody
    /// believes is worse than no warning.
    func reportPrefixCacheMissIfAny(
        stepID: String,
        taskID: Int,
        runID: Int?,
        config: LLMConfig,
        observation: PromptPrefixLedger.Observation,
        serverPrefill: ServerPrefillReport?,
        clientResidency: ClientResidencyFacts? = nil
    ) async {
        let stepKey = TaskStepKey(taskID: taskID, stepID: stepID)
        // A missing entry means the step is torn down — never report for it.
        guard let state = executionStates[stepKey] else { return }

        // Feed the warm floor from every request, hit or miss: it is the MINIMUM rate this model
        // achieves on this machine, and only a hit can produce the minimum. The depth rides
        // along because the rate is ~`overhead / depth` on a hit — `nsPerToken` is non-nil only
        // when `promptTokens` is positive, so the fallback is unreachable.
        if let nsPerToken = serverPrefill?.nsPerToken {
            await prefixLedger.noteServerPrefill(
                baseURL: config.baseURLString, model: config.modelName,
                nsPerToken: nsPerToken, promptTokens: serverPrefill?.promptTokens ?? 0)
        }

        // Exemption 1: the planning-phase boundary sliced the conversation on purpose.
        if state.expectedPrefixResetPending {
            executionStates[stepKey]?.expectedPrefixResetPending = false
            return
        }

        // Exemption 2: the single-use image strip. The previous request carried images that were
        // nilled after sending, so this request legitimately diverges at that message.
        if state.lastRequestCarriedImages { return }

        // Exemption 3: the overflow banner is strictly more severe — it means the model may never
        // have received its instructions — and it fires pre-stream. Do not clobber it.
        // Read fail-closed, matching `warnIfContextBudgetExceeded`'s own nil handling.
        if executionStates[stepKey]?.didWarnContextOverflow ?? true { return }

        var server = PrefixCachePolicy.ServerSignals(
            modelLoadMs: serverPrefill?.modelLoadMs,
            prefillNsPerToken: serverPrefill?.nsPerToken,
            promptTokens: serverPrefill?.promptTokens)

        // Exemption 4: the user asked for immediate unload, so a reload is what they configured,
        // not a defect.
        //
        // Provider-scoped, because `keepAliveSeconds` is written onto EVERY config regardless of
        // provider while only Ollama reads it off the wire. On a provider whose residency this
        // app manages itself, a 0 the user set for their Ollama endpoint says nothing about what
        // just happened — and blinding the reload signal there is exactly wrong now that a
        // reload is detectable locally rather than only through a server figure LM Studio always
        // reports as 0.
        if config.keepAliveSeconds == 0, !config.provider.managesModelResidency {
            server.modelLoadMs = nil
        }

        var verdict = PrefixCachePolicy.resolve(
            structural: observation.structural,
            server: server,
            locallyReloaded: clientResidency?.appLoadedModelForThisRequest ?? false,
            warmFloorNsPerToken: observation.warmFloorNsPerToken,
            warmFloorPromptTokens: observation.warmFloorPromptTokens,
            floorSampleCount: observation.floorSampleCount,
            suspect: observation.suspect,
            totalPromptTokens: observation.totalPromptTokens,
            appendedTokens: observation.appendedTokens)

        // Exemption 5: a genuinely fresh conversation. NOT "iteration 1" — every re-entry replay
        // is also a first request, and a `.legacyConversation` replay is a documented guaranteed
        // miss worth reporting. Only a conversation built from scratch (a new step, or
        // `restartRole`'s deliberate re-synthesis) is inherent.
        if case .firstRequestForOwner = observation.structural {
            guard state.replaySource == .legacyConversation else { return }
            verdict = .missed(PrefixCachePolicy.Diagnosis(
                cause: .degradedReplay,
                commonSegments: 0,
                previousSegments: 0,
                discardedTokens: observation.totalPromptTokens))
        }

        guard var diagnosis = verdict.diagnosis else { return }

        // Exemption 6: below this the re-prefill costs well under a second.
        guard diagnosis.discardedTokens >= PrefixCachePolicy.materialTokenThreshold else { return }

        // Price the miss from the server's own numbers where they support it. Stamped here, the
        // one frame holding BOTH the verdict and `serverPrefill`, so every cause is priced the
        // same way — including the structural ones, whose diagnosis was decided by `compare`
        // before the send and therefore could not carry a measurement of its own.
        diagnosis.measuredExtraSeconds = PrefixCachePolicy.measuredExtraSeconds(
            prefillNsPerToken: server.prefillNsPerToken,
            warmFloorNsPerToken: observation.warmFloorNsPerToken,
            promptTokens: server.promptTokens)

        delegate?.reportPrefixCacheMiss(PrefixCacheMiss(
            owner: .step(taskID: taskID, stepID: stepID),
            runID: runID,
            modelName: config.modelName,
            diagnosis: diagnosis))
    }
}
