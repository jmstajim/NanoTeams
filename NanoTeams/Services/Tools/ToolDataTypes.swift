import Foundation

// MARK: - Error Codes (from JSON Schema)

enum ToolErrorCode: String, Codable {
    case invalidArgs = "INVALID_ARGS"
    case fileNotFound = "FILE_NOT_FOUND"
    case notAFile = "NOT_A_FILE"
    case notADirectory = "NOT_A_DIRECTORY"
    case permissionDenied = "PERMISSION_DENIED"
    case rangeOutOfBounds = "RANGE_OUT_OF_BOUNDS"
    case anchorNotFound = "ANCHOR_NOT_FOUND"
    case patchApplyFailed = "PATCH_APPLY_FAILED"
    case conflict = "CONFLICT"
    case commandFailed = "COMMAND_FAILED"
}

// MARK: - Response Envelope Types

struct ToolError: Codable {
    var code: String
    var message: String
    var details: [String: String]?
}

struct NextHint: Codable {
    var suggested_cmd: String?
    var suggested_args: [String: String]?
    var reason: String?
}

struct Telemetry: Codable {
    var truncated: Bool
    var warnings: [String]

    init(truncated: Bool = false, warnings: [String] = []) {
        self.truncated = truncated
        self.warnings = warnings
    }
}

// MARK: - FileSystem Data Types

struct Entry: Codable {
    var path: String
    var name: String
    var type: String  // "file" | "dir"
}

struct LineRef: Codable {
    var line: Int
    var text: String
}

struct SearchMatch: Codable {
    var path: String
    var line: Int
    var text: String
    var context_before: [LineRef]?
    var context_after: [LineRef]?
}

// MARK: - Git Data Types

struct GitPathStatus: Codable {
    var path: String
    var status: String
}

struct Commit: Codable {
    var hash: String
    var message: String
    var author: String?
    var date: String?
}

struct BranchInfo: Codable {
    var name: String
    var current: Bool
    var upstream: String?
    var is_remote: Bool?
}

// MARK: - Xcode Data Types

struct XcodeIssue: Codable {
    var file: String?
    var line: Int?
    var column: Int?
    var severity: String?
    var message: String
    var raw: String?
}

struct XcodeProjectRef: Codable {
    var kind: String  // "workspace" | "project"
    var path: String
}

// MARK: - Supervisor Data Types

struct AskSupervisorData: Codable {
    var question: String
    var status: String
}

// MARK: - Argument Error

enum ToolArgumentError: LocalizedError {
    case missingRequired(String)

    var errorDescription: String? {
        switch self {
        case .missingRequired(let key):
            "Missing required argument: \(key)"
        }
    }
}
