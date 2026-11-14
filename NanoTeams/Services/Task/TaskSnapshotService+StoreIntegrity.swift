import Foundation

/// The snapshot store holds what NanoTeams wrote into it, checked before EVERY sequence of git
/// calls (S1 of the F6 acceptance, 2026-11-12).
///
/// git reads a repository's `config`, `info/`, `objects/info/alternates`, `hooks/` and
/// `commondir` as instructions: a filter driver, an attributes file, someone else's objects, a
/// hook, someone else's whole repository. The Seatbelt profile keeps roles out of
/// `.nanoteams/internal`, and this is the second wall behind it: the reference config is what
/// `git init` plus the service's one setting write on THIS volume (it records the volume's case
/// sensitivity and Unicode normalization), replayed on a scratch store beside the real one and
/// never read back from the store it judges. What differs is written again, what NanoTeams
/// never writes is removed, and each repair is recorded so `task_changes` of every round open
/// at that moment warns about it.
extension TaskSnapshotService {

    /// The `info/attributes` NanoTeams writes. `info/attributes` outranks every `.gitattributes`
    /// in the work tree, so this resets — to unspecified, as if no file set it — each attribute
    /// that changes the bytes `add` stores (`text`/`crlf`/`eol`, `ident`, `filter`,
    /// `working-tree-encoding`) or the diff the agent reads (`diff`). It is what holds on a git
    /// older than 2.40, which ignores `GIT_ATTR_SOURCE` (`snapshotGitEnvironment`).
    nonisolated static let attributesOverride = "* !text !crlf !eol !ident !filter !working-tree-encoding !diff\n"

    /// The entries of `info/` that are NanoTeams' or git's own: the excludes mirror, the
    /// attributes override, and the `refs` list `gc` writes (repack runs update-server-info).
    nonisolated static let ownInfoEntries: Set<String> = ["exclude", "attributes", "refs"]

    /// Where the store keeps NanoTeams' or git's instructions to itself that NanoTeams never
    /// writes — removed whenever present.
    nonisolated static let foreignStoreEntries = ["hooks", "commondir", "objects/info/alternates", "objects/info/http-alternates"]

    /// The label a repair of an `info/` entry NanoTeams does not know is reported under. The
    /// entry's own name is whoever planted it's text, so it never reaches the agent.
    nonisolated static let unknownInfoEntryLabel = "info/*"

    /// One ref per repair, `<unix milliseconds>-<id>`, to a JSON blob of what was put back. Never
    /// deleted: a repair belongs to every round open at its moment, whichever task's call made it.
    /// Refs written before 2026-11-12 carry whole SECONDS (`momentMilliseconds(fromRefMoment:)`).
    nonisolated static let repairRefPrefix = "refs/nanoteams-repairs/"

    /// The commit-message line that stamps a snapshot's moment in milliseconds, on the same
    /// clock as the repair journal. git's own committer time is whole seconds, and a repair
    /// made in the second a round started read as that round's (2026-11-12).
    nonisolated static let snapshotMomentTrailer = "Snapshot-Moment-Ms: "

    /// Now, in milliseconds, strictly after every moment this process stamped before:
    /// snapshot sequences are serialized by the folder lock, so a repair and a round start
    /// never share a moment and the window comparison can be strict.
    nonisolated static func snapshotMomentMilliseconds() -> Int64 {
        Int64((MonotonicClock.shared.now().timeIntervalSince1970 * 1000).rounded(.down))
    }

    /// A journal ref's moment in milliseconds; a pre-2026-11-12 ref names whole seconds.
    nonisolated static func momentMilliseconds(fromRefMoment value: Int64) -> Int64 {
        value < 100_000_000_000 ? value * 1000 : value
    }

    /// The commit-message line a snapshot keeps the repairs ITS OWN check made in — a start
    /// snapshot's repair comes before the start, and a moment before the start belongs to no
    /// round's window.
    nonisolated static let storeRepairedTrailer = "Store-Repaired: "

    // MARK: - Creation, and the reference it is

    /// What a new store is: `git init` and the one setting the service adds, then the
    /// attributes override. The reference config is this, replayed beside the store.
    func initializeStore(at gitDir: URL, workFolder: URL) async throws {
        let initRes = try await runPrivateGit(
            ["init", "--bare", "--template=", "--shared=0600", gitDir.path],
            in: workFolder,
            gitDir: nil
        )
        if initRes.exitCode != 0 {
            throw ExternalAutovisorError("Failed to initialize snapshots repository: \(initRes.stderr)", code: .commandFailed)
        }
        try? fileManager.setAttributes(NTMSRepository.internalDirAttributes, ofItemAtPath: gitDir.path)
        let configRes = try await runPrivateGit(
            ["--git-dir=\(gitDir.path)", "config", "core.sharedRepository", "0600"],
            in: workFolder,
            gitDir: gitDir
        )
        if configRes.exitCode != 0 {
            throw ExternalAutovisorError("Failed to configure snapshots repository: \(configRes.stderr)", code: .commandFailed)
        }
        try writeOwnedFile(Data(Self.attributesOverride.utf8), to: infoDirectory(of: gitDir, creating: true)
            .appendingPathComponent("attributes"))
    }

    /// The config `initializeStore` writes for a store at `gitDir`'s location — produced on a
    /// scratch store in the same directory, once per store per service.
    func referenceConfig(for gitDir: URL, workFolder: URL) async throws -> Data {
        if let cached = referenceConfigs[gitDir.path] { return cached }
        let scratch = gitDir.deletingLastPathComponent()
            .appendingPathComponent("\(Self.referenceStorePrefix)\(UUID().uuidString).git", isDirectory: true)
        defer { try? fileManager.removeItem(at: scratch) }
        try await initializeStore(at: scratch, workFolder: workFolder)
        let data = try Data(contentsOf: scratch.appendingPathComponent("config"))
        referenceConfigs[gitDir.path] = data
        return data
    }

    // MARK: - The check

    /// Brings an existing store back to its reference. Returns what it had to put back or take
    /// away, by fixed labels (`config`, `hooks`, `info/attributes`, `info/*`, …). Throws when it
    /// cannot: a store it could not restore is not run.
    func restoreStore(gitDir: URL, workFolder: URL) async throws -> [String] {
        var repaired: [String] = []
        do {
            let reference = try await referenceConfig(for: gitDir, workFolder: workFolder)
            let config = gitDir.appendingPathComponent("config")
            if !isPlainFile(config) || (try? Data(contentsOf: config)) != reference {
                try removeIfPresent(config)
                try writeOwnedFile(reference, to: config)
                repaired.append("config")
            }

            for relative in Self.foreignStoreEntries {
                if try removeIfPresent(gitDir.appendingPathComponent(relative)) {
                    repaired.append(relative)
                }
            }

            let info = gitDir.appendingPathComponent("info", isDirectory: true)
            if exists(info), !isPlainDirectory(info) {
                try removeIfPresent(info)
                repaired.append("info")
            }
            let infoDir = try infoDirectory(of: gitDir, creating: true)
            var foundUnknown = false
            for name in (try? fileManager.contentsOfDirectory(atPath: infoDir.path)) ?? [] {
                let entry = infoDir.appendingPathComponent(name)
                if Self.ownInfoEntries.contains(name) {
                    guard !isPlainFile(entry) else { continue }
                    try removeIfPresent(entry)
                    repaired.append("info/\(name)")
                } else {
                    try removeIfPresent(entry)
                    foundUnknown = true
                }
            }
            if foundUnknown { repaired.append(Self.unknownInfoEntryLabel) }

            // A store from before the override has none: written, not reported.
            let attributes = infoDir.appendingPathComponent("attributes")
            let override = Data(Self.attributesOverride.utf8)
            if exists(attributes), (try? Data(contentsOf: attributes)) != override {
                try removeIfPresent(attributes)
                repaired.append("info/attributes")
            }
            if !exists(attributes) {
                try writeOwnedFile(override, to: attributes)
            }
        } catch let error as ExternalAutovisorError {
            throw error
        } catch {
            throw ExternalAutovisorError(
                "Snapshot store could not be restored: \(error.localizedDescription)", code: .commandFailed)
        }
        return Array(Set(repaired)).sorted()
    }

    // MARK: - The record

    /// Records a repair at this moment, for every round open now to report.
    func recordStoreRepairs(_ repairs: [String], gitDir: URL, workFolder: URL) async {
        guard !repairs.isEmpty, let json = try? JSONEncoder().encode(repairs) else { return }
        let scratch = gitDir.appendingPathComponent("nanoteams-repair-\(UUID().uuidString).json")
        defer { try? fileManager.removeItem(at: scratch) }
        guard (try? json.write(to: scratch, options: .atomic)) != nil,
              let hashRes = try? await runPrivateGit(
                ["--git-dir=\(gitDir.path)", "hash-object", "-w", "--no-filters", scratch.path],
                in: workFolder, gitDir: gitDir),
              hashRes.exitCode == 0
        else { return }
        let sha = hashRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let moment = Self.snapshotMomentMilliseconds()
        let id = UUID().uuidString.prefix(8).lowercased()
        _ = try? await runPrivateGit(
            ["--git-dir=\(gitDir.path)", "update-ref", "\(Self.repairRefPrefix)\(moment)-\(id)", sha],
            in: workFolder, gitDir: gitDir)
    }

    nonisolated static func storeRepairedTrailerLine(_ repairs: [String]) -> String? {
        guard !repairs.isEmpty, let json = try? JSONEncoder().encode(repairs) else { return nil }
        return storeRepairedTrailer + json.base64EncodedString()
    }

    /// What was put back while a round was open: the repairs its own snapshots' checks made,
    /// and every repair recorded from its start to its end — to now, for a round still open.
    func storeRepairs(startRef: String, endRef: String?, workFolder: URL, gitDir: URL) async -> [String] {
        guard let listRes = try? await runPrivateGit(
            ["--git-dir=\(gitDir.path)", "for-each-ref", "--format=%(refname)", Self.repairRefPrefix],
            in: workFolder, gitDir: gitDir),
              listRes.exitCode == 0
        else { return [] }
        let refs = listRes.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard !refs.isEmpty else { return [] }

        let start = await commitRecord(startRef, workFolder: workFolder, gitDir: gitDir)
        var end: (time: Int64?, repairs: [String])?
        if let endRef {
            end = await commitRecord(endRef, workFolder: workFolder, gitDir: gitDir)
        }
        var repairs = Set(start.repairs + (end?.repairs ?? []))
        if let startTime = start.time {
            let endTime = end?.time ?? Self.snapshotMomentMilliseconds()
            for ref in refs {
                let name = ref.dropFirst(Self.repairRefPrefix.count)
                // Strictly after the start: a repair the start's own check made is in its
                // trailer, and one made before it belongs to an earlier round.
                guard let raw = name.split(separator: "-").first.flatMap({ Int64($0) }),
                      case let moment = Self.momentMilliseconds(fromRefMoment: raw),
                      startTime < moment, moment <= endTime,
                      let blobRes = try? await runPrivateGit(
                        ["--git-dir=\(gitDir.path)", "cat-file", "blob", ref], in: workFolder, gitDir: gitDir),
                      blobRes.exitCode == 0,
                      let recorded = try? JSONDecoder().decode([String].self, from: blobRes.stdoutData)
                else { continue }
                repairs.formUnion(recorded)
            }
        }
        return repairs.sorted()
    }

    /// A snapshot commit's moment in milliseconds — its `Snapshot-Moment-Ms:` line, else (a
    /// commit written before 2026-11-12) git's committer seconds — and the repairs its line names.
    func commitRecord(_ ref: String, workFolder: URL, gitDir: URL) async -> (time: Int64?, repairs: [String]) {
        guard let res = try? await runPrivateGit(
            ["--git-dir=\(gitDir.path)", "cat-file", "commit", ref], in: workFolder, gitDir: gitDir),
              res.exitCode == 0
        else { return (nil, []) }
        var committerTime: Int64?
        var stampedTime: Int64?
        var repairs: [String] = []
        for line in res.stdout.split(separator: "\n") {
            if committerTime == nil, line.hasPrefix("committer ") {
                // `committer <name> <<email>> <unix seconds> <zone>`
                let fields = line.split(separator: " ")
                if fields.count >= 2, let seconds = Int64(fields[fields.count - 2]) { committerTime = seconds * 1000 }
            } else if line.hasPrefix(Self.snapshotMomentTrailer) {
                stampedTime = Int64(line.dropFirst(Self.snapshotMomentTrailer.count))
            } else if line.hasPrefix(Self.storeRepairedTrailer),
                      let data = Data(base64Encoded: String(line.dropFirst(Self.storeRepairedTrailer.count))),
                      let decoded = try? JSONDecoder().decode([String].self, from: data) {
                repairs = decoded
            }
        }
        return (stampedTime ?? committerTime, repairs)
    }

    // MARK: - Files, without following a symlink

    private func exists(_ url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    private func isPlainFile(_ url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular
    }

    private func isPlainDirectory(_ url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory
    }

    /// Removes the entry itself — a symlink, not what it points at. `true` when there was one.
    @discardableResult
    private func removeIfPresent(_ url: URL) throws -> Bool {
        guard exists(url) else { return false }
        try fileManager.removeItem(at: url)
        return true
    }

    private func infoDirectory(of gitDir: URL, creating: Bool) throws -> URL {
        let info = gitDir.appendingPathComponent("info", isDirectory: true)
        if creating, !exists(info) {
            try fileManager.createDirectory(
                at: info, withIntermediateDirectories: true, attributes: NTMSRepository.internalDirAttributes)
        }
        return info
    }

    /// Writes a file of the store as git would: replaced whole, owner-only.
    private func writeOwnedFile(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
