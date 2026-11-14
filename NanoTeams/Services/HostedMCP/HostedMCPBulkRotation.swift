import Foundation

/// The outcome of reissuing every agent's token: what was issued, and who was left out.
///
/// A rotation is per agent and atomic (`HostedMCPAgentStore.rotateToken` changes nothing when
/// it throws), so a failure is no reason to stop: the loop goes on to the next agent and
/// reports the failure beside the tokens. Until 2026-11-08 it threw at the first failure, after
/// the agents before it were rotated — their old tokens dead, their new ones dropped with the
/// error, and no way to show them again.
nonisolated struct HostedMCPBulkRotation: Sendable, Equatable {
    nonisolated struct Failure: Sendable, Equatable {
        let agentID: UUID
        let label: String
        /// The store's own English sentence (`HostedMCPAgentStoreError.message`). Never a
        /// foreign error's `localizedDescription`: that text is in the system language and may
        /// carry a path (`Ratchet/ErrorResponsePinTests`), so anything the store did not author
        /// is reported as `unrecognizedFailure`.
        let message: String
    }

    var issued: [HostedMCPTokenHandoff]
    var failures: [Failure]

    /// What a failure the store did not author says. `rotateToken` throws only
    /// `HostedMCPAgentStoreError` today; this is the answer if that ever stops being true.
    static let unrecognizedFailure = "an unexpected error"

    static func rotate(
        _ records: [HostedMCPAgentRecord], with rotate: (UUID) throws -> HostedMCPTokenHandoff
    ) -> HostedMCPBulkRotation {
        var result = HostedMCPBulkRotation(issued: [], failures: [])
        for record in records {
            do {
                result.issued.append(try rotate(record.id))
            } catch {
                result.failures.append(Failure(
                    agentID: record.id, label: record.label,
                    message: (error as? HostedMCPAgentStoreError)?.message ?? unrecognizedFailure))
            }
        }
        return result
    }
}
