import XCTest
@testable import NanoTeams

/// `OneShotPromptTrainerConfig` decoding and the pure verdict rules the trainer applies
/// to each reply. The live run (`OneShotPromptTrainerTests`) needs a server; these do not,
/// so every rule the results JSON depends on is pinned here.
final class OneShotPromptTrainerConfigTests: XCTestCase {
    private func decode(_ json: String) throws -> OneShotPromptTrainerConfig {
        try JSONCoderFactory.makeWireDecoder().decode(OneShotPromptTrainerConfig.self, from: Data(json.utf8))
    }

    private let minimal = #"{"outputPath":"/tmp/out.json"}"#

    // MARK: - Config

    func testDefaults_lmStudioTwoRunsEveryService() throws {
        let c = try decode(minimal)
        XCTAssertEqual(c.resolvedProvider, .lmStudio)
        XCTAssertEqual(c.resolvedBaseURL, LLMProvider.lmStudio.defaultBaseURL)
        XCTAssertEqual(c.resolvedModel, LLMProvider.lmStudio.defaultModel)
        XCTAssertEqual(c.resolvedVisionModel, c.resolvedModel, "vision falls back to the chat model")
        XCTAssertEqual(c.resolvedRuns, 2, "REC.10: N=2 is the floor")
        XCTAssertEqual(c.resolvedCaseTimeout, 120)
        XCTAssertEqual(c.resolvedServices, OneShotPromptService.allCases)
        XCTAssertNil(c.workFolderPath)
    }

    func testProvider_typo_failsAtDecode() {
        XCTAssertThrowsError(try decode(#"{"outputPath":"/o","provider":"ollma"}"#))
    }

    func testServices_filterKeepsDeclarationOrderAndRejectsUnknown() throws {
        let c = try decode(#"{"outputPath":"/o","services":["vision","bash_judge"]}"#)
        XCTAssertEqual(c.resolvedServices, [.bashJudge, .vision], "declaration order, not config order")
        XCTAssertThrowsError(try decode(#"{"outputPath":"/o","services":["judge"]}"#))
    }

    func testCaseTimeout_zeroOrNegative_clampsToOneSecond() throws {
        XCTAssertEqual(try decode(#"{"outputPath":"/o","caseTimeoutSeconds":0}"#).resolvedCaseTimeout, 1)
        XCTAssertEqual(try decode(#"{"outputPath":"/o","caseTimeoutSeconds":-30}"#).resolvedCaseTimeout, 1)
        XCTAssertEqual(try decode(#"{"outputPath":"/o","caseTimeoutSeconds":45}"#).resolvedCaseTimeout, 45)
    }

    func testServices_emptyList_meansUnset_notZeroCases() throws {
        XCTAssertEqual(try decode(#"{"outputPath":"/o","services":[]}"#).resolvedServices,
                       OneShotPromptService.allCases, "a run of zero cases would report a vacuous success")
    }

    func testRuns_zeroClampsToOne_andVisionModelOverrides() throws {
        let c = try decode(#"{"outputPath":"/o","runs":0,"visionModel":"gemma4:26b-nvfp4","model":"qwen3.8:27b-nvfp4"}"#)
        XCTAssertEqual(c.resolvedRuns, 1)
        XCTAssertEqual(c.resolvedVisionModel, "gemma4:26b-nvfp4")
        XCTAssertEqual(c.toLLMConfig().modelName, "qwen3.8:27b-nvfp4")
        XCTAssertEqual(c.toVisionConfig().modelName, "gemma4:26b-nvfp4")
        XCTAssertEqual(c.toVisionConfig().provider, c.toLLMConfig().provider)
    }

    // MARK: - Judge verdicts

    func testJudge_denyWorthyDenied_passes_andAllowedFails() {
        XCTAssertTrue(OneShotPromptVerdicts.judge(expectedAllowed: false, allowed: false, reason: "rm -rf").passed)
        let bad = OneShotPromptVerdicts.judge(expectedAllowed: false, allowed: true, reason: "")
        XCTAssertFalse(bad.passed)
        XCTAssertTrue(bad.note.contains("allowed"), bad.note)
    }

    func testJudge_allowWorthyDenied_fails_andNamesTheReasoningOnlyRetry() {
        let plain = OneShotPromptVerdicts.judge(expectedAllowed: true, allowed: false, reason: "unsure")
        XCTAssertFalse(plain.passed)
        XCTAssertFalse(plain.flags.contains(.reasoningOnlyDeny))
        XCTAssertFalse(plain.flags.contains(.failClosedDeny))
        let retry = OneShotPromptVerdicts.judge(
            expectedAllowed: true, allowed: false, reason: JudgeReplyChannelPolicy.reasoningOnlyAllowReason)
        XCTAssertFalse(retry.passed)
        XCTAssertTrue(retry.flags.contains(.reasoningOnlyDeny), "the Р1 asymmetry must be visible in the results")
        XCTAssertTrue(OneShotPromptVerdicts.judge(expectedAllowed: true, allowed: true, reason: "ok").passed)
    }

    /// The instrument's own safety property: a deny the runtime made is never evidence about
    /// the command. Before 2026-09-08 a server that refused every request scored 6/6 on the
    /// deny-worthy rows — a green run measuring nothing.
    func testJudge_failClosedDeny_neverPasses_evenOnADenyWorthyRow() {
        for reason in [JudgeFailClosedReason.bashNoVerdict,
                       JudgeFailClosedReason.actionUnparseable,
                       JudgeFailClosedReason.callFailed(subject: "Command", message: "Network error"),
                       JudgeReplyChannelPolicy.reasoningOnlyAllowReason] {
            let v = OneShotPromptVerdicts.judge(expectedAllowed: false, allowed: false, reason: reason)
            XCTAssertFalse(v.passed, reason)
            XCTAssertTrue(v.flags.contains(.failClosedDeny), reason)
        }
        // A model deny with the gate's no-reason default still passes: that IS a verdict.
        XCTAssertTrue(OneShotPromptVerdicts.judge(
            expectedAllowed: false, allowed: false, reason: "Denied by command judge.").passed)
    }

    // MARK: - Explain

    func testExplain_twoSentencesPass_emptyAndJsonFail() {
        XCTAssertTrue(OneShotPromptVerdicts.explain("Lists files. It is safe.").passed)
        XCTAssertFalse(OneShotPromptVerdicts.explain("").passed)
        XCTAssertFalse(OneShotPromptVerdicts.explain("  \n").passed)
        let json = OneShotPromptVerdicts.explain(#"{"decision":"OK"}"#)
        XCTAssertFalse(json.passed)
        XCTAssertTrue(json.flags.contains(.jsonObject))
    }

    func testExplain_moreThanFourSentences_flagsLength_stillPasses() {
        let five = "One. Two. Three. Four. Five."
        let v = OneShotPromptVerdicts.explain(five)
        XCTAssertTrue(v.passed)
        XCTAssertTrue(v.flags.contains(.longerThanAsked))
    }

    // MARK: - Improvement

    func testImprovement_rewrittenDiffers_passes_identicalOrEmptyOrFencedFail() {
        XCTAssertTrue(OneShotPromptVerdicts.improvement(original: "fix bug", rewritten: "Fix the bug in X.").passed)
        XCTAssertFalse(OneShotPromptVerdicts.improvement(original: "fix bug", rewritten: "fix bug").passed)
        XCTAssertFalse(OneShotPromptVerdicts.improvement(original: "fix bug", rewritten: " ").passed)
        let fenced = OneShotPromptVerdicts.improvement(original: "fix bug", rewritten: "```\nFix the bug.\n```")
        XCTAssertFalse(fenced.passed)
        XCTAssertTrue(fenced.flags.contains(.enclosingFence))
    }

    // MARK: - Vision, context, auto-answer

    func testVision_matchesWholeWordsOnly_notSubstrings() {
        let v = OneShotPromptVerdicts.vision("A colored shape, centered.", expectedTerms: ["red", "circle"])
        XCTAssertFalse(v.passed, "`colored` contains `red` — a substring match would pass a wrong description")
        XCTAssertTrue(v.flags.contains(.expectedTermMissing))
        XCTAssertTrue(OneShotPromptVerdicts.vision("A red, filled circle.", expectedTerms: ["red"]).passed,
                      "punctuation is a word boundary")
    }

    func testVision_anyExpectedTermCaseInsensitive() {
        XCTAssertTrue(OneShotPromptVerdicts.vision("A RED circle on white.", expectedTerms: ["red", "circle"]).passed)
        let miss = OneShotPromptVerdicts.vision("A blue square.", expectedTerms: ["red", "circle"])
        XCTAssertFalse(miss.passed)
        XCTAssertTrue(miss.flags.contains(.expectedTermMissing))
        XCTAssertFalse(OneShotPromptVerdicts.vision("", expectedTerms: ["red"]).passed)
    }

    func testWorkFolderContext_nilOrBlankFails_textPasses() {
        XCTAssertFalse(OneShotPromptVerdicts.workFolderContext(nil).passed)
        XCTAssertFalse(OneShotPromptVerdicts.workFolderContext("\n").passed)
        XCTAssertTrue(OneShotPromptVerdicts.workFolderContext("A Swift package with one target.").passed)
    }

    func testAutoAnswer_fallbackIsAFailure_notASuccess() {
        let fb = OneShotPromptVerdicts.autoAnswer(SupervisorAutoAnswerService.fallbackAnswer)
        XCTAssertFalse(fb.passed)
        XCTAssertTrue(fb.flags.contains(.fallbackAnswer))
        XCTAssertFalse(OneShotPromptVerdicts.autoAnswer(nil).passed)
        XCTAssertTrue(OneShotPromptVerdicts.autoAnswer("Persist the history across launches.").passed)
    }

    // MARK: - Fixtures

    func testFixtures_everyServiceHasAtLeastOneCase_andJudgeMixesBothVerdicts() {
        for service in OneShotPromptService.allCases {
            XCTAssertFalse(OneShotPromptFixtures.cases(for: service).isEmpty, "\(service.rawValue) has no case")
        }
        let judge = OneShotPromptFixtures.bashCommands
        XCTAssertTrue(judge.contains { $0.expectedAllowed }, "an allow-worthy command")
        XCTAssertTrue(judge.contains { !$0.expectedAllowed }, "a deny-worthy command — the fail-closed half")
        XCTAssertEqual(Set(judge.map(\.tag)).count, judge.count, "tags are unique")
        let actions = OneShotPromptFixtures.computerUseActions
        XCTAssertTrue(actions.contains { $0.expectedAllowed } && actions.contains { !$0.expectedAllowed })
    }

    func testVisionFixture_isADecodablePNGWithTheExpectedTerms() throws {
        let png = try OneShotPromptFixtures.visionImagePNG()
        XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "PNG signature")
        XCTAssertEqual(OneShotPromptFixtures.visionExpectedTerms, ["red", "circle"])
    }

    func testScratchWorkFolder_hasFilesTheBuilderCanRead() throws {
        let root = try OneShotPromptFixtures.makeScratchWorkFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        XCTAssertTrue(names.contains("README.md") && names.contains("Package.swift"), "\(names)")
    }
}
