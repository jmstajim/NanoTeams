import Foundation

/// The whole of one external Autovisor call: what the agent sent and what it got back.
///
/// The summary line in `external_activity.jsonl` keeps neither (Ш14): it is the index the pane
/// draws, and it stays a summary. This is the part the summary leaves out, kept BESIDE the log,
/// one file per call, so that a row of the External Autovisor pane opens the call in full
/// (Alex, 2026-11-08: «сделай, чтобы можно было ответы смотреть полные»). Nothing is cut.
nonisolated struct ExternalAutovisorFullCall: Codable, Hashable, Sendable {
    /// The `ExternalAutovisorActivityRecord.id` of the row this call belongs to.
    var id: UUID
    /// The arguments as the server decoded them, re-encoded as JSON (keys sorted, slashes
    /// unescaped) — the call as NanoTeams read it, not the bytes on the wire.
    var arguments: String
    /// `ToolExecutionResult.outputJSON`: exactly the text the agent received
    /// (`HostedMCPDispatcher.buildToolCallResultJSON` sends it as `content[0].text`).
    var response: String

    init(id: UUID, arguments: String, response: String) {
        self.id = id
        self.arguments = arguments
        self.response = response
    }

    private enum CodingKeys: String, CodingKey {
        case id, arguments, response
    }

    /// Every field but `id` decodes leniently, so a file written by a later version that adds a
    /// field — or one missing a body — still opens rather than reading as "no call".
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        arguments = try container.decodeIfPresent(String.self, forKey: .arguments) ?? ""
        response = try container.decodeIfPresent(String.self, forKey: .response) ?? ""
    }
}

/// File I/O for `ExternalAutovisorFullCall`: `.nanoteams/internal/autovisor/external_calls/<id>.json`.
///
/// Only `ExternalAutovisorActivityLog` calls it, and only from its serial `ioQueue`, so a write,
/// a later read of the same call and its removal are ordered by that queue. The directory is
/// owner-only (`NTMSRepository.internalDirAttributes`) and inherits `internal/`'s exclusion from
/// git, backup and Spotlight.
///
/// **What is scrubbed: the NanoTeams agent token, and nothing else** (`MCPRedaction.agentTokens`).
/// The rest of a body — a brief, an answer, an artifact's text — is already on disk verbatim in
/// the task it belongs to, and the generic credential heuristics of `MCPRedaction.text` would
/// turn prose such as "basic implementation" into "basic <redacted>" in a view whose whole point
/// is the full text.
nonisolated enum ExternalAutovisorFullCallStore {

    static let directoryName = "external_calls"
    private static let fileExtension = "json"

    static func fileURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).\(fileExtension)", isDirectory: false)
    }

    /// Writes one call atomically, scrubbed of agent tokens. `false` when the directory could not
    /// be created or the file could not be written — the log then holds an id whose read comes
    /// back `nil`, which the window reports in words.
    @discardableResult
    static func write(
        _ call: ExternalAutovisorFullCall,
        in directory: URL,
        fileManager: FileManager
    ) -> Bool {
        let scrubbed = ExternalAutovisorFullCall(
            id: call.id,
            arguments: MCPRedaction.agentTokens(call.arguments),
            response: MCPRedaction.agentTokens(call.response)
        )
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: NTMSRepository.internalDirAttributes
            )
            try? fileManager.setAttributes(NTMSRepository.internalDirAttributes, ofItemAtPath: directory.path)
            let data = try JSONCoderFactory.makeCompactPersistenceEncoder().encode(scrubbed)
            try data.write(to: fileURL(for: call.id, in: directory), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// The call filed under `id`, or `nil` when there is no such file, it does not decode, or it
    /// names a different call.
    static func read(id: UUID, in directory: URL) -> ExternalAutovisorFullCall? {
        guard let data = try? Data(contentsOf: fileURL(for: id, in: directory)),
              let call = try? JSONDecoder().decode(ExternalAutovisorFullCall.self, from: data),
              call.id == id
        else { return nil }
        return call
    }

    /// The ids that have a file. Anything else in the directory — a stray file, a name that is
    /// not a UUID, an atomic write's temporary — is not a call and is ignored.
    static func storedIDs(in directory: URL, fileManager: FileManager) -> Set<UUID> {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        var ids: Set<UUID> = []
        for name in names {
            let url = URL(fileURLWithPath: name)
            guard url.pathExtension == fileExtension,
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent)
            else { continue }
            ids.insert(id)
        }
        return ids
    }

    static func remove(ids: Set<UUID>, in directory: URL, fileManager: FileManager) {
        for id in ids {
            try? fileManager.removeItem(at: fileURL(for: id, in: directory))
        }
    }
}
