import XCTest
@testable import NanoTeams

/// Pins `ActivityDetailWindow.Hashable`/`Equatable` semantics — `==`/`hash` are
/// overridden to compare ONLY a stable `dedupKey`, NOT the full payload.
///
/// Why: SwiftUI's `WindowGroup(for:)` opens one window per unique `Hashable`
/// value. Without the override the synthesized `==` would compare full
/// payloads, so every streaming-tick mutation of `text`/`resultJSON` would
/// look like a new value and pop a new window.
///
/// Three behaviour groups pinned here:
///   1. Same record / mutated payload → equal (window dedup).
///   2. Different ids → not equal (distinct windows).
///   3. Different cases sharing the same UUID → not equal (no cross-case
///      collision because `dedupKey` carries a per-case prefix).
///   4. Same artifact name in same task but different files → not equal
///      (regression guard for the Frontend/QC `index.html` collision pinned
///      by `TimelineArtifactIDCollisionTests`).
///   5. Codable: `init(from:)` throws — windows aren't restored from disk.
final class ActivityDetailWindowDedupTests: XCTestCase {

    // MARK: - Same id, mutated payload → equal (window dedup)

    func testThinking_sameIDDifferentText_areEqual() {
        let id = UUID()
        let a = ActivityDetailWindow.thinking(id: id, roleName: "PM", text: "abc")
        let b = ActivityDetailWindow.thinking(id: id, roleName: "PM", text: "abc — much longer now")
        XCTAssertEqual(a, b, "Mid-stream payload mutation must keep the same window value (focus existing).")
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testThinking_sameIDDifferentRoleName_areEqual() {
        let id = UUID()
        let a = ActivityDetailWindow.thinking(id: id, roleName: "PM", text: "x")
        let b = ActivityDetailWindow.thinking(id: id, roleName: "Tech Lead", text: "x")
        XCTAssertEqual(a, b, "RoleName is display-only — same id is the same window.")
    }

    func testToolCall_sameIDDifferentResult_areEqual() {
        let id = UUID()
        let a = ActivityDetailWindow.toolCall(
            id: id, toolName: "read_file",
            argumentsJSON: "{}", resultJSON: nil,
            isError: false, createdAt: Date(timeIntervalSince1970: 0)
        )
        let b = ActivityDetailWindow.toolCall(
            id: id, toolName: "read_file",
            argumentsJSON: "{}", resultJSON: "{\"content\": \"...\"}",
            isError: false, createdAt: Date(timeIntervalSince1970: 100)
        )
        XCTAssertEqual(a, b, "Tool result completing between two clicks must reuse the same window.")
    }

    // MARK: - Different ids → not equal (distinct windows)

    func testThinking_differentIDs_areNotEqual() {
        let a = ActivityDetailWindow.thinking(id: UUID(), roleName: "PM", text: "x")
        let b = ActivityDetailWindow.thinking(id: UUID(), roleName: "PM", text: "x")
        XCTAssertNotEqual(a, b)
    }

    func testToolCall_differentIDs_areNotEqual() {
        let a = ActivityDetailWindow.toolCall(
            id: UUID(), toolName: "read_file",
            argumentsJSON: "{}", resultJSON: nil,
            isError: false, createdAt: Date()
        )
        let b = ActivityDetailWindow.toolCall(
            id: UUID(), toolName: "read_file",
            argumentsJSON: "{}", resultJSON: nil,
            isError: false, createdAt: Date()
        )
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Cross-case dedup namespace

    func testCrossCase_sameUUID_distinctCases_areNotEqual() {
        let id = UUID()
        let llm = ActivityDetailWindow.thinking(id: id, roleName: "X", text: "y")
        let meeting = ActivityDetailWindow.meetingThinking(id: id, roleName: "X", text: "y")
        let supervisor = ActivityDetailWindow.supervisorThinking(id: id, roleName: "X", text: "y")
        let toolCall = ActivityDetailWindow.toolCall(
            id: id, toolName: "x",
            argumentsJSON: "{}", resultJSON: nil,
            isError: false, createdAt: Date()
        )
        let summary = MeetingToolSummary(
            id: id, toolName: "x", arguments: "{}", result: ""
        )
        let meetingTool = ActivityDetailWindow.meetingTool(id: id, summary: summary)
        let meetingTools = ActivityDetailWindow.meetingTools(id: id, summaries: [summary])
        // A system notice keys on `LLMMessage.id` — the SAME id space as
        // `.thinking`, so this pair is a real collision risk, not a theoretical
        // one: one message can own both a thinking window and a notice window.
        let systemNotice = ActivityDetailWindow.systemNotice(id: id, label: "retry", text: "y")

        // All pairwise-distinct because each case prefixes its own namespace
        // into `dedupKey`.
        let cases: [ActivityDetailWindow] = [
            llm, meeting, supervisor, toolCall, meetingTool, meetingTools, systemNotice,
        ]
        for i in 0..<cases.count {
            for j in (i + 1)..<cases.count {
                XCTAssertNotEqual(cases[i], cases[j],
                                  "Cases \(i) and \(j) share UUID \(id) but must dedup separately.")
            }
        }
    }

    // MARK: - Artifact dedup uses relativePath, not name

    /// Regression guard for the Frontend Developer / Quality Controller
    /// `index.html` collision pinned at the timeline-id level by
    /// `TimelineArtifactIDCollisionTests`. The same hazard exists at the
    /// window level: two roles in the same task can produce same-named
    /// artifacts, paths differ via the role-dir, and the dedup key MUST
    /// include the path to keep windows distinct.
    func testArtifact_sameNameDifferentRolesInSameTask_areNotEqual() {
        let frontend = ActivityDetailWindow.artifact(
            taskID: 9,
            artifactName: "index.html",
            mimeType: "text/html",
            relativePath: "tasks/9/runs/0/roles/frontend_developer_step/artifact_index_html.md",
            createdAt: Date()
        )
        let qc = ActivityDetailWindow.artifact(
            taskID: 9,
            artifactName: "index.html",
            mimeType: "text/html",
            relativePath: "tasks/9/runs/0/roles/quality_controller_step/artifact_index_html.md",
            createdAt: Date()
        )
        XCTAssertNotEqual(frontend, qc,
                          "Two roles' same-named artifacts must open distinct windows (paths differ).")
    }

    func testArtifact_sameRelativePath_areEqual() {
        // Idempotency: re-emitting the same artifact (re-run/restart) must
        // dedup so the user doesn't see two windows for the same file.
        let path = "tasks/3/runs/0/roles/engineer_step/artifact_engineering_notes.md"
        let a = ActivityDetailWindow.artifact(
            taskID: 3, artifactName: "Engineering Notes", mimeType: "text/markdown",
            relativePath: path, createdAt: Date(timeIntervalSince1970: 0)
        )
        let b = ActivityDetailWindow.artifact(
            taskID: 3, artifactName: "Engineering Notes", mimeType: "text/markdown",
            relativePath: path, createdAt: Date(timeIntervalSince1970: 999)
        )
        XCTAssertEqual(a, b)
    }

    func testArtifact_sameNameDifferentTasks_areNotEqual() {
        let parentPath = "tasks/1/runs/0/roles/engineer_step/artifact_engineering_notes.md"
        let childPath = "tasks/1/subtasks/2/runs/0/roles/engineer_step/artifact_engineering_notes.md"
        let parent = ActivityDetailWindow.artifact(
            taskID: 1, artifactName: "Engineering Notes", mimeType: "text/markdown",
            relativePath: parentPath, createdAt: Date()
        )
        let child = ActivityDetailWindow.artifact(
            taskID: 2, artifactName: "Engineering Notes", mimeType: "text/markdown",
            relativePath: childPath, createdAt: Date()
        )
        XCTAssertNotEqual(parent, child)
    }

    /// Defensive: a transient artifact without a persisted `relativePath`
    /// dedups by `(taskID, name, createdAt)`. Same name + same timestamp
    /// (re-emit / idempotent restore) still collapses to one window.
    func testArtifact_nilRelativePath_sameCreatedAt_dedupsAsIdempotentReemit() {
        let stamp = Date(timeIntervalSince1970: 42)
        let a = ActivityDetailWindow.artifact(
            taskID: 5, artifactName: "Untitled", mimeType: "text/plain",
            relativePath: nil, createdAt: stamp
        )
        let b = ActivityDetailWindow.artifact(
            taskID: 5, artifactName: "Untitled", mimeType: "text/plain",
            relativePath: nil, createdAt: stamp
        )
        XCTAssertEqual(a, b, "Idempotent re-emit (same timestamp) must dedup to one window.")
    }

    /// Pre-fix the transient fallback only used `(taskID, name)`, so two
    /// roles in the same task each emitting `index.html` (Frontend Developer
    /// + Quality Controller — see `testArtifact_sameNameDifferentRolesInSameTask_areNotEqual`
    /// for the persisted variant) collided into one window before either
    /// artifact was written to disk. Mixing `createdAt` distinguishes them
    /// without expanding the case payload to carry roleID; production
    /// `Artifact.createdAt` is sourced from `MonotonicClock` so collisions
    /// across independent calls are impossible.
    func testArtifact_nilRelativePath_distinctCreatedAt_areNotEqual() {
        let a = ActivityDetailWindow.artifact(
            taskID: 9, artifactName: "index.html", mimeType: "text/html",
            relativePath: nil, createdAt: Date(timeIntervalSince1970: 10)
        )
        let b = ActivityDetailWindow.artifact(
            taskID: 9, artifactName: "index.html", mimeType: "text/html",
            relativePath: nil, createdAt: Date(timeIntervalSince1970: 11)
        )
        XCTAssertNotEqual(a, b,
                          "Two transient same-named artifacts emitted at distinct timestamps must open separate windows.")
    }

    // MARK: - System notice dedup

    /// `.serverError` notices rewrite their text in place across retry attempts
    /// on the SAME message id, so a payload-sensitive identity would pop a new
    /// window on every attempt.
    func testSystemNotice_sameIDDifferentText_areEqual() {
        let id = UUID()
        let a = ActivityDetailWindow.systemNotice(
            id: id, label: "server error", text: "attempt 1/3 … Retrying in 10s…")
        let b = ActivityDetailWindow.systemNotice(
            id: id, label: "server error", text: "attempt 2/3 … Retrying in 10s…")
        XCTAssertEqual(a, b, "A retry rewriting the note in place must reuse the open window.")
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testSystemNotice_sameIDDifferentLabel_areEqual() {
        let id = UUID()
        let a = ActivityDetailWindow.systemNotice(id: id, label: "retry", text: "x")
        let b = ActivityDetailWindow.systemNotice(id: id, label: "loop correction", text: "x")
        XCTAssertEqual(a, b, "Label is display-only — same message id is the same window.")
    }

    func testSystemNotice_differentIDs_areNotEqual() {
        let a = ActivityDetailWindow.systemNotice(id: UUID(), label: "retry", text: "x")
        let b = ActivityDetailWindow.systemNotice(id: UUID(), label: "retry", text: "x")
        XCTAssertNotEqual(a, b, "Two nudges must open two windows.")
    }

    // MARK: - Codable: encoding emits dedupKey, decoding throws

    func testCodable_decodeThrows() throws {
        let value = ActivityDetailWindow.thinking(id: UUID(), roleName: "PM", text: "x")
        let encoded = try JSONEncoder().encode(value)
        XCTAssertThrowsError(try JSONDecoder().decode(ActivityDetailWindow.self, from: encoded),
                             "ActivityDetailWindow must not be decodable — windows aren't restored from disk.")
    }

    func testCodable_encodeWritesDedupKey() throws {
        let id = UUID()
        let value = ActivityDetailWindow.thinking(id: id, roleName: "PM", text: "x")
        let encoded = try JSONEncoder().encode(value)
        let decodedAsString = try JSONDecoder().decode(String.self, from: encoded)
        XCTAssertEqual(decodedAsString, "thinking:\(id)",
                       "Encoding must emit the dedupKey only — never the full payload.")
    }

    func testCodable_encodeWritesDedupKey_forSystemNotice() throws {
        let id = UUID()
        let value = ActivityDetailWindow.systemNotice(id: id, label: "retry", text: "x")
        let encoded = try JSONEncoder().encode(value)
        let decodedAsString = try JSONDecoder().decode(String.self, from: encoded)
        XCTAssertEqual(decodedAsString, "system-notice:\(id)")
    }
}
