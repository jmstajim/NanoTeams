import XCTest

@testable import NanoTeams

/// The whole matrix. Five steps, two modes, two trust settings, two annotations and three pin
/// states — so the cases are enumerated rather than sampled, because the ones that matter are
/// exactly the combinations nobody thinks to try.
final class MCPPermissionServiceTests: XCTestCase {

    private let approvedHash = "h1"

    private func pin(_ hash: String = "h1", alwaysAllow: Bool = false) -> MCPToolPin {
        MCPToolPin(toolName: "t", hash: hash, approvedAt: Date(timeIntervalSince1970: 0), alwaysAllow: alwaysAllow)
    }

    /// Every hint STATED — the server spelled all four out.
    private func annotations(readOnly: Bool, destructive: Bool = true) -> MCPToolAnnotations {
        MCPToolAnnotations(title: nil, stated: [
            .readOnly: readOnly, .destructive: destructive, .idempotent: false, .openWorld: true,
        ])
    }

    private func evaluate(
        mode: MCPApprovalMode,
        trusted: Bool = false,
        readOnly: Bool = false,
        destructive: Bool = true,
        pin: MCPToolPin? = nil,
        liveHash: String = "h1"
    ) -> MCPPermissionDecision {
        MCPPermissionService.evaluate(
            approvalMode: mode, serverTrusted: trusted,
            annotations: annotations(readOnly: readOnly, destructive: destructive),
            pin: pin, liveHash: liveHash)
    }

    private func isDeny(_ decision: MCPPermissionDecision) -> Bool {
        if case .deny = decision { return true }
        return false
    }

    private func isAsk(_ decision: MCPPermissionDecision) -> Bool {
        if case .ask = decision { return true }
        return false
    }

    private func reason(_ decision: MCPPermissionDecision) -> String {
        switch decision {
        case .allow: return ""
        case .ask(let reason), .deny(let reason): return reason
        }
    }

    // MARK: - Step 0: pinning is the floor

    /// Above the mode, above `alwaysAllow`, above trust. A tool nobody reviewed never reaches
    /// a prompt, so a call landing here means the catalogue moved under a running step.
    func testAnUnpinnedToolIsDeniedInEveryMode() {
        for mode in MCPApprovalMode.allCases {
            XCTAssertTrue(isDeny(evaluate(mode: mode, trusted: true, readOnly: true, pin: nil)), mode.rawValue)
        }
    }

    /// The rug pull. Without this arm a tool approved as honest and then rewritten would ride
    /// its own stale `alwaysAllow` straight through under Semi-automatic.
    func testAChangedHashIsDeniedEvenWithAnAlwaysAllowGrant() {
        let decision = evaluate(
            mode: .semiAutomatic, trusted: true, readOnly: true,
            pin: pin(approvedHash, alwaysAllow: true), liveHash: "h2")
        XCTAssertTrue(isDeny(decision))
        XCTAssertTrue(reason(decision).contains("changed"), reason(decision))
    }

    func testBothDenialsTellTheModelWhatToDoInstead() {
        for decision in [evaluate(mode: .manual, pin: nil),
                         evaluate(mode: .manual, pin: pin(), liveHash: "h2")] {
            XCTAssertTrue(isDeny(decision))
            XCTAssertTrue(reason(decision).contains("Drop the call"), reason(decision))
        }
    }

    // MARK: - Step 1: Manual asks above everything else

    /// The user asked to see every call. A prior grant and a read-only annotation are both
    /// skipped — same placement as `bash`'s Manual, above its read-only bypass.
    func testManualAsksEvenForATrustedReadOnlyToolThatWasAlwaysAllowed() {
        let decision = evaluate(
            mode: .manual, trusted: true, readOnly: true, destructive: false, pin: pin(alwaysAllow: true))
        XCTAssertTrue(isAsk(decision))
        XCTAssertEqual(reason(decision), MCPPermissionService.manualModeReason)
        XCTAssertTrue(reason(decision).contains("manual"), reason(decision))
    }

    /// The trust mark counts exactly under the modes that say they read it
    /// (`MCPApprovalMode.readsTrustMark`, which greys the switch out in the editor and names
    /// those modes under it): under any other, a trusted server's read-only tool asks exactly
    /// as an untrusted one's does, while the stored mark waits for a mode that reads it.
    func testTheTrustMarkCountsOnlyUnderTheModesThatReadIt() {
        for mode in MCPApprovalMode.allCases {
            let trusted = evaluate(mode: mode, trusted: true, readOnly: true, destructive: false, pin: pin())
            let untrusted = evaluate(mode: mode, trusted: false, readOnly: true, destructive: false, pin: pin())
            if mode.readsTrustMark {
                XCTAssertEqual(trusted, .allow, "\(mode)")
                XCTAssertNotEqual(trusted, untrusted, "\(mode)")
            } else {
                XCTAssertEqual(trusted, untrusted, "\(mode): the mark is ignored")
                XCTAssertTrue(isAsk(trusted), "\(mode)")
            }
        }
    }

    // MARK: - Step 2: a grant a person gave

    func testAlwaysAllowClearsACallUnderSemiAutomatic() {
        XCTAssertEqual(evaluate(mode: .semiAutomatic, pin: pin(alwaysAllow: true)), .allow)
    }

    /// A grant survives an untrusted server and a destructive annotation: a person looked at
    /// this exact tool at this exact hash and said yes.
    func testAlwaysAllowOutranksBothTheTrustSwitchAndTheAnnotations() {
        XCTAssertEqual(
            evaluate(mode: .semiAutomatic, trusted: false, readOnly: false, destructive: true,
                     pin: pin(alwaysAllow: true)),
            .allow)
    }

    // MARK: - Step 3: the one annotation-driven bypass

    func testATrustedServersReadOnlyToolRunsUnderSemiAutomatic() {
        XCTAssertEqual(
            evaluate(mode: .semiAutomatic, trusted: true, readOnly: true, destructive: false, pin: pin()),
            .allow)
    }

    /// A tool claiming to be read-only AND destructive is contradicting itself, and the rule
    /// that annotations may only raise friction says the harsher claim counts. Reading the
    /// pair as "read-only wins" would hand a server a two-field way to lower friction on a
    /// tool it has already called destructive.
    func testATrustedServerCannotClearACallByClaimingBothAtOnce() {
        let decision = evaluate(mode: .semiAutomatic, trusted: true, readOnly: true, destructive: true, pin: pin())
        XCTAssertTrue(isAsk(decision))
        XCTAssertTrue(reason(decision).contains("at once"), reason(decision))
    }

    /// An untrusted server's `readOnlyHint` is a claim it makes about itself — and the
    /// cheapest lie an attacker can tell.
    func testAnUntrustedServersReadOnlyClaimClearsNothing() {
        let decision = evaluate(mode: .semiAutomatic, trusted: false, readOnly: true, destructive: false, pin: pin())
        XCTAssertTrue(isAsk(decision))
        XCTAssertTrue(reason(decision).contains("not marked trusted"), reason(decision))
    }

    // MARK: - Step 3, read as the spec reads a read-only claim

    /// What a server sends, as the descriptor factory reads it — not four booleans spelled out,
    /// which would state every hint.
    private func evaluate(
        mode: MCPApprovalMode, trusted: Bool, sent annotations: [String: JSONValue]
    ) -> MCPPermissionDecision {
        MCPPermissionService.evaluate(
            approvalMode: mode, serverTrusted: trusted,
            annotations: MCPToolAnnotations(raw: .object(annotations)),
            pin: pin(), liveHash: approvedHash)
    }

    /// A trusted server that marks its read tools the usual way — `readOnlyHint: true` and
    /// nothing about destruction, which the spec reads only for a tool that writes — has them
    /// run under Semi-automatic. Trusted means exactly "read-only counts".
    ///
    /// RED until 2026-09-24: the spec's `destructiveHint: true` default counted against a tool
    /// stated read-only, so the Trusted mark did nothing for such a server.
    func testATrustedServersToolStatingOnlyReadOnlyRunsUnderSemiAutomatic() {
        XCTAssertEqual(
            evaluate(mode: .semiAutomatic, trusted: true, sent: ["readOnlyHint": .bool(true)]), .allow)
    }

    /// The same tool on a server nobody marked trusted asks — and the model is told the true
    /// reason, not that the server contradicted itself.
    ///
    /// RED until 2026-09-24: the reason said "read-only and as destructive at once", which the
    /// server never said.
    func testAnUntrustedServersToolStatingOnlyReadOnlyAsksBecauseTheServerIsNotTrusted() {
        let decision = evaluate(mode: .semiAutomatic, trusted: false, sent: ["readOnlyHint": .bool(true)])
        XCTAssertTrue(isAsk(decision))
        XCTAssertTrue(reason(decision).contains("not marked trusted"), reason(decision))
        XCTAssertFalse(reason(decision).contains("at once"), reason(decision))
    }

    /// A server that STATES both is contradicting itself: the harsher reading counts, trusted or
    /// not, and the reason names the pair.
    func testATrustedServerThatStatesReadOnlyAndDestructiveStillAsks() {
        let decision = evaluate(
            mode: .semiAutomatic, trusted: true,
            sent: ["readOnlyHint": .bool(true), "destructiveHint": .bool(true)])
        XCTAssertTrue(isAsk(decision))
        XCTAssertTrue(reason(decision).contains("at once"), reason(decision))
    }

    /// Manual asks above the read-only reading, whatever the server states.
    func testManualStillAsksForATrustedToolStatingOnlyReadOnly() {
        let decision = evaluate(mode: .manual, trusted: true, sent: ["readOnlyHint": .bool(true)])
        XCTAssertTrue(isAsk(decision))
        XCTAssertTrue(reason(decision).contains("manual"), reason(decision))
    }

    /// A tool that states it writes, or says nothing, keeps the destructive default a trusted
    /// server cannot talk its way past.
    func testATrustedServersToolThatDoesNotStateReadOnlyStillAsks() {
        for sent: [String: JSONValue] in [[:], ["readOnlyHint": .bool(false)], ["destructiveHint": .bool(false)]] {
            XCTAssertTrue(isAsk(evaluate(mode: .semiAutomatic, trusted: true, sent: sent)), "\(sent)")
        }
    }

    /// Trust is not a blanket permission: it buys the read-only bypass and nothing else.
    func testTrustDoesNotClearAToolThatWritesEvenOnSemiAutomatic() {
        XCTAssertTrue(isAsk(evaluate(mode: .semiAutomatic, trusted: true, readOnly: false, pin: pin())))
    }

    // MARK: - Step 4: the reason names the nearest miss

    func testTheAskReasonNamesWhyRatherThanRepeatingTheMode() {
        XCTAssertTrue(reason(evaluate(mode: .semiAutomatic, trusted: true, readOnly: false, destructive: true,
                                      pin: pin())).contains("destructive"))
        XCTAssertTrue(reason(evaluate(mode: .semiAutomatic, trusted: true, readOnly: false, destructive: false,
                                      pin: pin())).contains("making changes"))
        XCTAssertTrue(reason(evaluate(mode: .semiAutomatic, trusted: false, readOnly: true, destructive: false,
                                      pin: pin())).contains("not marked trusted"))
    }

    /// Every ask arm is reachable, and the combination read-only, not destructive, trusted is
    /// step 3's allow rather than another reason. Pinned so the ladder cannot be reordered into
    /// a dead branch.
    func testEveryAskReasonIsReachableAndTheyAreAllDistinct() {
        let reasons = [
            reason(evaluate(mode: .semiAutomatic, trusted: true, readOnly: false, destructive: true, pin: pin())),
            reason(evaluate(mode: .semiAutomatic, trusted: true, readOnly: false, destructive: false, pin: pin())),
            reason(evaluate(mode: .semiAutomatic, trusted: true, sent: [:])),
            reason(evaluate(mode: .semiAutomatic, trusted: true, readOnly: true, destructive: true, pin: pin())),
            reason(evaluate(mode: .semiAutomatic, trusted: false, readOnly: true, destructive: false, pin: pin())),
        ]
        XCTAssertEqual(Set(reasons).count, 5, "\(reasons)")
        XCTAssertEqual(Set(reasons), Set(MCPPermissionService.AskReason.allCases.map(MCPPermissionService.reasonForAsking)),
                       "every arm of the ladder is one of these five, and each is reached")
        XCTAssertEqual(
            evaluate(mode: .semiAutomatic, trusted: true, readOnly: true, destructive: false, pin: pin()),
            .allow)
    }

    // MARK: - The reason attributes to the server only what it stated (2026-10-28)

    /// The model is told what the SERVER said only where the server said it: a hint it left
    /// out is described as how the app treats it. Each case is what a server can send, read as
    /// the descriptor factory reads it, on a trusted server under Semi-automatic — the one mode
    /// whose ask carries a reason of the tool's own.
    ///
    /// RED until 2026-10-28: a tool with no annotations was reported as one "the server marks
    /// … as making destructive changes" — both values were the spec's defaults (F54, the
    /// model-facing half).
    func testTheReasonAttributesToTheServerOnlyWhatItStated() {
        let cases: [(sent: [String: JSONValue], reason: String)] = [
            ([:], "the server does not mark this tool read-only, so it is treated as making changes"),
            (["destructiveHint": .bool(false)],
             "the server does not mark this tool read-only, so it is treated as making changes"),
            (["openWorldHint": .bool(false)],
             "the server does not mark this tool read-only, so it is treated as making changes"),
            (["readOnlyHint": .bool(false)], "the server marks this tool as making changes"),
            (["readOnlyHint": .bool(false), "destructiveHint": .bool(false)],
             "the server marks this tool as making changes"),
            (["destructiveHint": .bool(true)], "the server marks this tool as making destructive changes"),
            (["readOnlyHint": .bool(false), "destructiveHint": .bool(true)],
             "the server marks this tool as making destructive changes"),
            (["readOnlyHint": .bool(true), "destructiveHint": .bool(true)],
             "the server marks this tool as read-only and as destructive at once, so the read-only annotation does not clear a call"),
        ]
        for (sent, expected) in cases {
            XCTAssertEqual(reason(evaluate(mode: .semiAutomatic, trusted: true, sent: sent)), expected, "\(sent)")
            XCTAssertEqual(reason(evaluate(mode: .semiAutomatic, trusted: false, sent: sent)), expected,
                           "\(sent): the tool's own reason comes before the trust mark")
        }
    }

    /// The one arm a trust mark decides: a tool stated read-only and not destructive — by the
    /// server, or by the spec's reading beside a stated read-only — asks only because the
    /// server is not marked trusted, and the reason says exactly that.
    func testAReadOnlyToolOfAnUntrustedServerAsksBecauseOfTheMarkAlone() {
        for sent: [String: JSONValue] in [["readOnlyHint": .bool(true)],
                                          ["readOnlyHint": .bool(true), "destructiveHint": .bool(false)]] {
            XCTAssertEqual(
                reason(evaluate(mode: .semiAutomatic, trusted: false, sent: sent)),
                "this server is not marked trusted, so its read-only annotation does not clear a call on its own",
                "\(sent)")
            XCTAssertEqual(evaluate(mode: .semiAutomatic, trusted: true, sent: sent), .allow, "\(sent)")
        }
    }

    /// Walks every combination a server can send for the two hints the reasons read — each
    /// absent, stated true or stated false — and holds the truth rule: a reason says "the
    /// server marks" a hint only when the server stated it.
    func testNoReasonClaimsAHintTheServerLeftOut() {
        let choices: [Bool?] = [nil, true, false]
        var walked = 0
        for readOnly in choices {
            for destructive in choices {
                var sent: [String: JSONValue] = [:]
                if let readOnly { sent["readOnlyHint"] = .bool(readOnly) }
                if let destructive { sent["destructiveHint"] = .bool(destructive) }
                for trusted in [true, false] {
                    let decision = evaluate(mode: .semiAutomatic, trusted: trusted, sent: sent)
                    guard case .ask(let text) = decision else { continue }
                    walked += 1
                    if text.contains("marks this tool as making destructive changes") {
                        XCTAssertEqual(destructive, true, "\(sent): destructive was not stated")
                    }
                    if text.contains("marks this tool as making changes") {
                        XCTAssertEqual(readOnly, false, "\(sent): writing was not stated")
                    }
                    if text.contains("read-only and as destructive at once") {
                        XCTAssertTrue(readOnly == true && destructive == true, "\(sent)")
                    }
                    if text.contains("does not mark this tool read-only") {
                        XCTAssertNil(readOnly, "\(sent): a stated read-only claim is not denied")
                        XCTAssertNotEqual(destructive, true, "\(sent): a stated destructive claim is not dropped")
                    }
                }
            }
        }
        XCTAssertEqual(walked, 16, "anti-vacuum: every ask of the walk was read (two allows)")
    }

    // MARK: - Model-facing wording

    /// Every reason here is read by the model, never by a person: the approval card shows the
    /// tool, the server and the arguments, and no reason at all.
    func testNoReasonAddressesAHumanReader() {
        var reasons: [String] = []
        for mode in MCPApprovalMode.allCases {
            for trusted in [true, false] {
                for readOnly in [true, false] {
                    for destructive in [true, false] {
                        for pin in [nil, self.pin(), self.pin(alwaysAllow: true)] as [MCPToolPin?] {
                            for live in ["h1", "h2"] {
                                reasons.append(reason(evaluate(
                                    mode: mode, trusted: trusted, readOnly: readOnly,
                                    destructive: destructive, pin: pin, liveHash: live)))
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(reasons.count, 40, "anti-vacuum: the matrix must actually be walked")
        for text in reasons {
            let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            XCTAssertFalse(words.contains("you"), text)
            XCTAssertFalse(words.contains("your"), text)
        }
    }

    // MARK: - Unattended availability & Auto policy equivalence (D-M14)

    /// `runsUnattended` is derived directly from `evaluate`: `.allow` always runs unattended,
    /// `.ask` runs unattended iff `approvalMode == .auto` (where the LLM judge answers the ask),
    /// and `.deny` never runs.
    func testRunsUnattendedFollowsEvaluateAndMode() {
        for mode in MCPApprovalMode.allCases {
            for trusted in [true, false] {
                for readOnly in [true, false] {
                    for destructive in [true, false] {
                        for currentPin in [nil, self.pin(), self.pin(alwaysAllow: true)] as [MCPToolPin?] {
                            for live in [approvedHash, "other_hash"] {
                                let ann = annotations(readOnly: readOnly, destructive: destructive)
                                let decision = MCPPermissionService.evaluate(
                                    approvalMode: mode, serverTrusted: trusted, annotations: ann,
                                    pin: currentPin, liveHash: live)
                                let unattended = MCPPermissionService.runsUnattended(
                                    approvalMode: mode, serverTrusted: trusted, annotations: ann,
                                    pin: currentPin, liveHash: live)
                                switch decision {
                                case .allow:
                                    XCTAssertTrue(unattended, "\(mode) \(trusted) \(readOnly) \(destructive)")
                                case .ask:
                                    XCTAssertEqual(unattended, mode == .auto, "\(mode) \(trusted) \(readOnly) \(destructive)")
                                case .deny:
                                    XCTAssertFalse(unattended, "\(mode) \(trusted) \(readOnly) \(destructive)")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// `evaluate(.auto, x) == evaluate(.semiAutomatic, x)` across the entire input matrix
    /// (including cross-server calls): `.auto` changes WHO answers `.ask` (the LLM judge instead
    /// of a human card), never which calls bypass `.ask` via `alwaysAllow` or `trusted + readOnly`.
    func testAutoEvaluatesIdenticallyToSemiAutomaticAcrossTheMatrix() {
        var checked = 0
        for trusted in [true, false] {
            for readOnly in [nil, true, false] as [Bool?] {
                for destructive in [nil, true, false] as [Bool?] {
                    var sent: [String: JSONValue] = [:]
                    if let readOnly { sent["readOnlyHint"] = .bool(readOnly) }
                    if let destructive { sent["destructiveHint"] = .bool(destructive) }
                    let ann = MCPToolAnnotations(raw: .object(sent))
                    for currentPin in [nil, self.pin(), self.pin(alwaysAllow: true)] as [MCPToolPin?] {
                        for live in [approvedHash, "other_hash"] {
                            for prior in [[], ["Folio Desktop"]] {
                                let semi = MCPPermissionService.evaluate(
                                    approvalMode: .semiAutomatic, serverTrusted: trusted, annotations: ann,
                                    pin: currentPin, liveHash: live, priorServerNames: prior,
                                    targetServerName: "GitHub")
                                let auto = MCPPermissionService.evaluate(
                                    approvalMode: .auto, serverTrusted: trusted, annotations: ann,
                                    pin: currentPin, liveHash: live, priorServerNames: prior,
                                    targetServerName: "GitHub")
                                XCTAssertEqual(auto, semi)
                                checked += 1
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(checked, 216)
    }

    // MARK: - Cross-server flow control (D-M4)

    /// Once a step has already used MCP server A, any call to another MCP server B under
    /// `.semiAutomatic` must ask a person — even when B's tool has `alwaysAllow` or B is
    /// trusted and the tool is `readOnlyHint: true`. Same-server calls (`priorServerNames` empty)
    /// continue to use the normal rules.
    func testCrossServerCallUnderSemiAutomaticAsksEvenWhenAlwaysAllowedOrTrustedReadOnly() {
        let alwaysGranted = MCPPermissionService.evaluate(
            approvalMode: .semiAutomatic,
            serverTrusted: true,
            annotations: annotations(readOnly: true, destructive: false),
            pin: pin(alwaysAllow: true),
            liveHash: approvedHash,
            priorServerNames: ["Folio Desktop"],
            targetServerName: "GitHub")
        XCTAssertTrue(isAsk(alwaysGranted), "\(alwaysGranted)")
        XCTAssertTrue(reason(alwaysGranted).contains("Folio Desktop"), reason(alwaysGranted))
        XCTAssertTrue(reason(alwaysGranted).contains("GitHub"), reason(alwaysGranted))

        let trustedReadOnly = MCPPermissionService.evaluate(
            approvalMode: .semiAutomatic,
            serverTrusted: true,
            annotations: annotations(readOnly: true, destructive: false),
            pin: pin(alwaysAllow: false),
            liveHash: approvedHash,
            priorServerNames: ["Folio Desktop"],
            targetServerName: "GitHub")
        XCTAssertTrue(isAsk(trustedReadOnly), "\(trustedReadOnly)")
        XCTAssertEqual(reason(trustedReadOnly), reason(alwaysGranted))
    }
}
