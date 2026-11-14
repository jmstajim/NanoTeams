import Foundation

/// Pure, stateless rule engine deciding what happens to one MCP tool call before anyone is
/// asked. No I/O, no clock, no isolation — the same shape as `BashPermissionService`, and for
/// the same reason: a security decision that cannot be unit-tested exhaustively is a security
/// decision nobody has checked.
///
/// Precedence is **deny > ask > allow**, and the order of the steps is the policy:
///
///  0. **No pin, or a pin that no longer matches** — deny. This is above everything, mode
///     included: a tool whose text changed since a person read it has not been approved, and
///     under `.semiAutomatic` a rug-pulled tool would otherwise ride its own stale
///     `alwaysAllow` straight through.
///  1. **Manual** — ask. Above the read-only bypass on purpose, exactly as `bash`'s Manual is:
///     the user asked to see every call, so no annotation and no prior grant skips them.
///  2. **Always-allow** — allow. Granted by a person, for this tool at this hash; step 0 has
///     already established the hash still holds.
///  3. **Trusted server + `readOnlyHint`, not destructive** — allow. The ONE place a server's
///     own claim about itself lowers friction, and it takes a switch the user threw by hand.
///     The hints are read as the spec reads them (`MCPToolAnnotations`): a tool stated
///     read-only that says nothing about destruction is not destructive — the spec's `true`
///     default is for a tool that writes — so a trusted server that marks its read tools the
///     usual way has them run. One that STATES both contradicts itself and asks.
///  4. Otherwise ask.
///
/// Every ASK reason is read by the MODEL, not by a person: the approval card shows the tool,
/// the server, the arguments and the annotation chips, never a reason. The one consumer is the
/// gate's no-human arm, which composes "This call needs a person's approval (<reason>), and this
/// run has none." — so each reason is registered text (`RuntimePromptRegistry`,
/// `manualModeReason` and every arm of `reasonForAsking`). Third person throughout — written in
/// the second person it produced "…needs YOUR approval…, but no human is available", a
/// sentence that contradicts itself for its one reader. The two DENY reasons reach nobody: the
/// gate answers a deny with the executor's own `mcp_tool_changed` refusal.
nonisolated enum MCPPermissionService {

    /// - Parameters:
    ///   - pin: what the user approved, or `nil` if nobody has.
    ///   - liveHash: the hash of the tool as the server publishes it right now.
    ///   - priorServerNames: display names of other MCP servers already contacted in the same step.
    ///   - targetServerName: display name of the server this call targets.
    static func evaluate(
        approvalMode: MCPApprovalMode,
        serverTrusted: Bool,
        annotations: MCPToolAnnotations,
        pin: MCPToolPin?,
        liveHash: String,
        priorServerNames: [String] = [],
        targetServerName: String = ""
    ) -> MCPPermissionDecision {
        // 0. Pinning is the floor. A tool nobody reviewed never reaches a prompt in the first
        //    place, so a call landing here means the catalogue moved under a running step —
        //    which is exactly the case this arm exists for.
        guard let pin else {
            return .deny(reason: "This tool has not been reviewed and approved for use. "
                + "Drop the call and report the gap in the answer.")
        }
        guard pin.hash == liveHash else {
            return .deny(reason: "The server changed this tool's description or schema after it was approved. "
                + "Drop the call and report the gap in the answer.")
        }

        // 1. Manual: every call is reviewed individually — a prior grant and a read-only
        //    annotation are both skipped, which is what the mode means.
        if approvalMode == .manual {
            return .ask(reason: manualModeReason)
        }

        // 1b. Cross-server flow control: once a step has already used another MCP server, calling
        //     a second server under Semi-automatic or Auto requires review before arguments
        //     can cross between servers — even if this server's tool has a standing grant or is a
        //     trusted read-only tool.
        if !priorServerNames.isEmpty {
            return .ask(reason: crossServerTransferReason(from: priorServerNames, to: targetServerName))
        }

        // 2. A grant a person gave for this tool at this hash — under a mode that allows a
        //    standing grant, the one rule the card's button, the page's switch and the write read
        //    too (`MCPApprovalMode.allowsStandingGrants`). Step 1 has already asked under Manual;
        //    reading the rule here too keeps a grant from counting under any mode that has not
        //    said it allows one.
        if approvalMode.allowsStandingGrants, pin.alwaysAllow {
            return .allow
        }

        // 3. The single annotation-driven bypass, and only on a server marked trusted. An
        //    untrusted server's `readOnlyHint` is a claim it makes about itself.
        //
        //    `destructiveHint` has to be clear as well, and not as a belt-and-braces flourish:
        //    a tool claiming BOTH is contradicting itself, and the rule that annotations may
        //    only raise friction says the harsher claim is the one that counts. Reading the
        //    pair as "read-only wins" would hand a server a two-field way to lower friction on
        //    a tool it has already told us is destructive.
        //
        //    `destructiveHint` is read as `MCPToolAnnotations` reads it, and nowhere else:
        //    beside a stated `readOnlyHint: true` an unstated one reads `false` — the spec
        //    reads the hint only for a tool that writes. Until 2026-09-24 the spec's `true`
        //    default counted here, and a trusted server's read tools never cleared a call.
        if serverTrusted, annotations.readOnlyHint, !annotations.destructiveHint {
            return .allow
        }

        return .ask(reason: reasonForAsking(askReason(annotations)))
    }

    /// Whether a call of this tool can proceed when no human is present to approve a card
    /// (`MCPToolsSnapshot.Entry.runsUnattended`, `MCPGrantCatalogue.Tool.runsUnattended`).
    /// Derived from `evaluate` so there is no second copy of the policy: `.allow` always runs,
    /// `.ask` runs only when `approvalMode == .auto` (where `MCPJudgeService` answers the ask),
    /// and `.deny` never runs.
    static func runsUnattended(
        approvalMode: MCPApprovalMode,
        serverTrusted: Bool,
        annotations: MCPToolAnnotations,
        pin: MCPToolPin?,
        liveHash: String
    ) -> Bool {
        switch evaluate(
            approvalMode: approvalMode,
            serverTrusted: serverTrusted,
            annotations: annotations,
            pin: pin,
            liveHash: liveHash
        ) {
        case .allow: return true
        case .ask: return approvalMode == .auto
        case .deny: return false
        }
    }

    /// Step 1's reason: the server's mode, which says why whatever the tool is.
    /// runtime-prompt
    static let manualModeReason = "manual approval mode — every call to this server is reviewed individually"

    /// Cross-server transfer reason when a step has already contacted another MCP server.
    /// runtime-prompt
    static func crossServerTransferReason(from priorServers: [String], to targetServer: String) -> String {
        let joined = priorServers.joined(separator: ", ")
        let destination = targetServer.isEmpty ? "another MCP server" : targetServer
        return "this step has already used MCP server \(joined), so calling \(destination) requires a person's approval to prevent cross-server data transfer"
    }

    /// The arms of `reasonForAsking` — one per case step 3 can leave to ask, each reachable
    /// (`MCPPermissionServiceTests.testEveryAskReasonIsReachableAndTheyAreAllDistinct`).
    enum AskReason: CaseIterable, Sendable {
        /// The server STATED `destructiveHint: true` on a tool that is not stated read-only.
        case destructiveStated
        /// The server STATED `readOnlyHint: false`, and did not state it destructive.
        case writesStated
        /// The server did not state read-only, nor destructive: the tool is treated as making
        /// changes — the spec's default — and nothing is put in the server's mouth.
        case writesAssumed
        /// The server STATED read-only and STATED destructive.
        case contradiction
        /// Read-only and not destructive — the server's word, or the spec's reading beside a
        /// stated read-only — on a server nobody marked trusted.
        case untrusted
    }

    /// Names the NEAREST miss, so the model's report of a refused call says something true
    /// about why rather than repeating the mode — and attributes to the server only what the
    /// server STATED (`MCPToolAnnotations.statedHints`). A hint it left out is described as how
    /// this app treats it. Until 2026-10-28 a tool with no annotations at all was reported as
    /// one "the server marks … as making destructive changes": both values were the spec's
    /// defaults, the model-facing half of F54.
    /// runtime-prompt
    static func reasonForAsking(_ reason: AskReason) -> String {
        switch reason {
        case .destructiveStated: "the server marks this tool as making destructive changes"
        case .writesStated: "the server marks this tool as making changes"
        case .writesAssumed: "the server does not mark this tool read-only, so it is treated as making changes"
        case .contradiction:
            "the server marks this tool as read-only and as destructive at once, so the read-only annotation does not clear a call"
        case .untrusted: "this server is not marked trusted, so its read-only annotation does not clear a call on its own"
        }
    }

    /// Which arm a call step 3 did not clear falls under, in the order step 3 rules them out.
    ///
    /// A tool that reads read-only was STATED so (the default is `false`); beside it a
    /// destructive reading can only be stated too (`specDefault(of:given:)`), which is the
    /// contradiction — otherwise the trust mark is the miss. A tool that reads as writing is
    /// described by what the server said: destructive when it stated that, making changes when
    /// it stated it writes, and otherwise by the default alone. Destructiveness does not decide
    /// the ask for a writing tool — any writing tool asks — so an unstated one is not named:
    /// "may be destructive" would add a word the model can do nothing with.
    /// Only reached past step 3, so a tool left read-only and not destructive is one whose
    /// server is not marked trusted.
    static func askReason(_ annotations: MCPToolAnnotations) -> AskReason {
        let stated = annotations.statedHints
        guard annotations.readOnlyHint else {
            if stated.contains(.destructive), annotations.destructiveHint { return .destructiveStated }
            return stated.contains(.readOnly) ? .writesStated : .writesAssumed
        }
        if annotations.destructiveHint { return .contradiction }
        return .untrusted
    }
}
