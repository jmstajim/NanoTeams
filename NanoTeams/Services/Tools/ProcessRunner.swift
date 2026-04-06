import Foundation

enum ProcessRunnerError: LocalizedError {
    case timeout(TimeInterval)
    case executableNotFound(String)

    var errorDescription: String? {
        switch self {
        case .timeout(let seconds):
            "Process timed out after \(Int(seconds)) seconds"
        case .executableNotFound(let path):
            "Executable not found: \(path)"
        }
    }
}

struct ProcessRunner {
    struct Result {
        var exitCode: Int32
        var stdout: String
        var stderr: String

        var success: Bool { exitCode == 0 }
        var combinedOutput: String { stdout + stderr }
    }

    static func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 60
    ) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        if let dir = currentDirectory {
            process.currentDirectoryURL = dir
        }

        if let env = environment {
            var processEnv = ProcessInfo.processInfo.environment
            for (key, value) in env {
                processEnv[key] = value
            }
            process.environment = processEnv
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.executableNotFound(executable)
        }

        let timeoutWorkItem = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }

        DispatchQueue.global().asyncAfter(
            deadline: .now() + timeout,
            execute: timeoutWorkItem
        )

        // Read pipes concurrently BEFORE waitUntilExit to prevent deadlock.
        // If the child process fills the pipe buffer (~64KB), it blocks on write.
        // Calling waitUntilExit() before draining the pipes would deadlock.
        var stdoutData = Data()
        var stderrData = Data()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        process.waitUntilExit()
        group.wait()
        timeoutWorkItem.cancel()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        // Check if terminated due to timeout
        if process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGTERM {
            throw ProcessRunnerError.timeout(timeout)
        }

        return Result(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }

    /// Run git command in specified directory
    static func runGit(
        _ arguments: [String],
        in directory: URL,
        timeout: TimeInterval = 60
    ) throws -> Result {
        try run(
            executable: "/usr/bin/git",
            arguments: arguments,
            currentDirectory: directory,
            timeout: timeout
        )
    }

    /// Run xcodebuild command in specified directory
    static func runXcodebuild(
        _ arguments: [String],
        in directory: URL,
        timeout: TimeInterval = 600
    ) throws -> Result {
        try run(
            executable: "/usr/bin/xcodebuild",
            arguments: arguments,
            currentDirectory: directory,
            timeout: timeout
        )
    }
}
