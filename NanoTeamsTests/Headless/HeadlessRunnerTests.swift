import XCTest
@testable import NanoTeams

@MainActor
final class HeadlessRunnerTests: XCTestCase {

    /// Main entry point for headless execution.
    ///
    /// Invoke via:
    /// ```
    /// xcodebuild test -project NanoTeams.xcodeproj -scheme NanoTeams \
    ///   -only-testing NanoTeamsTests/HeadlessRunnerTests/testRunHeadless
    /// ```
    ///
    /// Config is loaded from `.nanoteams/headless_task.json` in the project root.
    /// If the file doesn't exist, the test silently passes (normal test suite unaffected).
    func testRunHeadless() async throws {
        // Resolve project root from this source file's location
        let sourceFile = URL(fileURLWithPath: #filePath)
        let workFolderRoot = sourceFile
            .deletingLastPathComponent() // Headless/
            .deletingLastPathComponent() // NanoTeamsTests/
            .deletingLastPathComponent() // NanoTeams/ (project root)

        let configURL = workFolderRoot
            .appendingPathComponent(".nanoteams")
            .appendingPathComponent("headless_task.json")

        guard FileManager.default.fileExists(atPath: configURL.path) else {
            print("[HEADLESS] No config at \(configURL.path) — skipping.")
            return
        }

        // Load config
        let configData = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(HeadlessConfig.self, from: configData)

        // Pre-flight: check if LLM server is reachable (skip if not)
        let serverURL = URL(string: config.resolvedBaseURL)!
        let probe = URLRequest(url: serverURL, timeoutInterval: 3)
        let reachable: Bool
        do {
            let (_, response) = try await URLSession.shared.data(for: probe)
            reachable = (response as? HTTPURLResponse)?.statusCode != nil
        } catch {
            reachable = false
        }
        guard reachable else {
            print("[HEADLESS] LLM server at \(config.resolvedBaseURL) is not reachable — skipping.")
            return
        }

        print("[HEADLESS] ==========================================")
        print("[HEADLESS] Task: \(config.taskTitle)")
        print("[HEADLESS] Goal: \(config.supervisorTask.prefix(120))...")
        print("[HEADLESS] Project: \(config.projectPath)")
        print("[HEADLESS] Team: \(config.teamTemplate ?? "startup")")
        print("[HEADLESS] Timeout: \(config.timeoutSeconds ?? 600)s")
        print("[HEADLESS] ==========================================")

        // Run
        let runner = HeadlessRunner(config: config)
        let result = await runner.run()

        // Print summary
        printResult(result)

        // Write result JSON
        writeResultJSON(result, projectPath: config.projectPath)

        // Assert success
        XCTAssertEqual(
            result.outcome, .success,
            "Headless run failed: \(result.errors.joined(separator: "; "))"
        )
    }

    // MARK: - Output

    private func printResult(_ result: HeadlessResult) {
        print("")
        print("[HEADLESS] ==========================================")
        print("[HEADLESS] RESULT: \(result.outcome.rawValue.uppercased())")
        print("[HEADLESS] Duration: \(Int(result.duration))s")
        print("[HEADLESS] Tokens: \(result.inputTokens) in / \(result.outputTokens) out")

        print("[HEADLESS] ---")
        print("[HEADLESS] Roles:")
        for role in result.roleResults.sorted(by: { $0.roleName < $1.roleName }) {
            let step = role.stepStatus.map { " step:\($0.rawValue)" } ?? ""
            print("[HEADLESS]   \(role.roleName): \(role.status.rawValue)\(step) | msgs:\(role.messageCount) tools:\(role.toolCallCount)")
        }

        if !result.artifacts.isEmpty {
            print("[HEADLESS] ---")
            print("[HEADLESS] Artifacts:")
            for artifact in result.artifacts {
                print("[HEADLESS]   \(artifact.name)")
            }
        }

        if !result.errors.isEmpty {
            print("[HEADLESS] ---")
            print("[HEADLESS] Errors:")
            for err in result.errors {
                print("[HEADLESS]   \(err)")
            }
        }
        print("[HEADLESS] ==========================================")
    }

    private func writeResultJSON(_ result: HeadlessResult, projectPath: String) {
        let paths = NTMSPaths(workFolderRoot: URL(fileURLWithPath: projectPath))

        struct ResultJSON: Codable {
            var outcome: String
            var durationSeconds: Int
            var taskID: String?
            var runID: Int?
            var inputTokens: Int
            var outputTokens: Int
            var roles: [RoleJSON]
            var artifacts: [String]
            var errors: [String]

            struct RoleJSON: Codable {
                var name: String
                var status: String
                var messageCount: Int
                var toolCallCount: Int
            }
        }

        let json = ResultJSON(
            outcome: result.outcome.rawValue,
            durationSeconds: Int(result.duration),
            taskID: result.taskID.map(String.init),
            runID: result.runID,
            inputTokens: result.inputTokens,
            outputTokens: result.outputTokens,
            roles: result.roleResults.map {
                ResultJSON.RoleJSON(
                    name: $0.roleName,
                    status: $0.status.rawValue,
                    messageCount: $0.messageCount,
                    toolCallCount: $0.toolCallCount
                )
            },
            artifacts: result.artifacts.map(\.name),
            errors: result.errors
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(json)
            let outputURL = paths.headlessResultJSON
            try data.write(to: outputURL)
            print("[HEADLESS] Result → \(outputURL.path)")
        } catch {
            print("[HEADLESS] Failed to write result JSON: \(error)")
        }
    }
}
