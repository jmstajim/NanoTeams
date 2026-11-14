import XCTest
@testable import NanoTeams

/// Offline unit tests for `AutovisorContinuationTrainer` (REC.10).
///
/// Runs on every build without an LLM server: verifies config decoding, real `PromptBuilder`
/// + `LLMExecutionService.resolveToolSchemas` assembly for all six scenarios, Variant A vs B
/// envelope injection, next-turn classification across native and prompt-taught tool calls,
/// and a full trainer pass against a scripted `LLMClient`.
@MainActor
final class AutovisorContinuationTrainerOfflineTests: XCTestCase {

    func testConfigDefaultsAndScenarioFiltering_preservesDeclarationOrderAndSkipsBeforeOnScenario6() throws {
        let bare = try JSONCoderFactory.makeWireDecoder().decode(
            AutovisorContinuationTrainerConfig.self,
            from: Data(#"{"outputPath":"/tmp/autovisor_cont.json"}"#.utf8)
        )
        XCTAssertEqual(bare.resolvedProvider, .lmStudio)
        XCTAssertEqual(bare.resolvedBaseURL, "http://127.0.0.1:1234")
        XCTAssertEqual(bare.resolvedRuns, 2)
        XCTAssertEqual(bare.resolvedVariant, .before)
        XCTAssertEqual(bare.resolvedToolCallingPreference, .auto)
        XCTAssertEqual(bare.resolvedScenarios, AutovisorContinuationScenario.allCases)
        XCTAssertFalse(AutovisorContinuationScenario.delegationChildPausedTimeout.supportsBeforeArm)
        XCTAssertTrue(AutovisorContinuationScenario.pauseNoEngine.supportsBeforeArm)

        let subset = try JSONCoderFactory.makeWireDecoder().decode(
            AutovisorContinuationTrainerConfig.self,
            from: Data(#"{"outputPath":"/tmp/out.json","variant":"both","scenarios":["repeated_close","pause_no_engine"],"toolCallingPreference":"native"}"#.utf8)
        )
        XCTAssertEqual(subset.resolvedVariant, .both)
        XCTAssertEqual(subset.resolvedToolCallingPreference, .native)
        XCTAssertEqual(
            subset.resolvedScenarios,
            [.pauseNoEngine, .repeatedClose],
            "declaration order must be preserved regardless of config order"
        )
    }

    func testBuildFixture_constructsRealPromptBuilderSystemPromptAndToolSchemasForAllSixScenarios() async throws {
        for scenario in AutovisorContinuationScenario.allCases {
            let afterFixture = try await AutovisorContinuationTrainer.buildFixture(
                scenario: scenario,
                arm: .after,
                toolCallingMode: .promptTaught
            )
            XCTAssertGreaterThan(
                afterFixture.systemPromptChars, 1500,
                "\(scenario.rawValue): system prompt must be built by real PromptBuilder"
            )
            XCTAssertEqual(afterFixture.messages.first?.role, .system)
            XCTAssertEqual(afterFixture.messages.last?.role, .tool)
            let joinedToolContents = afterFixture.messages
                .filter { $0.role == .tool }
                .compactMap(\.content)
                .joined(separator: "\n")
            XCTAssertTrue(
                joinedToolContents.contains(afterFixture.injectedEnvelope),
                "\(scenario.rawValue): tool turns must carry the injected envelope"
            )
            XCTAssertFalse(afterFixture.tools.isEmpty, "\(scenario.rawValue): tool schemas must not be empty")

            if scenario == .delegationChildPausedTimeout {
                XCTAssertTrue(
                    afterFixture.tools.contains(where: { $0.name == ToolNames.delegateToTeam }),
                    "scenario 6 must advertise delegate_to_team on Coding Agent"
                )
                XCTAssertTrue(
                    afterFixture.tools.contains(where: { $0.name == ToolNames.resumeDelegation }),
                    "scenario 6 must advertise resume_delegation on Coding Agent"
                )
                XCTAssertTrue(afterFixture.injectedEnvelope.contains("child_paused"))
            } else {
                XCTAssertTrue(
                    afterFixture.tools.contains(where: { $0.name == ToolNames.controlTask }),
                    "\(scenario.rawValue) must advertise Autovisor Manager tools"
                )
                let beforeFixture = try await AutovisorContinuationTrainer.buildFixture(
                    scenario: scenario,
                    arm: .before,
                    toolCallingMode: .promptTaught
                )
                XCTAssertNotEqual(
                    beforeFixture.injectedEnvelope,
                    afterFixture.injectedEnvelope,
                    "\(scenario.rawValue): Variant A and Variant B envelopes must differ"
                )
            }
        }
    }

    func testClassify_scoresNextStepToolArgumentsRepeatAndVerdictAcrossBothArms() async throws {
        let managerFixture = try await AutovisorContinuationTrainer.buildFixture(
            scenario: .messageTaskInReview,
            arm: .after,
            toolCallingMode: .promptTaught
        )

        // 1. Repeating the exact same action is flagged and fails the verdict.
        let repeated = AutovisorContinuationTrainer.classify(
            scenario: .messageTaskInReview,
            arm: .after,
            content: "",
            nativeCalls: [
                StepToolCall(
                    name: ToolNames.messageTask,
                    argumentsJSON: managerFixture.targetArgumentsJSON
                )
            ],
            advertisedTools: managerFixture.tools,
            targetToolName: managerFixture.targetToolName,
            targetArgumentsJSON: managerFixture.targetArgumentsJSON
        )
        XCTAssertTrue(repeated.repeatedSameAction)
        XCTAssertFalse(repeated.verdict.passed)

        // 2. Calling manage_role request_changes after the Review refusal passes.
        let recovered = AutovisorContinuationTrainer.classify(
            scenario: .messageTaskInReview,
            arm: .after,
            content: "",
            nativeCalls: [
                StepToolCall(
                    name: ToolNames.manageRole,
                    argumentsJSON: #"{"action":"request_changes","comment":"Add negative input tests.","role_id":"software_engineer","task_id":4}"#
                )
            ],
            advertisedTools: managerFixture.tools,
            targetToolName: managerFixture.targetToolName,
            targetArgumentsJSON: managerFixture.targetArgumentsJSON
        )
        XCTAssertEqual(recovered.toolNames, [ToolNames.manageRole])
        XCTAssertFalse(recovered.repeatedSameAction)
        XCTAssertTrue(recovered.verdict.passed)

        // 3. Prompt-taught `<|call|>` envelope on scenario 6 (delegation child paused) resolves and passes.
        let delegationFixture = try await AutovisorContinuationTrainer.buildFixture(
            scenario: .delegationChildPausedTimeout,
            arm: .after,
            toolCallingMode: .promptTaught
        )
        let delegationPass = AutovisorContinuationTrainer.classify(
            scenario: .delegationChildPausedTimeout,
            arm: .after,
            content: #"<|call|>{"name":"resume_delegation","arguments":{"child_task_id":7}}<|end|>"#,
            nativeCalls: [],
            advertisedTools: delegationFixture.tools,
            targetToolName: delegationFixture.targetToolName,
            targetArgumentsJSON: delegationFixture.targetArgumentsJSON
        )
        XCTAssertEqual(delegationPass.toolNames, [ToolNames.resumeDelegation])
        XCTAssertFalse(delegationPass.repeatedSameAction)
        XCTAssertTrue(delegationPass.verdict.passed)
    }

    // MARK: - Production-rendered message_task results

    /// Only the two message scenarios have a `message_task` slot. Every other scenario answers
    /// `nil` on both arms, and rendering one throws rather than measuring a borrowed reply.
    func testMessageScenarioRendering_refusesEveryScenarioWithoutAMessageTaskSlot() async {
        let args = #"{"message":"Keep going.","task_id":4}"#
        let others = AutovisorContinuationScenario.allCases.filter {
            $0 != .messageTaskInReview && $0 != .messageTaskOnPaused
        }
        XCTAssertEqual(others.count, 4)
        for scenario in others {
            XCTAssertNil(AutovisorContinuationTrainer.messageScenarioTaskStatusEnvelope(scenario: scenario), scenario.rawValue)
            for arm in AutovisorContinuationArm.allCases {
                XCTAssertNil(
                    AutovisorContinuationTrainer.messageTaskReply(scenario: scenario, arm: arm, taskID: 4),
                    "\(scenario.rawValue)/\(arm.rawValue)")
                do {
                    _ = try await AutovisorContinuationTrainer.messageTaskEnvelope(
                        scenario: scenario, arm: arm, argumentsJSON: args)
                    XCTFail("\(scenario.rawValue)/\(arm.rawValue) must not render a message_task result")
                } catch {
                    XCTAssertEqual(
                        error as? AutovisorContinuationFixtureError, .notAMessageTaskScenario(scenario),
                        "\(scenario.rawValue)/\(arm.rawValue)")
                }
            }
        }
    }

    /// A call production's decoder refuses is thrown, never rendered into an envelope to measure.
    func testMessageTaskEnvelope_throwsTheDecodersRefusalForEveryCallProductionWouldRefuse() async {
        let refused = [
            #"{"message":"Keep going."}"#,
            #"{"message":"   ","task_id":4}"#,
            #"{"message":"Keep going.","task_id":"four"}"#,
            "keep going on task four",
        ]
        for arguments in refused {
            do {
                _ = try await AutovisorContinuationTrainer.messageTaskEnvelope(
                    scenario: .messageTaskInReview, arm: .after, argumentsJSON: arguments)
                XCTFail("`\(arguments)` must not render")
            } catch {
                XCTAssertTrue(error is AutovisorDecodeFailure, "`\(arguments)`: \(error)")
            }
        }
    }

    /// The reply names the task the call named, on both arms of both scenarios.
    func testMessageTaskEnvelope_namesTheTaskTheCallNamed() async throws {
        let args = #"{"message":"Keep going.","task_id":42}"#
        let expected: [(AutovisorContinuationScenario, AutovisorContinuationArm, String)] = [
            (.messageTaskInReview, .before, AutovisorReply.messageQueued(taskID: 42).text),
            (.messageTaskInReview, .after, AutovisorReply.messageDiscardedTaskFinished(taskID: 42).text),
            (.messageTaskOnPaused, .before, AutovisorReply.messageQueued(taskID: 42).text),
            (.messageTaskOnPaused, .after, AutovisorReply.messageQueuedAndResumed(taskID: 42).text),
        ]
        for (scenario, arm, text) in expected {
            let envelope = try await AutovisorContinuationTrainer.messageTaskEnvelope(
                scenario: scenario, arm: arm, argumentsJSON: args)
            XCTAssertTrue(envelope.contains(text), "\(scenario.rawValue)/\(arm.rawValue): \(envelope)")
            XCTAssertFalse(envelope.contains("#4."), "\(scenario.rawValue)/\(arm.rawValue): \(envelope)")
        }
    }

    func testRun_executesAllConfiguredArmsThroughInjectedClientAndWritesResultsJSON() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("autovisor-cont-trainer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("results.json")
        let config = AutovisorContinuationTrainerConfig(
            provider: .lmStudio,
            baseURL: "http://127.0.0.1:1234",
            model: "qwen3.6-35b-a3b-splash",
            toolCallingPreference: .promptTaught,
            outputPath: outputURL.path,
            runs: 1,
            caseTimeoutSeconds: 10,
            variant: .both,
            scenarios: [.repeatedClose, .delegationChildPausedTimeout]
        )

        let client = ScriptedToolCallClient(script: [
            .toolCall(name: ToolNames.waitForEvents, argumentsJSON: "{}"),
            .toolCall(name: ToolNames.waitForEvents, argumentsJSON: "{}"),
            .toolCall(name: ToolNames.resumeDelegation, argumentsJSON: #"{"child_task_id":7}"#),
        ])
        let trainer = AutovisorContinuationTrainer(config: config, client: client)
        let result = try await trainer.run()

        // repeated_close runs (.before + .after), delegation_child_paused_timeout runs (.after only) -> 3 cases.
        XCTAssertEqual(client.callCount, 3)
        XCTAssertEqual(result.cases.count, 3)
        XCTAssertEqual(
            result.cases.map { "\($0.scenario.rawValue):\($0.arm.rawValue)" },
            [
                "repeated_close:before",
                "repeated_close:after",
                "delegation_child_paused_timeout:after",
            ]
        )
        XCTAssertTrue(result.cases.allSatisfy(\.verdict.passed))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
    }
}
