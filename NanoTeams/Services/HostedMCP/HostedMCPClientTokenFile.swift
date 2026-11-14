import Darwin
import Foundation

/// The file through which NanoTeams hands an agent its token: written when the token is issued
/// or reissued, removed when the agent is revoked, read by the `--mcp-stdio` bridge
/// (`HostedMCPStdioRelay.readTokenFile`) — or by a client that takes a token from a file. One
/// file per agent, in one folder, whatever the client: until 2026-11-09 the folder and the
/// format were a property of the client picked when the agent was added (a headers file for
/// Claude Code's helper, a bare token for Claude Desktop's bridge, nothing for the rest), which
/// tied the app to each client's configuration format — knowledge that rots on other people's
/// release schedules and that nothing here could verify (DEBTS D-M6).
///
/// `~/.config/nanoteams/<id>.token`: a path with no space in it, so the bridge's
/// `--token-file` argument pastes into any client's configuration unquoted; not `~/.nanoteams`,
/// which is the per-work-folder metadata directory's name — a person who opens `~` as a work
/// folder would find the tokens inside it. `SeatbeltSandbox.externalAgentTokenLocations` denies
/// the folder to every role's `bash` in EVERY profile — reads and writes, whatever Settings →
/// Bash grants, the credential-store toggle included, External Agents on or off — and
/// `SandboxPathResolver` hides it from the file tools (#375). Folder `0700`, file `0600`, written
/// to a temporary file in the same folder and renamed over the old one, so a reader sees the
/// old token or the new one, never half of either; a `.gitignore` of `*` goes in beside it,
/// because `~/.config` is a directory people keep in a dotfiles repository.
nonisolated struct HostedMCPClientTokenFile: Sendable {
    /// The home folder the token folder is under: the person's own in the app
    /// (`HostedMCPEnvironment.live`), a temporary folder everywhere else.
    let home: URL

    /// The token folder, relative to the home folder.
    static let folderRelativePath = ".config/nanoteams"

    /// What a token file is called after the agent's id.
    static let fileExtension = "token"

    /// The folder every token file lives in. Nothing but NanoTeams-written tokens lives in it,
    /// so the sandbox and the file tools keep it from every role unconditionally
    /// (`SeatbeltSandbox.externalAgentTokenLocations`).
    static func folder(home: URL) -> URL {
        home.appendingPathComponent(folderRelativePath, isDirectory: true)
    }

    /// Where the file for `shortID` lives, or `nil` for an id that is not the store's eight hex
    /// digits: it would be a path component of the person's choosing.
    static func location(shortID: String, home: URL) -> URL? {
        guard isValidShortID(shortID) else { return nil }
        return folder(home: home).appendingPathComponent("\(shortID).\(fileExtension)", isDirectory: false)
    }

    /// What the file holds: the bare token and a newline, which is what the bridge reads
    /// (`HostedMCPStdioRelay.readTokenFile` trims it).
    static func contents(token: String) -> Data {
        Data((token + "\n").utf8)
    }

    static func isValidShortID(_ shortID: String) -> Bool {
        shortID.utf8.count == HostedMCPConstants.shortIDCharacterCount && HostedMCPHex.isDigits(shortID)
    }

    /// Writes `token` for `shortID` and returns where. Throws when the id names no file, or when
    /// the folder or the file cannot be written.
    @discardableResult
    func write(token: String, shortID: String) throws -> URL {
        guard let url = Self.location(shortID: shortID, home: home) else {
            throw HostedMCPClientTokenFileError.invalidAgentID
        }
        let folder = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // A folder that existed already keeps its mode through `createDirectory`.
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        } catch {
            throw HostedMCPClientTokenFileError.folderNotWritable(Self.displayPath(folder, home: home))
        }
        // `~/.config` is commonly versioned, and a `git add -A` there would commit the bearer.
        // Best effort: a folder that cannot take the marker still takes the token, which is the
        // thing the person asked for.
        let ignore = folder.appendingPathComponent(".gitignore", isDirectory: false)
        if !FileManager.default.fileExists(atPath: ignore.path) {
            try? Data("*\n".utf8).write(to: ignore, options: [.atomic])
        }

        let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw HostedMCPClientTokenFileError.fileNotWritable(Self.displayPath(url, home: home))
        }
        // One write-all loop in the app, and it is the tested one (`VerifiedFileTests` drives
        // its failure through a pipe with no reader).
        let wroteAll = VerifiedFile.writeAll(Self.contents(token: token), to: descriptor) == nil && fsync(descriptor) == 0
        close(descriptor)
        guard wroteAll, rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw HostedMCPClientTokenFileError.fileNotWritable(Self.displayPath(url, home: home))
        }
        return url
    }

    /// Removes the file for `shortID`, if there is one. A file already gone is not an error, and
    /// an id that names no file has none to remove.
    func remove(shortID: String) throws {
        guard let url = Self.location(shortID: shortID, home: home) else { return }
        if unlink(url.path) != 0, errno != ENOENT {
            throw HostedMCPClientTokenFileError.fileNotRemovable(Self.displayPath(url, home: home))
        }
    }

    /// `url` as a person reads it: under `home` as `~/…`.
    static func displayPath(_ url: URL, home: URL) -> String {
        let path = url.path
        let homePath = home.path
        guard path.hasPrefix(homePath + "/") else { return path }
        return "~" + path.dropFirst(homePath.count)
    }
}

/// Why a token file could not be written or removed — said to the person in the Add agent sheet
/// and the External Agents page. Our own English; never a foreign error's text.
nonisolated enum HostedMCPClientTokenFileError: Error, LocalizedError, Sendable, Equatable {
    /// The agent's id is not the store's eight hex digits, so it names no file.
    case invalidAgentID
    case folderNotWritable(String)
    case fileNotWritable(String)
    case fileNotRemovable(String)

    var message: String {
        switch self {
        case .invalidAgentID: "The agent's id names no token file."
        case .folderNotWritable(let path): "Could not create \(path)."
        case .fileNotWritable(let path): "Could not write \(path)."
        case .fileNotRemovable(let path): "Could not remove \(path)."
        }
    }

    var errorDescription: String? { message }
}

/// A token as it was handed over: the issued agent, and whether its file took the token. The
/// token itself rides in `agent` either way — a client that sends it in a header copies it from
/// the sheet, once; the bridge reads the file.
nonisolated struct HostedMCPTokenHandoff: Sendable, Equatable {
    nonisolated enum Delivery: Sendable, Equatable {
        /// NanoTeams wrote the token to its file.
        case written(URL)
        /// Writing the file failed: the bridge cannot connect until a reissue writes it, and the
        /// token on the sheet is the only copy there is.
        case notWritten(URL, reason: String)
    }

    let agent: HostedMCPIssuedAgent
    let delivery: Delivery
}
