import Foundation

/// What a connection's catalogue says about its tools — derived from `descriptors` and
/// `trustRecord`, which the connection keeps in step (`adoptTrustRecord()`). Reads only: every
/// write stays in `MCPServerConnection.swift` beside the lifecycle that orders it.
extension MCPServerConnection {

    /// Where one descriptor stands, from ITS OWN hash — never from another entry that happens
    /// to share its name.
    func pinState(of descriptor: MCPToolDescriptor) -> MCPPinState {
        MCPPinState(liveHash: descriptor.pinHash, pin: trustRecord.toolPins[descriptor.originalName])
    }

    func pinState(of prompt: MCPPromptDescriptor) -> MCPPinState {
        MCPPinState(liveHash: prompt.pinHash, pin: trustRecord.toolPins[prompt.pinKey])
    }

    func pinState(of tool: String) -> MCPPinState? { pinStates[tool] }

    /// The approval on record for a tool, whatever text it covers — what the review sheet
    /// compares a rewrite against.
    func pin(of tool: String) -> MCPToolPin? { trustRecord.toolPins[tool] }

    /// Whether the person refused exactly this text — the trust record's one reading of a
    /// refusal (`MCPServerTrustRecord.isRejected`), which the grant catalogue asks too.
    func isRejected(_ descriptor: MCPToolDescriptor) -> Bool {
        trustRecord.isRejected(descriptor)
    }

    /// Read from observed state, so the Settings chip redraws when a grant lands.
    func isAlwaysAllowed(tool: String) -> Bool {
        trustRecord.toolPins[tool]?.alwaysAllow ?? false
    }

    /// Only approved tools at a matching hash — the set that may reach a prompt.
    var approvedDescriptors: [MCPToolDescriptor] {
        descriptors.filter { pinState(of: $0).isApproved }
    }

    /// Only approved prompts at a matching hash — the set that may reach the `/` skills picker.
    var approvedPrompts: [MCPPromptDescriptor] {
        promptDescriptors.filter { pinState(of: $0).isApproved }
    }

    /// The approved tools and prompts by their pin keys, each at the hash approved — what the
    /// registry checks a call's or prompt fetch's `expectedHash` against.
    var approvedHashes: [String: String] {
        var hashes = Dictionary(
            approvedDescriptors.map { ($0.originalName, $0.pinHash) },
            uniquingKeysWith: { first, _ in first })
        for prompt in approvedPrompts where hashes[prompt.pinKey] == nil {
            hashes[prompt.pinKey] = prompt.pinHash
        }
        return hashes
    }

    /// Every published tool counted against the approvals on record — the Settings row's line
    /// and the server page's badge (`MCPServerRow.tools`), and the one count of this server's
    /// tools there is: the status carried the approved count until F47, this extension an
    /// approved and an unreviewed count beside it, and the pin diff and the grant catalogue an
    /// unreviewed count each until 2026-10-28 — which nothing but tests read, and which counted a
    /// refused text as waiting. The grant catalogue counts its copy of these same tools by this
    /// same rule (`MCPGrantCatalogue.Server.toolTally`) rather than a count of its own. Derived
    /// from the same two observed values as every row here, so a decision redraws the counts
    /// with the rows.
    var toolTally: MCPToolTally {
        MCPToolTally(descriptors.map { (state: pinState(of: $0), isRejected: isRejected($0)) })
    }

    /// It published tools and roles can be offered none of them: its listing collided
    /// (`catalogueError`, which empties `descriptors`), or the app's descriptor factory refused
    /// every entry it sent (`rejections`, no descriptor). The APP's refusal of what it could not
    /// read, not the person's refusal of a text they reviewed (`isRejected`) — and not a server
    /// that publishes nothing, which is what the page, the list and the picker said of it until
    /// 2026-10-28, under the red message or above the list of what was not offered. The one
    /// predicate: the manager copies it onto the Settings row and the grant catalogue's server.
    var nothingItPublishesCanBeOffered: Bool {
        descriptors.isEmpty && (catalogueError != nil || !rejections.isEmpty)
    }

    /// What a bulk approval may take: tools nobody has approved or refused. Never a rewrite —
    /// an approved tool the server changed is exactly what one click must not re-arm, so it
    /// always goes through its own review.
    var newTools: [MCPToolDescriptor] {
        descriptors.filter { pinState(of: $0) == .new && !isRejected($0) }
    }
}
