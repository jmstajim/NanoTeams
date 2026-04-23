import XCTest
@testable import NanoTeams

/// Tests for persistence-roundtrip stability of the Team Activity feed ordering.
///
/// Repro of the user-visible bug: after closing and reopening a task, messages
/// appear out of order. Root cause was `JSONCoderFactory`'s `.iso8601` date
/// strategy truncating to whole seconds, collapsing `MonotonicClock`'s
/// millisecond-spaced timestamps into identical values on disk — so when the
/// feed is rebuilt after reload, items fall back to stable-sort insertion
/// order (messages first, then tool calls, then artifacts, etc.) instead of
/// interleaving chronologically.
///
/// Each test here encodes with the real persistence encoder used by
/// `AtomicJSONStore`, decodes with the real decoder, then feeds the result
/// through `ActivityFeedBuilder` and asserts the same relative ordering
/// observed in memory.
@MainActor
final class ActivityFeedPersistenceRoundTripTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - Encode/decode helper

    private func encodeDecode<T: Codable>(_ value: T) throws -> T {
        let data = try JSONCoderFactory.makePersistenceEncoder().encode(value)
        return try JSONCoderFactory.makeDateDecoder().decode(T.self, from: data)
    }

    // MARK: - Domain helpers

    private func makeMessage(
        role: LLMRole = .assistant,
        content: String,
        at timestamp: Date,
        sourceRole: Role? = nil,
        sourceContext: MessageSourceContext? = nil
    ) -> LLMMessage {
        LLMMessage(
            createdAt: timestamp,
            role: role,
            content: content,
            sourceRole: sourceRole,
            sourceContext: sourceContext
        )
    }

    private func makeToolCall(
        name: String = "read_file",
        at timestamp: Date,
        argumentsJSON: String = "{}"
    ) -> StepToolCall {
        StepToolCall(createdAt: timestamp, name: name, argumentsJSON: argumentsJSON)
    }

    private func makeArtifact(name: String, at timestamp: Date) -> Artifact {
        Artifact(name: name, createdAt: timestamp, updatedAt: timestamp)
    }

    private func makeStep(
        role: Role = .softwareEngineer,
        messages: [LLMMessage] = [],
        toolCalls: [StepToolCall] = [],
        artifacts: [Artifact] = [],
        status: StepStatus = .done
    ) -> StepExecution {
        StepExecution(
            id: role.baseID,
            role: role,
            title: "\(role.displayName) Step",
            status: status,
            artifacts: artifacts,
            toolCalls: toolCalls,
            llmConversation: messages
        )
    }

    private func makeRun(
        steps: [StepExecution],
        meetings: [TeamMeeting] = [],
        changeRequests: [ChangeRequest] = []
    ) -> Run {
        Run(id: 0, steps: steps, meetings: meetings, changeRequests: changeRequests)
    }

    private func makeChangeRequest(
        at timestamp: Date,
        changes: String = "Fix null check",
        requester: String = "codeReviewer",
        target: String = "softwareEngineer"
    ) -> ChangeRequest {
        ChangeRequest(
            createdAt: timestamp,
            requestingRoleID: requester,
            targetRoleID: target,
            changes: changes,
            reasoning: "missing guard"
        )
    }

    private func build(
        steps: [StepExecution],
        run: Run? = nil
    ) -> [ActivityFeedBuilder.TaggedItem] {
        ActivityFeedBuilder.buildTimelineItems(
            steps: steps,
            run: run,
            stepArtifactContentCache: [:],
            debugModeEnabled: false,
            isStreaming: { _ in false }
        )
    }

    /// Extracts a compact signature of each timeline item for ordering comparison.
    private func signatures(_ items: [ActivityFeedBuilder.TaggedItem]) -> [String] {
        items.map { tagged in
            switch tagged.item {
            case .llmMessage(let msg, _, _):
                return "msg:\(msg.content)"
            case .toolCall(let call, _, _):
                return "tool:\(call.name):\(call.argumentsJSON)"
            case .artifact(let artifact, _, _):
                return "art:\(artifact.name)"
            case .meetingMessage(let msg, _):
                return "meet:\(msg.content)"
            case .changeRequest(let req, _):
                return "cr:\(req.changes)"
            case .notification(_, _, let type, _):
                switch type {
                case .supervisorInput(let q, _, _, _, _, _):
                    return "notif:input:\(q)"
                case .failed:
                    return "notif:failed"
                }
            case .supervisorTask:
                return "supervisorTask"
            }
        }
    }

    // MARK: - 1. Low-level regression probe on JSONCoderFactory

    func testMonotonicClockTimestamps_surviveJSONRoundTrip() throws {
        // Generate five timestamps 1ms apart via MonotonicClock.
        let originals: [Date] = (0..<5).map { _ in MonotonicClock.shared.now() }

        // Sanity: they must actually be strictly increasing before encoding.
        for i in 1..<originals.count {
            XCTAssertLessThan(originals[i - 1], originals[i])
        }

        let data = try JSONCoderFactory.makePersistenceEncoder().encode(originals)
        let decoded = try JSONCoderFactory.makeDateDecoder().decode([Date].self, from: data)

        XCTAssertEqual(decoded.count, originals.count)
        // After roundtrip, strict ordering must still hold. With second-precision
        // encoding these all collapse to the same Date and this fails.
        for i in 1..<decoded.count {
            XCTAssertLessThan(
                decoded[i - 1], decoded[i],
                "Timestamp at \(i - 1) (\(decoded[i - 1])) must be strictly less than timestamp at \(i) (\(decoded[i])) after JSON roundtrip"
            )
        }
    }

    // MARK: - 2. Legacy (second-precision) decoder compatibility

    func testDecoder_acceptsLegacySecondPrecisionDates() throws {
        struct Wrapper: Codable { var d: Date }
        let legacyJSON = #"{"d":"2026-04-23T14:30:00Z"}"#.data(using: .utf8)!
        let decoded = try JSONCoderFactory.makeDateDecoder().decode(Wrapper.self, from: legacyJSON)
        // Expect 2026-04-23T14:30:00Z — verify by re-parsing with a known formatter.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let expected = formatter.date(from: "2026-04-23T14:30:00Z")!
        XCTAssertEqual(decoded.d, expected)
    }

    // MARK: - 3. Interleaved message / tool call / artifact within one step

    func testRoundTrip_preservesInterleavedMessageToolCallArtifactOrder() throws {
        let t1 = MonotonicClock.shared.now()
        let t2 = MonotonicClock.shared.now()
        let t3 = MonotonicClock.shared.now()
        let t4 = MonotonicClock.shared.now()
        let t5 = MonotonicClock.shared.now()

        let step = makeStep(
            messages: [
                makeMessage(content: "first-say", at: t1),
                makeMessage(content: "after-tool", at: t3)
            ],
            toolCalls: [
                makeToolCall(at: t2, argumentsJSON: "{\"a\":1}"),
                makeToolCall(at: t4, argumentsJSON: "{\"a\":2}")
            ],
            artifacts: [makeArtifact(name: "Design Spec", at: t5)]
        )

        // In-memory build — the baseline we expect to preserve through roundtrip.
        let inMemory = signatures(build(steps: [step]))
        XCTAssertEqual(inMemory, [
            "msg:first-say",
            "tool:read_file:{\"a\":1}",
            "msg:after-tool",
            "tool:read_file:{\"a\":2}",
            "art:Design Spec"
        ])

        // Roundtrip the whole step and rebuild.
        let decoded = try encodeDecode(step)
        let afterRoundtrip = signatures(build(steps: [decoded]))

        XCTAssertEqual(
            afterRoundtrip, inMemory,
            "Message/tool-call/artifact ordering must survive JSON roundtrip — \(afterRoundtrip) vs \(inMemory)"
        )
    }

    // MARK: - 4. Cross-step interleaving

    func testRoundTrip_preservesCrossStepInterleaving() throws {
        // Two steps whose items are interleaved in time: A-first, B-mid, A-last.
        let a1 = MonotonicClock.shared.now()
        let b1 = MonotonicClock.shared.now()
        let a2 = MonotonicClock.shared.now()

        let stepA = makeStep(
            role: .productManager,
            messages: [makeMessage(content: "A-first", at: a1)],
            toolCalls: [makeToolCall(at: a2, argumentsJSON: "{\"src\":\"A\"}")]
        )
        let stepB = makeStep(
            role: .techLead,
            messages: [makeMessage(content: "B-mid", at: b1)]
        )

        let inMemory = signatures(build(steps: [stepA, stepB]))
        XCTAssertEqual(inMemory, [
            "msg:A-first",
            "msg:B-mid",
            "tool:read_file:{\"src\":\"A\"}"
        ])

        // Roundtrip through a full Run (what actually lives on disk).
        let run = makeRun(steps: [stepA, stepB])
        let decodedRun = try encodeDecode(run)
        let afterRoundtrip = signatures(build(steps: decodedRun.steps, run: decodedRun))

        XCTAssertEqual(
            afterRoundtrip, inMemory,
            "Cross-step interleaving must survive roundtrip"
        )
    }

    // MARK: - 5. Answered supervisor-input notifications

    func testRoundTrip_preservesAnsweredSupervisorNotificationOrdering() throws {
        // Timeline: ask Q1 → answer A1 → ask Q2 → answer A2. Each 1ms apart.
        let ask1 = MonotonicClock.shared.now()
        let ans1 = MonotonicClock.shared.now()
        let ask2 = MonotonicClock.shared.now()
        let ans2 = MonotonicClock.shared.now()

        let step = makeStep(
            messages: [
                makeMessage(
                    role: .user,
                    content: "Supervisor answer: yes",
                    at: ans1,
                    sourceContext: .supervisorAnswer
                ),
                makeMessage(
                    role: .user,
                    content: "Supervisor answer: do it",
                    at: ans2,
                    sourceContext: .supervisorAnswer
                )
            ],
            toolCalls: [
                makeToolCall(
                    name: ToolNames.askSupervisor,
                    at: ask1,
                    argumentsJSON: #"{"question":"Proceed?"}"#
                ),
                makeToolCall(
                    name: ToolNames.askSupervisor,
                    at: ask2,
                    argumentsJSON: #"{"question":"Ready?"}"#
                )
            ]
        )

        let inMemory = signatures(build(steps: [step]))
        // Baseline: both notifications appear at their ANSWER timestamps, so they
        // sort after the corresponding answer message. The answered supervisor
        // `ask_supervisor` tool calls themselves are also in the timeline.
        let q1NotifIdx = inMemory.firstIndex(of: "notif:input:Proceed?")
        let q2NotifIdx = inMemory.firstIndex(of: "notif:input:Ready?")
        XCTAssertNotNil(q1NotifIdx)
        XCTAssertNotNil(q2NotifIdx)
        if let a = q1NotifIdx, let b = q2NotifIdx {
            XCTAssertLessThan(a, b, "Q1's notification must appear before Q2's in-memory")
        }

        let decoded = try encodeDecode(step)
        let afterRoundtrip = signatures(build(steps: [decoded]))

        XCTAssertEqual(
            afterRoundtrip, inMemory,
            "Answered-supervisor notification ordering must survive roundtrip"
        )
    }

    // MARK: - 6. Meeting messages interleaved with step items

    func testRoundTrip_preservesMeetingMessageOrderRelativeToStepItems() throws {
        // Step msg A → meeting msg M1 → step msg B → meeting msg M2.
        let tA = MonotonicClock.shared.now()
        let tM1 = MonotonicClock.shared.now()
        let tB = MonotonicClock.shared.now()
        let tM2 = MonotonicClock.shared.now()

        let step = makeStep(
            role: .productManager,
            messages: [
                makeMessage(content: "A-step", at: tA),
                makeMessage(content: "B-step", at: tB)
            ]
        )

        let meeting = TeamMeeting(
            topic: "Planning",
            initiatedBy: .productManager,
            participants: [.productManager, .techLead],
            messages: [
                TeamMessage(createdAt: tM1, role: .techLead, content: "M1-meet"),
                TeamMessage(createdAt: tM2, role: .techLead, content: "M2-meet")
            ]
        )

        let run = makeRun(steps: [step], meetings: [meeting])

        let inMemory = signatures(build(steps: [step], run: run))
        XCTAssertEqual(inMemory, [
            "msg:A-step",
            "meet:M1-meet",
            "msg:B-step",
            "meet:M2-meet"
        ])

        let decodedRun = try encodeDecode(run)
        let afterRoundtrip = signatures(build(steps: decodedRun.steps, run: decodedRun))

        XCTAssertEqual(
            afterRoundtrip, inMemory,
            "Meeting/step-item interleaving must survive roundtrip"
        )
    }

    // MARK: - 7. Change requests interleaved with step items

    func testRoundTrip_preservesChangeRequestOrderRelativeToStepItems() throws {
        // Step msg A → CR1 → step msg B → CR2.
        let tA = MonotonicClock.shared.now()
        let tCR1 = MonotonicClock.shared.now()
        let tB = MonotonicClock.shared.now()
        let tCR2 = MonotonicClock.shared.now()

        let step = makeStep(
            role: .codeReviewer,
            messages: [
                makeMessage(content: "A-step", at: tA),
                makeMessage(content: "B-step", at: tB)
            ]
        )
        let run = makeRun(
            steps: [step],
            changeRequests: [
                makeChangeRequest(at: tCR1, changes: "CR1"),
                makeChangeRequest(at: tCR2, changes: "CR2")
            ]
        )

        let inMemory = signatures(build(steps: [step], run: run))
        XCTAssertEqual(inMemory, [
            "msg:A-step", "cr:CR1", "msg:B-step", "cr:CR2"
        ])

        let decodedRun = try encodeDecode(run)
        let afterRoundtrip = signatures(build(steps: decodedRun.steps, run: decodedRun))
        XCTAssertEqual(afterRoundtrip, inMemory)
    }

    // MARK: - 8. Failed-step notification pins to completedAt

    func testRoundTrip_failedStepNotificationPinsToCompletedAt() throws {
        // Two steps — stepA finishes at completedAt BETWEEN two stepB messages;
        // the failed notification must land in that slot, not at the end.
        let tB1 = MonotonicClock.shared.now()
        let tCompletedA = MonotonicClock.shared.now()
        let tB2 = MonotonicClock.shared.now()

        let stepA = StepExecution(
            id: Role.softwareEngineer.baseID,
            role: .softwareEngineer,
            title: "SWE Step",
            status: .failed,
            completedAt: tCompletedA
        )
        let stepB = makeStep(
            role: .techLead,
            messages: [
                makeMessage(content: "B1", at: tB1),
                makeMessage(content: "B2", at: tB2)
            ]
        )

        let inMemory = signatures(build(steps: [stepA, stepB]))
        // Expected: B1 → failed-notification (at completedAtA) → B2.
        XCTAssertEqual(inMemory, ["msg:B1", "notif:failed", "msg:B2"])

        let run = makeRun(steps: [stepA, stepB])
        let decodedRun = try encodeDecode(run)
        let afterRoundtrip = signatures(build(steps: decodedRun.steps, run: decodedRun))

        XCTAssertEqual(
            afterRoundtrip, inMemory,
            "Failed-step notification must stay at completedAt after roundtrip"
        )
    }

    // MARK: - 9. Supervisor task stays first

    func testRoundTrip_supervisorTaskBriefStaysFirst() throws {
        // Task brief predates any step item.
        let tBrief = MonotonicClock.shared.now()
        let t1 = MonotonicClock.shared.now()
        let t2 = MonotonicClock.shared.now()

        let step = makeStep(
            role: .productManager,
            messages: [
                makeMessage(content: "first-msg", at: t1),
                makeMessage(content: "second-msg", at: t2)
            ]
        )

        func buildWithBrief(_ decodedStep: StepExecution, _ briefDate: Date) -> [String] {
            signatures(ActivityFeedBuilder.buildTimelineItems(
                steps: [decodedStep],
                run: nil,
                supervisorBrief: "Do thing",
                supervisorBriefDate: briefDate,
                stepArtifactContentCache: [:],
                debugModeEnabled: false,
                isStreaming: { _ in false }
            ))
        }

        let inMemory = buildWithBrief(step, tBrief)
        XCTAssertEqual(
            inMemory,
            ["supervisorTask", "msg:first-msg", "msg:second-msg"],
            "Supervisor task must be first in-memory"
        )

        // Encode Run + brief date together (the brief date is persisted on NTMSTask.createdAt).
        // For this roundtrip test we encode a wrapper so the brief date survives too.
        struct Payload: Codable { let step: StepExecution; let briefDate: Date }
        let encoded = try JSONCoderFactory.makePersistenceEncoder().encode(Payload(step: step, briefDate: tBrief))
        let decoded = try JSONCoderFactory.makeDateDecoder().decode(Payload.self, from: encoded)

        let afterRoundtrip = buildWithBrief(decoded.step, decoded.briefDate)
        XCTAssertEqual(
            afterRoundtrip, inMemory,
            "Supervisor task must stay first after roundtrip"
        )
    }

    // MARK: - 10. LLMMessage non-timestamp fields preserved

    func testRoundTrip_preservesLLMMessageThinkingSourceRoleAndContext() throws {
        // Mix of user+consultation-sourced and assistant-with-thinking messages.
        let t1 = MonotonicClock.shared.now()
        let t2 = MonotonicClock.shared.now()

        let assistantWithThinking = LLMMessage(
            createdAt: t1,
            role: .assistant,
            content: "answer",
            thinking: "let me think…"
        )
        let consultationResponse = LLMMessage(
            createdAt: t2,
            role: .user,
            content: "TL says OK",
            sourceRole: .techLead,
            sourceContext: .consultation
        )

        let step = makeStep(
            messages: [assistantWithThinking, consultationResponse]
        )
        let decoded = try encodeDecode(step)

        XCTAssertEqual(decoded.llmConversation.count, 2)

        let a = decoded.llmConversation[0]
        XCTAssertEqual(a.role, .assistant)
        XCTAssertEqual(a.thinking, "let me think…")
        XCTAssertNil(a.sourceRole)
        XCTAssertNil(a.sourceContext)

        let c = decoded.llmConversation[1]
        XCTAssertEqual(c.role, .user)
        XCTAssertEqual(c.sourceRole, .techLead)
        XCTAssertEqual(c.sourceContext, .consultation)
        // And the feed still shows both (consultation response is kept by the
        // filter because sourceContext is non-nil).
        let afterRoundtrip = signatures(build(steps: [decoded]))
        XCTAssertEqual(afterRoundtrip, ["msg:answer", "msg:TL says OK"])
    }

    // MARK: - 11. Meeting message thinking + tool summaries preserved

    func testRoundTrip_preservesMeetingMessageThinkingAndToolSummaries() throws {
        let t = MonotonicClock.shared.now()
        let summary = MeetingToolSummary(
            toolName: "read_file",
            arguments: #"{"path":"a.swift"}"#,
            result: #"{"lines":10}"#,
            isError: false
        )
        let msg = TeamMessage(
            createdAt: t,
            role: .techLead,
            content: "Let's go",
            replyToID: nil,
            messageType: .proposal,
            thinking: "weighing options",
            toolSummaries: [summary]
        )
        let meeting = TeamMeeting(
            topic: "Plan",
            initiatedBy: .productManager,
            participants: [.productManager, .techLead],
            messages: [msg]
        )
        let run = makeRun(steps: [], meetings: [meeting])

        let decodedRun = try encodeDecode(run)
        let decodedMsg = decodedRun.meetings.first?.messages.first
        XCTAssertNotNil(decodedMsg)
        XCTAssertEqual(decodedMsg?.thinking, "weighing options")
        XCTAssertEqual(decodedMsg?.messageType, .proposal)
        XCTAssertEqual(decodedMsg?.toolSummaries?.count, 1)
        XCTAssertEqual(decodedMsg?.toolSummaries?.first?.toolName, "read_file")
        XCTAssertEqual(decodedMsg?.toolSummaries?.first?.arguments, #"{"path":"a.swift"}"#)
    }

    // MARK: - 12. Real disk I/O via AtomicJSONStore

    func testRoundTrip_viaAtomicJSONStore_preservesOrder() throws {
        // Actual production persistence path: AtomicJSONStore used by NTMSRepository
        // for task.json. Uses the same factory-produced encoder/decoder under the hood,
        // but exercises the file layer so a future regression in the store itself
        // (e.g. someone wiring a fresh `JSONEncoder()` directly) would be caught.
        let t1 = MonotonicClock.shared.now()
        let t2 = MonotonicClock.shared.now()
        let t3 = MonotonicClock.shared.now()
        let t4 = MonotonicClock.shared.now()

        let step = makeStep(
            messages: [
                makeMessage(content: "first", at: t1),
                makeMessage(content: "third", at: t3)
            ],
            toolCalls: [
                makeToolCall(at: t2, argumentsJSON: "{}"),
                makeToolCall(at: t4, argumentsJSON: "{}")
            ]
        )
        let run = makeRun(steps: [step])

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityFeedPersistenceRoundTripTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let fileURL = tmpDir.appendingPathComponent("run.json")

        let store = AtomicJSONStore()
        try store.write(run, to: fileURL)
        let decodedRun = try store.read(Run.self, from: fileURL)

        let inMemory = signatures(build(steps: [step]))
        let afterDiskRoundtrip = signatures(build(steps: decodedRun.steps, run: decodedRun))
        XCTAssertEqual(
            afterDiskRoundtrip, inMemory,
            "Disk roundtrip via AtomicJSONStore must preserve timeline order"
        )
    }

    // MARK: - 13. Large realistic scenario — 24 items over multiple steps

    func testRoundTrip_largeRealisticScenario_preservesStrictChronology() throws {
        // 24 items with monotonic 1ms spacing spread across three steps and one
        // meeting. Any same-second collapse would reorder at least one pair.
        var steps: [StepExecution] = []
        var meetingMessages: [TeamMessage] = []

        var expectedSignatures: [String] = []

        // 3 steps × 6 items each (2 msgs, 2 tool calls, 1 artifact, 1 msg)
        for stepIdx in 0..<3 {
            let role: Role = [.productManager, .techLead, .softwareEngineer][stepIdx]
            var msgs: [LLMMessage] = []
            var tools: [StepToolCall] = []
            var arts: [Artifact] = []

            for itemIdx in 0..<6 {
                let t = MonotonicClock.shared.now()
                switch itemIdx {
                case 0, 1, 5:
                    let c = "s\(stepIdx)-m\(itemIdx)"
                    msgs.append(makeMessage(content: c, at: t))
                    expectedSignatures.append("msg:\(c)")
                case 2, 3:
                    let args = "{\"s\":\(stepIdx),\"i\":\(itemIdx)}"
                    tools.append(makeToolCall(at: t, argumentsJSON: args))
                    expectedSignatures.append("tool:read_file:\(args)")
                case 4:
                    let n = "Art-s\(stepIdx)"
                    arts.append(makeArtifact(name: n, at: t))
                    expectedSignatures.append("art:\(n)")
                default: break
                }
            }

            // Add one meeting message interleaved halfway through the second step
            if stepIdx == 1 {
                let tm = MonotonicClock.shared.now()
                meetingMessages.append(TeamMessage(createdAt: tm, role: .techLead, content: "m-mid"))
                expectedSignatures.append("meet:m-mid")
            }

            steps.append(makeStep(role: role, messages: msgs, toolCalls: tools, artifacts: arts))
        }

        let meeting = TeamMeeting(
            topic: "Sync",
            initiatedBy: .techLead,
            participants: [.techLead, .productManager],
            messages: meetingMessages
        )
        let run = makeRun(steps: steps, meetings: [meeting])

        let inMemory = signatures(build(steps: steps, run: run))
        XCTAssertEqual(inMemory.count, expectedSignatures.count, "In-memory count mismatch")

        let decodedRun = try encodeDecode(run)
        let afterRoundtrip = signatures(build(steps: decodedRun.steps, run: decodedRun))

        XCTAssertEqual(
            afterRoundtrip, inMemory,
            "Full timeline must remain byte-identical through roundtrip"
        )
        // Direct probe: every adjacent pair stays strictly ordered by createdAt.
        let taggedAfter = build(steps: decodedRun.steps, run: decodedRun)
        for i in 1..<taggedAfter.count {
            XCTAssertLessThan(
                taggedAfter[i - 1].item.createdAt, taggedAfter[i].item.createdAt,
                "Adjacent items must remain strictly ordered (idx \(i - 1) → \(i))"
            )
        }
    }

    // MARK: - 14. JSONL encoder also preserves fractional seconds

    func testJSONLEncoder_preservesFractionalSeconds() throws {
        // Tool-call logs go through `makeJSONLEncoder`; regression guard so that
        // path doesn't silently regress to second-precision if the factory changes.
        struct LogRecord: Codable { let createdAt: Date; let name: String }
        let t1 = MonotonicClock.shared.now()
        let t2 = MonotonicClock.shared.now()

        let encoder = JSONCoderFactory.makeJSONLEncoder()
        let decoder = JSONCoderFactory.makeDateDecoder()
        let d1 = try decoder.decode(LogRecord.self, from: encoder.encode(LogRecord(createdAt: t1, name: "a")))
        let d2 = try decoder.decode(LogRecord.self, from: encoder.encode(LogRecord(createdAt: t2, name: "b")))

        XCTAssertLessThan(d1.createdAt, d2.createdAt,
                          "JSONL encoder must also preserve sub-second precision through roundtrip")
    }
}
