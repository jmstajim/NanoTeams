import Foundation

/// Per-folder read/write grants for the `bash` Seatbelt sandbox. `SeatbeltSandbox`
/// enforces them and the judge is told the confinement; the table is the single
/// source of truth for both.
///
/// The defaults reproduce the prior hardcoded profile exactly: reads broad,
/// writes confined to the work folder + temp dirs, credential reads blocked,
/// credential writes always blocked. So `BashSandboxPermissions()` passed to
/// `SeatbeltSandbox.profile` yields the confinement the tool shipped with.
///
/// Note: turning a READ off is a footgun — the shell needs broad reads (system
/// libraries, binaries, project files) to run almost anything, so narrowing reads
/// will stop most commands from working. Writes are the meaningful confinement.
///
/// IMPORTANT: like `BashPolicy`, this carries no credential and is freely
/// `Codable` (persisted to UserDefaults as JSON).
nonisolated struct BashSandboxPermissions: Codable, Hashable, Sendable {
    /// Reads of the project work folder. Default `true`.
    var workFolderRead: Bool
    /// Writes to the project work folder. Default `true`.
    var workFolderWrite: Bool
    /// Reads of temp directories. Default `true`.
    var tempRead: Bool
    /// Writes to temp directories. Default `true`.
    var tempWrite: Bool
    /// Reads of credential stores. Default `false` (secrets blocked).
    var credentialRead: Bool
    /// Reads of the user's home folder (`~`) outside the project, temp, and
    /// credential stores. Splitting it out of `everythingElse` lets the home folder
    /// be granted/denied independently of system paths. Default mirrors
    /// `everythingElseRead` when unset (pre-split, home was part of "everything else").
    var homeRead: Bool
    /// Writes to the user's home folder (`~`) outside work/temp/credentials. Default
    /// mirrors `everythingElseWrite` when unset. Credential writes stay blocked
    /// regardless.
    var homeWrite: Bool
    /// Reads of SYSTEM paths outside home/work/temp/credentials (`/usr`, `/Library`,
    /// `/etc`, binaries, system libs). Default `true` — the shell needs these to run
    /// commands.
    var everythingElseRead: Bool
    /// Writes to SYSTEM paths outside home/work/temp. Default `false`. Enabling it is
    /// the escape hatch — broad write of `/`; credential writes stay blocked.
    var everythingElseWrite: Bool

    init(
        workFolderRead: Bool = true,
        workFolderWrite: Bool = true,
        tempRead: Bool = true,
        tempWrite: Bool = true,
        credentialRead: Bool = false,
        homeRead: Bool? = nil,
        homeWrite: Bool? = nil,
        everythingElseRead: Bool = true,
        everythingElseWrite: Bool = false
    ) {
        self.workFolderRead = workFolderRead
        self.workFolderWrite = workFolderWrite
        self.tempRead = tempRead
        self.tempWrite = tempWrite
        self.credentialRead = credentialRead
        self.everythingElseRead = everythingElseRead
        self.everythingElseWrite = everythingElseWrite
        // Unset home grant inherits the system grant — before the split the home
        // folder rode inside "everything else", so this reproduces it exactly.
        self.homeRead = homeRead ?? everythingElseRead
        self.homeWrite = homeWrite ?? everythingElseWrite
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.workFolderRead = try c.decodeIfPresent(Bool.self, forKey: .workFolderRead) ?? true
        self.workFolderWrite = try c.decodeIfPresent(Bool.self, forKey: .workFolderWrite) ?? true
        self.tempRead = try c.decodeIfPresent(Bool.self, forKey: .tempRead) ?? true
        self.tempWrite = try c.decodeIfPresent(Bool.self, forKey: .tempWrite) ?? true
        self.credentialRead = try c.decodeIfPresent(Bool.self, forKey: .credentialRead) ?? false
        let everythingElseRead = try c.decodeIfPresent(Bool.self, forKey: .everythingElseRead) ?? true
        let everythingElseWrite = try c.decodeIfPresent(Bool.self, forKey: .everythingElseWrite) ?? false
        self.everythingElseRead = everythingElseRead
        self.everythingElseWrite = everythingElseWrite
        // Legacy JSON (pre-split) carries no home keys — inherit the system grant so
        // the decoded profile is byte-identical to what that config produced before.
        self.homeRead = try c.decodeIfPresent(Bool.self, forKey: .homeRead) ?? everythingElseRead
        self.homeWrite = try c.decodeIfPresent(Bool.self, forKey: .homeWrite) ?? everythingElseWrite
    }
}
