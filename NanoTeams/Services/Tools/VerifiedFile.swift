import Darwin
import Foundation

/// File I/O for the role's file tools that decides on what the kernel actually OPENED, not on
/// the name it checked a moment before (#377).
///
/// `SandboxPathResolver` judges a path by its real location — but a role's `bash` may keep a
/// background command swapping a name between a regular file and a link, and a check on the
/// name followed by an open of the name can land on either side of the swap. So every read here
/// opens first, asks the kernel where the descriptor really points (`F_GETPATH`), and reads only
/// when the resolver permits THAT path; every write creates a temporary file inside a directory
/// it holds open and has verified, then renames it into place within that same directory — a
/// link swapped in for the directory or the file changes nothing the write touches.
///
/// Every failure keeps the kernel's own `errno` (`ToolErrorHandler.classify` already turns 2,
/// 13, 21 and 28 into their own sentences): flattening them into one Cocoa code told a role its
/// PATH was invalid when the disk was full, and said "File not found." about a file it had just
/// listed.
nonisolated enum VerifiedFile {

    /// The real path of the file or directory `descriptor` names, as the kernel resolved it when
    /// it was opened — links followed then, not now.
    ///
    /// Normalised through `SandboxPathResolver.canonicalPath` before anyone compares it, because
    /// the two oracles are NOT the same function: across a macOS firmlink `F_GETPATH` answers
    /// `/Users/…` where `realpath` keeps `/System/Volumes/Data/Users/…`, and the resolver's root
    /// and hidden locations are all `realpath` output. Left unreconciled, a work folder opened by
    /// its `/System/Volumes/Data` spelling answered "File not found." for every file in it.
    static func realPath(of descriptor: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) != -1 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return SandboxPathResolver.canonicalPath(String(decoding: bytes, as: UTF8.self))
    }

    /// A read-only handle on `url`, verified AFTER the open: what the kernel resolved must be a
    /// regular file `resolver` permits, or this throws "File not found" as any hidden location
    /// does. The caller reads from the handle, never from the path again.
    ///
    /// `O_NONBLOCK` is load-bearing and free: a read-only `open` of a FIFO waits for a writer
    /// FOREVER, so one `mkfifo notes.md` in the work folder would hang `read_file`, `edit_file`,
    /// `analyze_image` and the vocabulary index on a thread nothing can interrupt — while for
    /// the regular file that is the only kind this returns, the flag changes nothing.
    static func openForReading(_ url: URL, resolver: SandboxPathResolver) throws -> FileHandle {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard let real = realPath(of: descriptor), resolver.permits(canonicalPath: real) else {
            try? handle.close()
            throw SandboxPathError.restrictedPath
        }
        // Separate from the refusal above on purpose: "this is a directory" is a fact about the
        // file and reads as one, while `restrictedPath` is this sandbox's answer and must not be
        // spent on anything else — `search` reports the two differently.
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            try? handle.close()
            throw VerifiedFileError.notARegularFile
        }
        return handle
    }

    /// Reads `url` whole through a verified handle.
    static func readData(_ url: URL, resolver: SandboxPathResolver) throws -> Data {
        let handle = try openForReading(url, resolver: resolver)
        defer { try? handle.close() }
        return try handle.readToEnd() ?? Data()
    }

    /// Where a path-taking reader — the document extractors, which open the name themselves and
    /// keep an mtime/size cache keyed on it — should be pointed instead of at the name the model
    /// wrote: the same file's REAL path, checked against `resolver`.
    ///
    /// Strictly stronger than checking the written name and then opening it, because a real path
    /// holds no symlink to flip: every component of it is the thing itself. Weaker than a
    /// descriptor, which is why it is only for the readers that cannot take one — the residual
    /// is a real directory REPLACED by a link between this call and the open, which costs the
    /// attacker the directory.
    ///
    /// An RTFD bundle is a DIRECTORY whose text lives in an inner file the extractor opens by
    /// name, so a link planted at that name read an arbitrary RTF document from anywhere on
    /// disk — no race needed. The inner document is judged here too, at the one seam that owns
    /// the question.
    static func verifiedRealURL(_ url: URL, resolver: SandboxPathResolver) throws -> URL {
        let real = SandboxPathResolver.canonicalPath(url.path)
        guard resolver.permits(canonicalPath: real) else { throw SandboxPathError.restrictedPath }
        if url.pathExtension.lowercased() == "rtfd" {
            let document = (real as NSString).appendingPathComponent("TXT.rtf")
            guard resolver.permits(canonicalPath: SandboxPathResolver.canonicalPath(document))
            else { throw SandboxPathError.restrictedPath }
        }
        return URL(fileURLWithPath: real)
    }

    /// Writes `data` to `url` atomically: into a new temporary file inside `url`'s directory,
    /// opened and verified as a descriptor, then renamed over `url` in that same directory. A
    /// file that existed keeps its permissions; one that did not gets the usual ones.
    static func writeAtomically(_ data: Data, to url: URL, resolver: SandboxPathResolver) throws {
        let name = url.lastPathComponent
        let directory = try openVerifiedDirectory(containing: url, resolver: resolver)
        defer { close(directory) }

        var existing = stat()
        let keepsMode = fstatat(directory, name, &existing, AT_SYMLINK_NOFOLLOW) == 0
            && (existing.st_mode & S_IFMT) == S_IFREG
        // Independent of the target's name: `.<name>.nanoteams-<uuid>.tmp` added 52 units to it,
        // so a legal 204-character file name overflowed NAME_MAX and `openat` refused it with
        // ENAMETOOLONG — the file became permanently unwritable. Uniqueness comes from the UUID
        // and from `O_EXCL` inside a directory this call holds open.
        let temporary = ".nanoteams-\(UUID().uuidString).tmp"
        let descriptor = openat(
            directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
        guard descriptor >= 0 else { throw posixError() }

        var failure = writeAll(data, to: descriptor)
        if failure == nil, keepsMode { fchmod(descriptor, existing.st_mode & 0o7777) }
        if failure == nil, fsync(descriptor) != 0 { failure = errno }
        close(descriptor)
        if let failure {
            unlinkat(directory, temporary, 0)
            throw posixError(failure)
        }
        guard renameat(directory, temporary, directory, name) == 0 else {
            let renameFailure = errno
            unlinkat(directory, temporary, 0)
            throw posixError(renameFailure)
        }
    }

    /// Removes the file `url` names, inside its verified directory. A link is removed as a
    /// link; a directory is refused (`removesFilesOnly`).
    static func removeFile(_ url: URL, resolver: SandboxPathResolver) throws {
        let directory = try openVerifiedDirectory(containing: url, resolver: resolver)
        defer { close(directory) }
        var info = stat()
        guard fstatat(directory, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw posixError()
        }
        guard (info.st_mode & S_IFMT) != S_IFDIR else { throw VerifiedFileError.isADirectory }
        guard unlinkat(directory, url.lastPathComponent, 0) == 0 else { throw posixError() }
    }

    /// Opens `url`'s directory and verifies what it opened: inside the work folder, not hidden —
    /// and the entry about to be written there, by its real name, not hidden or an agent's
    /// configuration either.
    private static func openVerifiedDirectory(containing url: URL, resolver: SandboxPathResolver) throws -> Int32 {
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw posixError() }
        guard let realDirectory = realPath(of: directory),
              resolver.permits(canonicalPath: realDirectory)
        else {
            close(directory)
            throw SandboxPathError.restrictedPath
        }
        let realEntry = (realDirectory as NSString).appendingPathComponent(url.lastPathComponent)
        guard resolver.permits(canonicalPath: realEntry) else {
            close(directory)
            throw SandboxPathError.restrictedPath
        }
        guard !resolver.isAgentConfiguration(canonicalPath: realEntry) else {
            close(directory)
            throw SandboxPathError.agentConfiguration(url.lastPathComponent)
        }
        guard !resolver.isRepositoryControl(canonicalPath: realEntry) else {
            close(directory)
            throw SandboxPathError.repositoryControlDirectory
        }
        return directory
    }

    /// Writes every byte of `data` to `descriptor`, resuming after an interrupted call.
    /// `nil` when all of it landed, else the `errno` that stopped it — a short write is a
    /// FAILURE here, not a partial success, because the caller renames the result into place.
    ///
    /// Its own function so the failure can be exercised: a descriptor that refuses is a pipe
    /// whose reader is gone (EPIPE), which needs no full disk.
    static func writeAll(_ data: Data, to descriptor: Int32) -> Int32? {
        data.withUnsafeBytes { buffer -> Int32? in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                offset += count
            }
            return nil
        }
    }

    /// The kernel's own reason, kept whole. `ToolErrorHandler.classify` turns ENOENT, EACCES,
    /// EISDIR and ENOSPC into their own sentences and prints domain+code for everything else,
    /// which is strictly better than one Cocoa code standing in for all of them.
    private static func posixError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}

/// What `VerifiedFile` refuses for a reason that is not a sandbox rule — a fact about the file,
/// said in our own English (`ToolErrorHandler.classify` passes a `LocalizedError` through).
nonisolated enum VerifiedFileError: Error, LocalizedError, Equatable {
    case isADirectory
    case notARegularFile

    var errorDescription: String? {
        switch self {
        case .isADirectory: "Path is a directory."
        case .notARegularFile: "not a regular file"
        }
    }
}
