import Foundation

/// Build diagnostics caps (issue message/excerpt/total/log lengths).
enum BuildConstants {
    /// Maximum characters per issue message (longer messages truncated).
    static let maxIssueMessageLength = 500

    /// Maximum characters per issue excerpt/code line.
    static let maxIssueExcerptLength = 300

    /// Maximum total issues stored to disk (caps unbounded growth).
    static let maxTotalIssuesStored = 50

    /// Maximum characters for xcodebuild log in tool result (rest truncated).
    static let maxBuildLogChars = 5000
}
