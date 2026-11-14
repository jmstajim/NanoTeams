import XCTest
@testable import NanoTeams

/// Reads and writes that decide on what the kernel actually OPENED (#376, review 2026-11-08).
///
/// The resolver judges a path and hands back the name it was given; every tool then resolved
/// that name again. Two lookups, with a role's background `bash` free to flip a link in between —
/// so a read goes through a descriptor whose real path is re-checked after the open, and a write
/// happens inside a directory held open and verified.
final class VerifiedFileTests: XCTestCase {
    private let fm = FileManager.default
    private var base: URL!
    private var home: URL!
    private var work: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = fm.temporaryDirectory.appendingPathComponent("nt-verified-\(UUID().uuidString)", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        work = base.appendingPathComponent("work", isDirectory: true)
        outside = base.appendingPathComponent("outside", isDirectory: true)
        for folder in [home!, work!, outside!] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        if let base { try? fm.removeItem(at: base) }
        base = nil; home = nil; work = nil; outside = nil
        try super.tearDownWithError()
    }

    private var resolver: SandboxPathResolver {
        SandboxPathResolver(workFolderRoot: work, internalDir: nil, home: home)
    }

    private func write(_ text: String, _ relative: String, under root: URL? = nil) throws -> URL {
        let url = (root ?? work).appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Reads

    func testReadData_readsARegularFileInsideTheWorkFolder() throws {
        let url = try write("hello", "a.txt")
        XCTAssertEqual(String(decoding: try VerifiedFile.readData(url, resolver: resolver), as: UTF8.self), "hello")
    }

    func testReadData_emptyFile_isEmptyNotAFailure() throws {
        let url = try write("", "empty.txt")
        XCTAssertEqual(try VerifiedFile.readData(url, resolver: resolver), Data())
    }

    /// The point of verifying AFTER the open: the name says nothing. Here the name is a link out
    /// of the work folder, which no caller should pass — and if one does, the descriptor refuses.
    func testReadData_throughALinkOutOfTheWorkFolder_isRefused() throws {
        _ = try write("secret", "secret.txt", under: outside)
        let link = work.appendingPathComponent("peek.txt")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside.appendingPathComponent("secret.txt"))
        XCTAssertThrowsError(try VerifiedFile.readData(link, resolver: resolver)) {
            guard case SandboxPathError.restrictedPath = $0 else { return XCTFail("\($0)") }
        }
    }

    func testReadData_aDirectory_isRefusedRatherThanReadAsBytes() throws {
        try fm.createDirectory(at: work.appendingPathComponent("sub"), withIntermediateDirectories: true)
        XCTAssertThrowsError(
            try VerifiedFile.readData(work.appendingPathComponent("sub"), resolver: resolver))
    }

    func testReadData_missingFile_isANotFoundError() {
        XCTAssertThrowsError(
            try VerifiedFile.readData(work.appendingPathComponent("nope.txt"), resolver: resolver)
        ) { error in
            // The kernel's own ENOENT, kept whole (#377) — `classify` turns it into the
            // sentence, and a permission fault keeps its own.
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(ENOENT))
            XCTAssertEqual(ToolErrorHandler.classify(error).code, .fileNotFound)
        }
    }

    func testRealPath_ofAnOpenDescriptor_isWhereTheKernelResolvedIt() throws {
        let target = try write("x", "real.txt")
        let link = work.appendingPathComponent("alias.txt")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        let descriptor = open(link.path, O_RDONLY)
        defer { close(descriptor) }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(
            VerifiedFile.realPath(of: descriptor), SandboxPathResolver.canonicalPath(target.path),
            "the descriptor names the target, not the link")
    }

    /// A read-only `open` of a FIFO waits for a writer FOREVER. One `mkfifo notes.md` in the
    /// work folder would hang `read_file`, `edit_file`, `analyze_image` and the vocabulary index
    /// on a thread nothing can interrupt — the regular-file guard never runs, because the block
    /// happens before it (review 2026-11-08). `O_NONBLOCK` makes the guard the answer.
    func testReadData_aFIFO_isRefusedAtOnceRatherThanWaitedOn() throws {
        let fifo = work.appendingPathComponent("notes.md")
        try XCTSkipUnless(mkfifo(fifo.path, 0o600) == 0, "mkfifo unavailable on this volume")
        let started = Date()
        XCTAssertThrowsError(try VerifiedFile.readData(fifo, resolver: resolver)) {
            XCTAssertEqual($0 as? VerifiedFileError, .notARegularFile)
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 2,
            "the open must not wait for a writer")
    }

    /// A file the process may not read answers with the OS's own distinction, not with the
    /// sandbox's "File not found." — which `restrictedPath` keeps for itself so a probe learns
    /// nothing about a hidden location.
    func testReadData_anUnreadableFile_saysPermissionDeniedNotFileNotFound() throws {
        let url = try write("secret", "locked.txt")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        XCTAssertThrowsError(try VerifiedFile.readData(url, resolver: resolver)) { error in
            let classified = ToolErrorHandler.classify(error)
            XCTAssertEqual(classified.code, .permissionDenied, classified.message)
        }
    }

    func testReadData_aMissingFile_saysFileNotFound() {
        XCTAssertThrowsError(
            try VerifiedFile.readData(work.appendingPathComponent("absent.txt"), resolver: resolver)
        ) { error in
            XCTAssertEqual(ToolErrorHandler.classify(error).code, .fileNotFound)
        }
    }

    // MARK: - The document readers' real path

    func testVerifiedRealURL_returnsTheRealPathAndRefusesAHiddenOne() throws {
        let target = try write("doc", "docs/real.rtf")
        let link = work.appendingPathComponent("alias.rtf")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(
            try VerifiedFile.verifiedRealURL(link, resolver: resolver).path,
            SandboxPathResolver.canonicalPath(target.path))

        _ = try write("TOKEN", ".config/nanoteams/a4c36525.token", under: home)
        let atHome = SandboxPathResolver(workFolderRoot: home, internalDir: nil, home: home)
        XCTAssertThrowsError(
            try VerifiedFile.verifiedRealURL(
                home.appendingPathComponent(".config/nanoteams/a4c36525.token"), resolver: atHome))
    }

    // MARK: - Writes

    func testWriteAtomically_createsAndOverwrites() throws {
        let url = work.appendingPathComponent("out.txt")
        try VerifiedFile.writeAtomically(Data("one".utf8), to: url, resolver: resolver)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one")
        try VerifiedFile.writeAtomically(Data("two".utf8), to: url, resolver: resolver)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "two")
    }

    /// A file that existed keeps its permissions — an executable script stays executable.
    func testWriteAtomically_keepsAnExistingFilesMode() throws {
        let url = try write("#!/bin/sh\necho hi\n", "script.sh")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try VerifiedFile.writeAtomically(Data("#!/bin/sh\necho bye\n".utf8), to: url, resolver: resolver)
        let mode = try XCTUnwrap(
            (try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue)
        XCTAssertEqual(mode & 0o777, 0o755)
    }

    func testWriteAtomically_leavesNoTemporaryFileBehind() throws {
        try VerifiedFile.writeAtomically(
            Data("x".utf8), to: work.appendingPathComponent("out.txt"), resolver: resolver)
        let entries = try fm.contentsOfDirectory(atPath: work.path)
        XCTAssertEqual(entries, ["out.txt"], "\(entries)")
    }

    /// The write goes into the directory it verified and is renamed over the NAME. A link that
    /// appeared under that name is replaced, never written through — so the file outside is safe
    /// even when the name was swapped after the resolver judged it.
    func testWriteAtomically_overALinkOut_replacesTheLinkRatherThanItsTarget() throws {
        let target = try write("original", "target.txt", under: outside)
        let link = work.appendingPathComponent("doc.txt")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        try VerifiedFile.writeAtomically(Data("replaced".utf8), to: link, resolver: resolver)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original")
        XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), "replaced")
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: link.path), "the link is gone")
    }

    /// The temporary name used to carry the target's own name, so 52 units were added to it and
    /// a legal 204-character file name overflowed NAME_MAX — `write_file` and `edit_file` then
    /// refused that file forever, with "Permission denied." naming neither cause nor repair.
    func testWriteAtomically_aMaximumLengthFileName_stillWrites() throws {
        let name = String(repeating: "n", count: 250) + ".txt"
        XCTAssertEqual(name.count, 254)
        let url = work.appendingPathComponent(name)
        try VerifiedFile.writeAtomically(Data("x".utf8), to: url, resolver: resolver)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "x")
    }

    func testWriteAtomically_insideAHiddenLocation_isRefused() throws {
        _ = try write("TOKEN", ".config/nanoteams/a4c36525.token", under: home)
        let atHome = SandboxPathResolver(workFolderRoot: home, internalDir: nil, home: home)
        XCTAssertThrowsError(
            try VerifiedFile.writeAtomically(
                Data("x".utf8),
                to: home.appendingPathComponent(".config/nanoteams/a4c36525.token"), resolver: atHome)
        ) {
            guard case SandboxPathError.restrictedPath = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(
            try String(contentsOf: home.appendingPathComponent(".config/nanoteams/a4c36525.token"), encoding: .utf8),
            "TOKEN")
    }

    func testWriteAtomically_anAgentConfiguration_isRefusedWithItsOwnReason() throws {
        _ = try write(#"{"mcpServers":{}}"#, ".mcp.json")
        XCTAssertThrowsError(
            try VerifiedFile.writeAtomically(
                Data("{}".utf8), to: work.appendingPathComponent(".mcp.json"), resolver: resolver)
        ) { error in
            guard case SandboxPathError.agentConfiguration(let name) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(name, ".mcp.json")
            XCTAssertTrue(
                error.localizedDescription.contains("configures a coding agent"),
                error.localizedDescription)
        }
        XCTAssertEqual(
            try String(contentsOf: work.appendingPathComponent(".mcp.json"), encoding: .utf8),
            #"{"mcpServers":{}}"#)
    }

    /// A file that merely LIVES in a client folder of the project is not its configuration: a
    /// skill body under `.claude/skills/` is ordinary project content.
    func testWriteAtomically_anOrdinaryFileInsideADotFolder_isAllowed() throws {
        let url = work.appendingPathComponent(".claude/skills/mine/SKILL.md")
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try VerifiedFile.writeAtomically(Data("# skill".utf8), to: url, resolver: resolver)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# skill")
    }

    // MARK: - The write loop itself

    /// Every byte lands, and an interrupted call resumes — asserted on a real descriptor.
    func testWriteAll_writesEveryByte() throws {
        let url = work.appendingPathComponent("bulk.bin")
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        let payload = Data(repeating: 0x41, count: 300_000)
        XCTAssertNil(VerifiedFile.writeAll(payload, to: descriptor))
        close(descriptor)
        XCTAssertEqual(try Data(contentsOf: url).count, payload.count)
    }

    /// A descriptor that refuses mid-write returns the kernel's own reason, not a flattened
    /// "unknown write error" — a pipe with no reader is EPIPE and needs no full disk (#382).
    func testWriteAll_whenTheDescriptorRefuses_returnsTheErrno() throws {
        signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, SIG_DFL) }
        var ends: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&ends), 0)
        close(ends[0])  // no reader
        let failure = VerifiedFile.writeAll(Data(repeating: 0x42, count: 1024), to: ends[1])
        close(ends[1])
        XCTAssertEqual(failure, EPIPE)
        XCTAssertEqual(
            ToolErrorHandler.classify(
                NSError(domain: NSPOSIXErrorDomain, code: Int(EPIPE))).code, .commandFailed)
    }

    // MARK: - Writes that cannot land

    /// A directory the process may not write: `openat` of the temporary file fails, and nothing
    /// is left behind.
    func testWriteAtomically_intoAReadOnlyDirectory_throwsAndLeavesNothing() throws {
        let locked = work.appendingPathComponent("locked", isDirectory: true)
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        XCTAssertThrowsError(
            try VerifiedFile.writeAtomically(
                Data("x".utf8), to: locked.appendingPathComponent("out.txt"), resolver: resolver))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: locked.path), [])
    }

    /// The rename cannot replace a DIRECTORY with a file, and the temporary file goes with it.
    func testWriteAtomically_overADirectoryName_throwsAndRemovesItsTemporary() throws {
        let occupied = work.appendingPathComponent("taken", isDirectory: true)
        try fm.createDirectory(at: occupied, withIntermediateDirectories: true)
        XCTAssertThrowsError(
            try VerifiedFile.writeAtomically(Data("x".utf8), to: occupied, resolver: resolver))
        XCTAssertTrue(fm.fileExists(atPath: occupied.path))
        let entries = try fm.contentsOfDirectory(atPath: work.path)
        XCTAssertEqual(entries.sorted(), ["taken"], "no temporary left behind: \(entries)")
    }

    func testWriteAtomically_withNoSuchDirectory_throwsNotFound() {
        XCTAssertThrowsError(
            try VerifiedFile.writeAtomically(
                Data("x".utf8), to: work.appendingPathComponent("absent/out.txt"), resolver: resolver))
    }

    /// The directory is permitted and the ENTRY is not: a credential store that is a single file
    /// (`~/.netrc`) inside a work folder at `~`.
    func testWriteAtomically_aHiddenEntryInAPermittedDirectory_isRefused() throws {
        _ = try write("machine example.com", ".netrc", under: home)
        let atHome = SandboxPathResolver(workFolderRoot: home, internalDir: nil, home: home)
        XCTAssertThrowsError(
            try VerifiedFile.writeAtomically(
                Data("x".utf8), to: home.appendingPathComponent(".netrc"), resolver: atHome)
        ) {
            guard case SandboxPathError.restrictedPath = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(
            try String(contentsOf: home.appendingPathComponent(".netrc"), encoding: .utf8),
            "machine example.com")
    }

    func testRemoveFile_inAReadOnlyDirectory_throws() throws {
        let locked = work.appendingPathComponent("locked", isDirectory: true)
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        let victim = locked.appendingPathComponent("keep.txt")
        try "x".write(to: victim, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        XCTAssertThrowsError(try VerifiedFile.removeFile(victim, resolver: resolver))
        XCTAssertTrue(fm.fileExists(atPath: victim.path))
    }

    /// An RTFD bundle is a DIRECTORY whose text lives in an inner `TXT.rtf` the extractor opens
    /// BY NAME. A link planted there read an arbitrary RTF document from anywhere on disk, with
    /// no race at all — so the inner document is judged too.
    func testVerifiedRealURL_anRTFDWhoseInnerDocumentLeavesTheWorkFolder_isRefused() throws {
        _ = try write(#"{\rtf1\ansi OUTSIDE-SECRET}"#, "private.rtf", under: outside)
        let bundle = work.appendingPathComponent("notes.rtfd", isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: bundle.appendingPathComponent("TXT.rtf"),
            withDestinationURL: outside.appendingPathComponent("private.rtf"))
        XCTAssertThrowsError(try VerifiedFile.verifiedRealURL(bundle, resolver: resolver)) {
            guard case SandboxPathError.restrictedPath = $0 else { return XCTFail("\($0)") }
        }

        // ...while an ordinary bundle still resolves.
        let ordinary = work.appendingPathComponent("ok.rtfd", isDirectory: true)
        try fm.createDirectory(at: ordinary, withIntermediateDirectories: true)
        _ = try write(#"{\rtf1\ansi INSIDE}"#, "ok.rtfd/TXT.rtf")
        XCTAssertEqual(
            try VerifiedFile.verifiedRealURL(ordinary, resolver: resolver).lastPathComponent,
            "ok.rtfd")
    }

    // MARK: - Removal

    func testRemoveFile_removesAFileAndRefusesADirectory() throws {
        let url = try write("x", "gone.txt")
        try VerifiedFile.removeFile(url, resolver: resolver)
        XCTAssertFalse(fm.fileExists(atPath: url.path))

        let directory = work.appendingPathComponent("sub", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertThrowsError(try VerifiedFile.removeFile(directory, resolver: resolver)) {
            XCTAssertEqual($0 as? VerifiedFileError, .isADirectory)
        }
        XCTAssertTrue(fm.fileExists(atPath: directory.path))
    }

    func testRemoveFile_missingFile_isANotFoundError() {
        XCTAssertThrowsError(
            try VerifiedFile.removeFile(work.appendingPathComponent("nope.txt"), resolver: resolver))
    }

    /// A link is removed AS a link: its target — which may be anywhere — is left alone.
    func testRemoveFile_removesTheLinkNotItsTarget() throws {
        let target = try write("keep", "target.txt", under: outside)
        let link = work.appendingPathComponent("alias.txt")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        try VerifiedFile.removeFile(link, resolver: resolver)
        XCTAssertFalse(fm.fileExists(atPath: link.path))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
    }
}
