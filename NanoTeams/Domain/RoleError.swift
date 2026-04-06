import Foundation

// MARK: - Role Error

/// Represents an error that occurred during role execution
struct RoleError: Codable, Identifiable, Hashable {
    var id: UUID
    var createdAt: Date
    var role: Role
    var errorMessage: String
    var errorType: RoleErrorType
    var strategy: RoleErrorStrategy
    var retryCount: Int
    var maxRetries: Int

    init(
        id: UUID = UUID(),
        createdAt: Date = MonotonicClock.shared.now(),
        role: Role,
        errorMessage: String,
        errorType: RoleErrorType = .unknown,
        strategy: RoleErrorStrategy = .askSupervisor,
        retryCount: Int = 0,
        maxRetries: Int = 3
    ) {
        self.id = id
        self.createdAt = createdAt
        self.role = role
        self.errorMessage = errorMessage
        self.errorType = errorType
        self.strategy = strategy
        self.retryCount = retryCount
        self.maxRetries = maxRetries
    }

    /// Whether more retries are available
    var canRetry: Bool {
        retryCount < maxRetries
    }
}

// MARK: - Role Error Type

enum RoleErrorType: String, Codable, Hashable {
    /// Transient error (network, timeout)
    case transient

    /// LLM error (bad response, parsing failure)
    case llmError

    /// Tool execution error
    case toolError

    /// Build failure
    case buildFailure

    /// Missing dependency (required artifact not available)
    case missingDependency

    /// Unknown error
    case unknown

    var isTransient: Bool {
        self == .transient
    }

    private static let strategyMap: [RoleErrorType: RoleErrorStrategy] = [
        .transient: .retry,
        .llmError: .retry,
        .toolError: .askSupervisor,
        .buildFailure: .askSupervisor,
        .missingDependency: .skip,
        .unknown: .askSupervisor,
    ]

    var suggestedStrategy: RoleErrorStrategy {
        Self.strategyMap[self] ?? .askSupervisor
    }
}

// MARK: - Role Error Strategy

enum RoleErrorStrategy: String, Codable, Hashable, CaseIterable {
    /// Automatic retry with exponential backoff
    case retry

    /// Ask Supervisor what to do
    case askSupervisor

    /// Skip this role and continue
    case skip

    /// Fail the entire task
    case failTask

    private static let metadata: [RoleErrorStrategy: (name: String, desc: String, icon: String)] = [
        .retry:         ("Retry",           "Automatically retry the operation",        "arrow.clockwise"),
        .askSupervisor: ("Ask Supervisor",  "Ask the Supervisor for guidance",          "person.fill.questionmark"),
        .skip:          ("Skip Role",       "Skip this role and continue with others",  "forward.fill"),
        .failTask:      ("Fail Task",       "Mark the entire task as failed",           "xmark.octagon"),
    ]

    var displayName: String { Self.metadata[self]?.name ?? rawValue }
    var description: String { Self.metadata[self]?.desc ?? rawValue }
    var icon: String { Self.metadata[self]?.icon ?? "questionmark" }
}

// MARK: - Error History

/// Tracks error history for a task/run for analytics
struct ErrorHistory: Codable {
    var errors: [RoleError] = []
    var totalRetries: Int = 0
    var totalSkipped: Int = 0
    var totalFailed: Int = 0

    mutating func record(_ error: RoleError, outcome: ErrorOutcome) {
        errors.append(error)

        switch outcome {
        case .retried:
            totalRetries += 1
        case .skipped:
            totalSkipped += 1
        case .failed:
            totalFailed += 1
        case .resolved:
            break
        }
    }

    enum ErrorOutcome: String, Codable {
        case retried
        case skipped
        case failed
        case resolved
    }

    var summary: String {
        "Errors: \(errors.count), Retries: \(totalRetries), Skipped: \(totalSkipped), Failed: \(totalFailed)"
    }
}
