import XCTest
@testable import NanoTeams

@MainActor
final class HeadlessRunnerTests: XCTestCase {

    /// Main entry point for headless execution.
    ///
    /// Invoke via `./run_headless.sh path/to/config.json`, or directly:
    /// ```
    /// NANOTEAMS_CONFIG_PATH=path/to/config.json \
    /// xcodebuild test -project NanoTeams.xcodeproj -scheme NanoTeams \
    ///   -only-testing NanoTeamsTests/HeadlessRunnerTests/testRunHeadless
    /// ```
    ///
    /// Config resolution, in order: `NANOTEAMS_CONFIG_PATH` (what
    /// `run_headless.sh` exports), else `<repoRoot>/.nanoteams/headless_task.json`
    /// (what the train-app skill writes when it invokes `xcodebuild` directly).
    ///
    /// A named-but-absent override FAILS; no config at all SKIPS. Neither
    /// passes: the old bare `return` on both made a run that did nothing report
    /// "completed successfully" through the wrapper.
    ///
    /// Every skip prints a `[HEADLESS] SKIP:` line BEFORE throwing, because
    /// `run_headless.sh` filters output to lines containing `[HEADLESS]`,
    /// `Test Case`, `error:` or `** TEST` — an `XCTSkip` message alone is
    /// swallowed, and a skipped test still exits `xcodebuild` with 0.
    func testRunHeadless() async throws {
        // Resolve project root from this source file's location
        let sourceFile = URL(fileURLWithPath: #filePath)
        let workFolderRoot = sourceFile
            .deletingLastPathComponent() // Headless/
            .deletingLastPathComponent() // NanoTeamsTests/
            .deletingLastPathComponent() // NanoTeams/ (project root)

        let configURL: URL
        switch HeadlessConfigLocator.resolve(
            environment: ProcessInfo.processInfo.environment,
            repositoryRoot: workFolderRoot,
            fileExists: { FileManager.default.fileExists(atPath: $0.path) }
        ) {
        case .found(let url, let source):
            // The wrapper greps for this exact line to prove the environment
            // reached the test host.
            print("[HEADLESS] Config: \(url.path) (source: \(source))")
            configURL = url

        case .missingOverride(let url):
            let message = "\(HeadlessConfigLocator.environmentKey) points at "
                + "\(url.path), but no file exists there."
            print("[HEADLESS] error: \(message)")
            receipt(.failed, config: url.path, detail: message)
            XCTFail(message)
            return

        case .none(let checked):
            let message = "No headless config. Set "
                + "\(HeadlessConfigLocator.environmentKey), or create \(checked.path)."
            print("[HEADLESS] SKIP: \(message)")
            receipt(.skipped, config: nil, detail: message)
            throw XCTSkip(message)
        }

        // Load config. `makeWireDecoder` for parity with the sibling trainers.
        let configData = try Data(contentsOf: configURL)
        let config = try JSONCoderFactory.makeWireDecoder()
            .decode(HeadlessConfig.self, from: configData)

        // Pre-flight: check if the LLM server is reachable (skip if not)
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
            let message = "LLM server at \(config.resolvedBaseURL) is not reachable."
            print("[HEADLESS] SKIP: \(message)")
            receipt(.skipped, config: configURL.path, detail: message)
            throw XCTSkip(message)
        }

        // From here the run genuinely happens, so the receipt is written BEFORE
        // the (possibly long) run rather than after — a crash or a hard timeout
        // must not read back as "never started".
        receipt(.ran, config: configURL.path,
                detail: "\(config.taskTitle) on \(config.resolvedProvider.rawValue)")

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

    /// Records what this run decided, for `run_headless.sh` to gate on. See
    /// `HeadlessConfigLocator.receiptEnvironmentKey` for why a file rather than
    /// the printed lines the wrapper filters for.
    private func receipt(
        _ status: HeadlessConfigLocator.Receipt.Status, config: String?, detail: String
    ) {
        HeadlessConfigLocator.writeReceipt(
            HeadlessConfigLocator.Receipt(status: status, configPath: config, detail: detail))
    }

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
