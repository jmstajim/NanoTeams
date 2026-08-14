import XCTest

@testable import NanoTeams

/// Structural invariants for `PromptPrefixLedger`, both of the "the wrong shape is not
/// reachable" kind that no behavioural test can observe once the shape is gone:
///
/// 1. **No process-global ledger.** The seam on `LLMExecutionService` must resolve INWARD
///    (CLAUDE.md Swift Style #49). A `= .shared` default is evaluated at the CALL SITE, and this
///    service is constructed bare in ~100 test files — so one `static let shared` silently
///    handed every suite the same actor. Three pieces of order-dependent state crossed with it:
///    the activity list that names suspects, the never-reset `prefillFloorNsPerToken` minimum,
///    and the per-owner chains (keyed `base|model|step:taskID:stepID`, and test task ids and role
///    ids collide by construction).
/// 2. **Ordering is a sequence, never a clock.** `suspect` compares one record's position
///    against another's for pure ORDERING, and `pruneOwnersIfNeeded` sorts by it. A `Date` ties
///    when two records land in the same instant — which back-to-back `await`s on one actor
///    routinely do — and a `MonotonicClock` stamp fails differently but just as hard: a default
///    argument is evaluated before the hop onto the actor, so the stamps can order the opposite
///    way from the arrivals (CLAUDE.md Грабли 2026-07-18).
///
/// Follows the house source-pin shape (`OrchestratorTestConstructionPinTests`): line comments are
/// stripped before matching, and every needle is assembled at RUNTIME so this file's own doc
/// comment can never satisfy its own scan.
final class PrefixCacheLedgerOwnershipPinTests: XCTestCase {

    // MARK: - Scaffolding

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LLM
            .deletingLastPathComponent()  // Services
            .deletingLastPathComponent()  // NanoTeamsTests
            .deletingLastPathComponent()  // repo root
    }

    /// Everything before an unquoted `//`. Verbatim from `OrchestratorTestConstructionPinTests` —
    /// without it this pin flags its own prose.
    private static func strippingLineComments(_ line: String) -> String {
        var out = ""
        var inString = false
        var previous: Character?
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"", previous != "\\" { inString.toggle() }
            if !inString, character == "/", previous == "/" {
                return String(out.dropLast())
            }
            out.append(character)
            previous = character
            index = line.index(after: index)
        }
        return out
    }

    private func codeLines(of relativePath: String) throws -> [(line: Int, text: String)] {
        let url = repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .enumerated()
            .map { (line: $0.offset + 1, text: Self.strippingLineComments($0.element)) }
    }

    private static var singletonNeedle: String { "static let " + "shared" }
    private static var sharedRefNeedle: String { "PromptPrefixLedger" + ".shared" }
    private static var dateNeedle: String { "Date" + "()" }
    private static var freshDropNeedle: String { "forgetPrefixChain" + "ForFreshConversation(" }
    private static var preflightNeedle: String { "preflight" + "Check(" }
    private static var collapseNeedle: String { "collapseRedundant" + "AssistantTextRuns" }

    private let ledgerPath = "NanoTeams/Services/LLM/PromptPrefixLedger.swift"
    private let servicePath = "NanoTeams/Services/LLM/LLMExecutionService.swift"
    private let lifecyclePath = "NanoTeams/Services/LLM/LLMExecutionService+StepLifecycle.swift"
    private let repairPath = "NanoTeams/Services/LLM/ConversationRepairService.swift"

    // MARK: - 1. No process-global ledger

    func testLedgerExposesNoProcessGlobalSingleton() throws {
        let offenders = try codeLines(of: ledgerPath)
            .filter { $0.text.contains(Self.singletonNeedle) }
        XCTAssertTrue(
            offenders.isEmpty,
            "PromptPrefixLedger must not expose a process-global instance — "
                + "the ~100 test sites that build LLMExecutionService bare would all share it. "
                + "Inject via `prefixLedger:` instead. Offending lines: "
                + offenders.map(\.line.description).joined(separator: ", "))
    }

    func testNoProductionSiteReferencesAGlobalLedger() throws {
        let sourceRoot = repoRoot.appendingPathComponent("NanoTeams")
        var offenders: [String] = []
        var filesScanned = 0

        let enumerator = FileManager.default.enumerator(
            at: sourceRoot, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            filesScanned += 1
            let relativePath = "NanoTeams/"
                + url.path.replacingOccurrences(of: sourceRoot.path + "/", with: "")
            for (line, text) in try String(contentsOf: url, encoding: .utf8)
                .components(separatedBy: "\n")
                .enumerated()
                .map({ ($0.offset + 1, Self.strippingLineComments($0.element)) })
            where text.contains(Self.sharedRefNeedle)
                || (text.contains(": PromptPrefixLedger") && text.contains("= .shared")) {
                offenders.append("\(relativePath):\(line)")
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "no production site may reach for a global ledger: \(offenders.joined(separator: ", "))")
        XCTAssertGreaterThan(
            filesScanned, 400,
            "the repo-root walk broke — a pin that scans nothing passes green")
    }

    func testTheInitSeamResolvesInward() throws {
        let source = try codeLines(of: servicePath).map(\.text).joined(separator: "\n")
        XCTAssertTrue(
            source.contains("prefixLedger: PromptPrefixLedger? = nil"),
            "the seam must default to nil, not to an expression evaluated at the call site")
        XCTAssertTrue(
            source.contains("prefixLedger ?? PromptPrefixLedger()"),
            "nil must resolve INWARD to this service's own ledger")
    }

    // MARK: - 2. Ordering is a sequence, never a clock

    func testLedgerOrdersWithASequenceNotAClock() throws {
        let lines = try codeLines(of: ledgerPath)
        let clockUses = lines.filter {
            $0.text.contains(Self.dateNeedle) || $0.text.contains("MonotonicClock")
        }
        XCTAssertTrue(
            clockUses.isEmpty,
            "`suspect` and the LRU compare records for ORDERING only. A clock ties when two "
                + "records land in the same instant, and a caller-supplied stamp is taken before "
                + "the hop onto this actor — so it can order the opposite way from the arrivals. "
                + "Use the actor-assigned `sequence`. Offending lines: "
                + clockUses.map(\.line.description).joined(separator: ", "))

        let source = lines.map(\.text).joined(separator: "\n")
        XCTAssertTrue(
            source.contains("private var sequence: UInt64"),
            "the ordering token must be an actor-owned counter")
    }

    // MARK: - 3. The fresh-conversation drop is actually wired

    /// The owner key `step:<taskID>:<roleID>` outlives the conversation it describes — a new
    /// `Run` and `restartRole` both rebuild that conversation from scratch — so request #1 of a
    /// fresh conversation is compared against the PREVIOUS run's chain unless the ledger is
    /// told. `startStepExecution` is the one place that knows (it already computes
    /// `ConversationReplay.resume(from:) == nil`), and it is a SINGLE line.
    ///
    /// Behavioural tests cannot pin it: `PrefixCacheWiringTests` drives
    /// `forgetPrefixChainForFreshConversation` directly, so deleting the call site would leave
    /// every one of them green while silently re-arming the defect. Hence a source scan.
    func testStepLifecycleDropsTheChainOnAFreshConversation() throws {
        let source = try codeLines(of: lifecyclePath).map(\.text).joined(separator: "\n")
        XCTAssertTrue(
            source.contains(Self.freshDropNeedle),
            "`startStepExecution` must drop this step's prefix chain when the conversation is "
                + "built from scratch. Without the call, run N+1's short opening is a strict "
                + "PREFIX of run N's chain, so `compare` answers `.reused` and the server "
                + "signals get consulted for a conversation with nothing to lose — the "
                + "Autovisor hits that every minute.")
    }

    /// The drop must run BEFORE config resolution. `preflightCheck` can replace the effective
    /// config with the global one, and a role's `llmOverride` can be edited between runs, so a
    /// `(server, model)`-keyed drop placed after resolution would clear one slot and leave the
    /// stale chain live under the other. Ordering is the reason `forgetOwner` is owner-scoped.
    func testTheChainIsDroppedBeforeTheConfigIsResolved() throws {
        let lines = try codeLines(of: lifecyclePath)
        guard let drop = lines.first(where: { $0.text.contains(Self.freshDropNeedle) })
        else { return XCTFail("the fresh-conversation drop is gone — see the test above") }
        guard let preflight = lines.first(where: { $0.text.contains(Self.preflightNeedle) })
        else { return XCTFail("`preflightCheck` moved — this ordering pin is now vacuous") }

        XCTAssertLessThan(
            drop.line, preflight.line,
            "the drop must not sit behind config resolution (or behind its 5s network round "
                + "trip), where the key it would target is no longer the key that gets recorded")
    }

    // MARK: - 4. The retry path never rewrites the conversation

    /// `collapseRedundantAssistantTextRuns` rebuilt the whole array on every retryable LLM error,
    /// so its divergence index was unbounded — a full re-prefill paid on top of an already-failed
    /// request, with no exemption to keep the detector honest. It was deleted; this stops it (or
    /// any equivalent) from returning to that arm.
    ///
    /// A source scan is the only option: with the function gone there is no behaviour left to
    /// assert, and re-adding it would leave every existing test green.
    func testTheRetryPathDoesNotCollapseTheConversation() throws {
        let offenders = try codeLines(of: lifecyclePath)
            .filter { $0.text.contains(Self.collapseNeedle) }
        XCTAssertTrue(
            offenders.isEmpty,
            "the retryable-error arm must not fold the conversation — the rewrite index is "
                + "unbounded and the retry then pays a cold prefill: "
                + offenders.map { "\(self.lifecyclePath):\($0.line)" }.joined(separator: ", "))
    }

    /// The same rule at the definition site, so the function cannot quietly come back and be
    /// wired in from somewhere new.
    func testTheCollapseHelperIsGone() throws {
        let repair = try codeLines(of: repairPath).map(\.text).joined(separator: "\n")
        XCTAssertFalse(
            repair.contains("func " + Self.collapseNeedle),
            "re-adding this helper re-arms an unbounded-index conversation rewrite")
    }

    // MARK: - 5. keep-alive stays a single-provider setting, or it must become per-provider

    /// `ollamaKeepAliveSeconds` is ONE app-wide value written onto every `LLMConfig` regardless of
    /// provider, and the provider flip restores the remembered endpoint but not this. That is safe
    /// only while exactly one provider consumes it: today `OllamaClient` sends it on the wire, and
    /// the cache detector's exemption is gated on `managesModelResidency`, so a value set for one
    /// server cannot mean anything on the other.
    ///
    /// The moment a second consumer appears — LM Studio's `/api/v1/models/load` does accept
    /// `ttl_seconds`, deliberately unused today — the shared value becomes wrong, and the setting
    /// has to gain per-provider storage like the endpoint memory. A tripwire rather than a
    /// dictionary: adding per-provider structure now would be structure with no reader.
    func testKeepAliveHasExactlyOneWireConsumer() throws {
        let needle = "keepAlive" + "Seconds"
        var wireConsumers: [String] = []

        let sources = repoRoot.appendingPathComponent("NanoTeams/Services/LLM")
        let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let name = url.lastPathComponent
            // The type that declares it and the detector exemption are not wire consumers.
            guard name != "LLMTypes.swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
                .components(separatedBy: "\n")
                .map { Self.strippingLineComments($0) }
                .joined(separator: "\n")
            guard text.contains(needle) else { continue }
            // A client SENDS it; anything else merely copies it between configs.
            if text.contains("keepAlive:") { wireConsumers.append(name) }
        }

        XCTAssertEqual(
            wireConsumers, ["OllamaClient.swift"],
            "a second provider now puts keep-alive on the wire, so one shared app-wide value is "
                + "no longer correct — give the setting per-provider storage (mirror "
                + "`llmProviderEndpoints`) before shipping this: \(wireConsumers)")
    }

    // MARK: - Anti-vacuity

    /// A broken `#filePath` walk would make every scan above pass over nothing.
    func testThePinIsNotVacuous() throws {
        let repair = try codeLines(of: repairPath).map(\.text).joined(separator: "\n")
        XCTAssertTrue(
            repair.contains("enum ConversationRepairService"),
            "ConversationRepairService.swift not found or renamed — the collapse scans above "
                + "are vacuous")

        let ledger = try codeLines(of: ledgerPath).map(\.text).joined(separator: "\n")
        XCTAssertTrue(
            ledger.contains("actor PromptPrefixLedger"),
            "PromptPrefixLedger.swift not found or renamed — the scans above are vacuous")

        let service = try codeLines(of: servicePath).map(\.text).joined(separator: "\n")
        XCTAssertTrue(
            service.contains("prefixLedger"),
            "the seam moved out of LLMExecutionService.swift — testTheInitSeamResolvesInward "
                + "would silently stop checking anything")

        let lifecycle = try codeLines(of: lifecyclePath).map(\.text).joined(separator: "\n")
        XCTAssertTrue(
            lifecycle.contains("func startStepExecution"),
            "startStepExecution moved out of +StepLifecycle.swift — the two scans above would "
                + "silently stop checking anything")
    }
}
