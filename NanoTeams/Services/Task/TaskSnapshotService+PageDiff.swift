import Foundation

/// A page of `task_changes`, diffed FILE BY FILE and decoded without loss (N8 and S5,
/// 2026-11-12).
///
/// One `git diff` over the whole page came back as one string decoded through
/// `String(decoding:as:)`: a Latin-1 or CP1251 file reached the agent with `�` and no sign, a
/// binary file was told apart only by git's own `Binary files … differ`, and a hidden character
/// in one file's diff could not be told from one in another's — so every file of the round was
/// warned about. Per file, each diff is its own bytes: valid UTF-8 is text, any other byte is
/// spelled `<0xNN>` and the file is marked, and git's binary verdict is read from the header.
/// A page is at most `page_size` files, so this is at most that many `git diff` calls.
extension TaskSnapshotService {

    /// One file's part of a page diff — what the presentation layer sanitizes and warns about,
    /// never sent as it is.
    struct PageFileDiff: Equatable, Sendable {
        let path: String
        let text: String
        let binary: Bool
        let notUTF8: Bool
    }

    /// The value `ChangedFile.encoding` takes for a file whose diff is not valid UTF-8.
    nonisolated static let notUTF8Encoding = "not_utf8"

    func pageDiffs(
        _ files: [ChangedFile], from startRef: String, to endRef: String, workFolder: URL, gitDir: URL
    ) async throws -> [PageFileDiff] {
        var out: [PageFileDiff] = []
        for file in files {
            var paths = [":(literal)\(file.path)"]
            if let oldPath = file.old_path, !oldPath.isEmpty, oldPath != file.path {
                paths.append(":(literal)\(oldPath)")
            }
            let args = [
                "--git-dir=\(gitDir.path)",
                "-c", "core.quotePath=false",
                "diff",
                "-M",
                "-U3",
                startRef,
                endRef,
                "--"
            ] + paths
            let res = try await runPrivateGit(args, in: workFolder, gitDir: gitDir, isDiff: true)
            if res.exitCode != 0 {
                throw ExternalAutovisorError("Snapshot diff failed: \(res.stderr)", code: .commandFailed)
            }
            let decoded = Self.losslessText(res.stdoutData)
            out.append(PageFileDiff(
                path: file.path,
                text: decoded.text,
                binary: Self.isBinaryDiff(decoded.text),
                notUTF8: decoded.hadInvalidBytes
            ))
        }
        return out
    }

    /// git's binary verdict, from the header — the lines before the first hunk, which git writes
    /// itself (a file's own text only follows a `@@`).
    nonisolated static func isBinaryDiff(_ text: String) -> Bool {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") { return false }
            if line.hasPrefix("Binary files ") && line.hasSuffix(" differ") { return true }
        }
        return false
    }

    /// UTF-8 decoded as far as it is UTF-8; every other byte spelled `<0xNN>`. Nothing becomes
    /// U+FFFD, so nothing is lost and nothing passes for a character the file does not hold.
    nonisolated static func losslessText(_ data: Data) -> (text: String, hadInvalidBytes: Bool) {
        if let text = String(data: data, encoding: .utf8) { return (text, false) }
        let bytes = [UInt8](data)
        var out = ""
        var run: [UInt8] = []
        var index = 0
        func flush() {
            if !run.isEmpty {
                out += String(decoding: run, as: UTF8.self)
                run.removeAll(keepingCapacity: true)
            }
        }
        while index < bytes.count {
            let length = validSequenceLength(bytes, at: index)
            if length > 0 {
                run.append(contentsOf: bytes[index..<(index + length)])
                index += length
            } else {
                flush()
                out += String(format: "<0x%02X>", bytes[index])
                index += 1
            }
        }
        flush()
        return (out, true)
    }

    /// The length of the well-formed UTF-8 sequence starting at `index` (Unicode Table 3-7),
    /// or 0 when the byte there does not start one.
    private nonisolated static func validSequenceLength(_ bytes: [UInt8], at index: Int) -> Int {
        let lead = bytes[index]
        let length: Int
        var secondRange: ClosedRange<UInt8> = 0x80...0xBF
        switch lead {
        case 0x00...0x7F: return 1
        case 0xC2...0xDF: length = 2
        case 0xE0: length = 3; secondRange = 0xA0...0xBF
        case 0xE1...0xEC, 0xEE...0xEF: length = 3
        case 0xED: length = 3; secondRange = 0x80...0x9F
        case 0xF0: length = 4; secondRange = 0x90...0xBF
        case 0xF1...0xF3: length = 4
        case 0xF4: length = 4; secondRange = 0x80...0x8F
        default: return 0
        }
        guard index + length <= bytes.count, secondRange.contains(bytes[index + 1]) else { return 0 }
        for offset in 2..<length where !(0x80...0xBF).contains(bytes[index + offset]) {
            return 0
        }
        return length
    }
}
