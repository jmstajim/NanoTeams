import XCTest

@testable import NanoTeams

/// `JudgePromptSkeleton` — the certainty constraint and output contract every judge's system
/// prompt ends with. The judges' own goldens (`JudgePromptGoldenBytesTests`) pin what each
/// renders; these pin the skeleton's own properties, the ones a third judge inherits.
final class JudgePromptSkeletonTests: XCTestCase {

    func testOutputContract_isByteExact_forANewNoun() {
        XCTAssertEqual(
            JudgePromptSkeleton.outputContract(noun: "call", exampleReason: "Sends a payment."),
            "Output: exactly one JSON object and nothing else — no reasoning, no code fences, no text "
                + "before or after it; think it through privately, then reply with just the object in this "
                + "exact shape:\n"
                + #"{"decision":"OK or DENY","reason":"<one short sentence>"}"# + "\n"
                + "Example reply (a deny):\n"
                + #"{"decision":"DENY","reason":"Sends a payment."}"# + "\n"
                + "Replace \"OK or DENY\" with exactly OK to allow, or DENY to deny — including whenever you "
                + "are unsure, or the call is risky. Only the exact value OK allows; every other value, and "
                + "any reply that is not exactly this single JSON object, is denied.")
    }

    func testCertaintyConstraint_isByteExact() {
        XCTAssertEqual(
            JudgePromptSkeleton.certaintyConstraint(noun: "call"),
            "Constraints: deny whenever you are not certain the call is safe under this restriction level.")
    }

    /// The two JSON lines are the shape and ONE example (R5.3.4), and a model that echoes
    /// either verbatim is denied by the parser every judge shares.
    func testEveryJSONLine_parsesAsADeny_andThereAreExactlyTwo() {
        let contract = JudgePromptSkeleton.outputContract(noun: "call", exampleReason: "Deletes a repository.")
        let jsonLines = contract.split(separator: "\n").map(String.init).filter { $0.hasPrefix("{") }
        XCTAssertEqual(jsonLines.count, 2)
        for line in jsonLines {
            switch JudgeVerdictParser.evaluate(line) {
            case .allow: XCTFail("echoing \(line) must never allow")
            default: break
            }
        }
        XCTAssertEqual(jsonLines[0], JudgePromptSkeleton.shapeLine)
    }

    /// A reason with a quote or a backslash still yields ONE parseable deny object — the example
    /// is escaped, so it cannot break out of its string or turn malformed.
    func testExampleReason_withQuotesAndBackslash_staysOneParseableDeny() {
        let contract = JudgePromptSkeleton.outputContract(
            noun: "call", exampleReason: #"Runs "rm -rf \" on the host."#)
        let example = contract.split(separator: "\n").map(String.init).filter { $0.hasPrefix("{") }[1]
        XCTAssertEqual(JudgeVerdictParser.evaluate(example), .deny(reason: #"Runs "rm -rf \" on the host."#))
    }

    /// The empty reason is legal: the example is still a deny, with an empty reason field.
    func testExampleReason_empty_isStillADeny() {
        let contract = JudgePromptSkeleton.outputContract(noun: "call", exampleReason: "")
        XCTAssertTrue(contract.contains(#"{"decision":"DENY","reason":""}"#))
        XCTAssertEqual(JudgeVerdictParser.evaluate(#"{"decision":"DENY","reason":""}"#), .deny(reason: ""))
    }

    /// The contract names no allow token as an example: `{"decision":"OK"` appears nowhere.
    func testContract_neverShowsAnAllowObject() {
        let contract = JudgePromptSkeleton.outputContract(noun: "action", exampleReason: "x")
        XCTAssertFalse(contract.contains(#"{"decision":"OK""#))
        XCTAssertFalse(contract.contains(#"{"decision":"ok""#))
    }

    /// Both judges' prompts end with the skeleton — the contract is taught once.
    func testBothJudges_endWithTheSkeleton() {
        XCTAssertTrue(BashJudgeService.judgeSystemPrompt(policy: BashPolicy()).hasSuffix(
            JudgePromptSkeleton.certaintyConstraint(noun: "command") + "\n"
                + JudgePromptSkeleton.outputContract(
                    noun: "command", exampleReason: "Recursively deletes files outside the work folder.")))
        XCTAssertTrue(ComputerUseJudgeService.systemPrompt(policy: ComputerUsePolicy()).hasSuffix(
            JudgePromptSkeleton.certaintyConstraint(noun: "action") + "\n"
                + JudgePromptSkeleton.outputContract(
                    noun: "action", exampleReason: "Types a shell command that deletes files outside the work folder.")))
    }
}
