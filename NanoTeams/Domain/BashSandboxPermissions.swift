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

    /// The same grants with every WRITE scope off and every READ scope untouched.
    ///
    /// MONOTONE by construction: no field can go `false → true`, so the result is never wider
    /// than the receiver under any configuration. That is the property the caller leans on —
    /// it narrows the user's OWN settings rather than substituting a fixed profile, so someone
    /// who already turned writes off sees no change and someone who narrowed reads keeps that.
    ///
    /// Reads are deliberately untouched: the header above calls narrowing them a footgun (the
    /// shell needs broad reads to run anything at all), and the only reason to narrow writes is
    /// to stop MUTATION, which reads cannot cause.
    ///
    /// `tempWrite` goes off with the rest, and that is load-bearing rather than tidiness.
    /// `SeatbeltSandbox` emits the write allow-list as `(subpath …)` clauses and its narrow-write
    /// branch emits no work-folder deny, so a work folder living under `$TMPDIR` or
    /// `/private/tmp` stays writable through the TEMP grant even with `workFolderWrite: false` —
    /// a property `SeatbeltSandboxTests.testProfile_workFolderWriteOff_blocksInsideWrite` already
    /// works around by placing its fixture under HOME. With every scope off the write clause
    /// carries only the dev-node literals and `(deny default)` answers everything else, so "no
    /// writes" is checkable by reading the profile instead of by re-deriving a containment
    /// argument each time a scope is added.
    ///
    /// Credential writes need no mention: `SeatbeltSandbox` denies them unconditionally.
    func withWritesDisabled() -> BashSandboxPermissions {
        var narrowed = self
        narrowed.workFolderWrite = false
        narrowed.tempWrite = false
        narrowed.homeWrite = false
        narrowed.everythingElseWrite = false
        return narrowed
    }
}
