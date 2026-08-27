import Foundation

/// Tunables for the `bash` command-execution tool and its permission layer.
/// Pure value namespace — no UI, no isolation.
nonisolated enum BashConstants {

    // MARK: - Timeouts

    /// Default per-command wall-clock timeout (ms) when the LLM omits `timeout`.
    /// Mirrors the Claude Code Bash tool default (120 s). The schema accepts the
    /// value in milliseconds; `BashArguments.resolveTimeoutSeconds` converts to
    /// seconds for `ProcessRunner`.
    static let defaultTimeoutMilliseconds = 120_000
    /// Hard ceiling (ms) for a single foreground command. A larger requested
    /// timeout is clamped to this.
    static let maxTimeoutMilliseconds = 600_000

    // MARK: - Policy defaults

    /// Default execution mode for a freshly-configured work folder.
    /// `.manual` (every command — read-only, allow-rule, and prior "always"
    /// matches included — pauses for explicit human approval; only deny rules
    /// block silently) is the safest interactive default. `bash` is granted by
    /// default to the code-writing roles (Software Engineer, Coding Assistant,
    /// Coding Agent), so this confirm-everything posture plus the sandbox
    /// (`defaultSandboxEnabled`) is the out-of-the-box safety net: nothing runs
    /// until you say so. Loosening to `.semiAutomatic` (read-only / previously
    /// allowed commands run unattended) or `.auto` (the judge decides) is one
    /// click away.
    ///
    /// Applies to FRESH configs only — a work folder that already stored a mode
    /// keeps it (a legacy `"manual"` raw value still decodes to `.semiAutomatic`,
    /// not this always-confirm `.manual`).
    static let defaultMode: BashExecutionMode = .manual
    static let defaultRestrictionLevel: BashRestrictionLevel = .standard
    /// Sandbox is on by default; the unsandboxed fallback and autonomous
    /// auto-approval are both off by default (explicit opt-in).
    static let defaultSandboxEnabled = true

    // MARK: - Shell

    /// Fallback login shell when `$SHELL` is empty or not executable. zsh is the
    /// macOS default and reads `~/.zshrc` under `-l`, so the user's real PATH
    /// (Homebrew, asdf, nvm, etc.) is available — `/bin/bash` on macOS is the
    /// frozen 3.2 build that only reads `~/.bash_profile`.
    static let fallbackShell = "/bin/zsh"

    /// Path to the system Seatbelt sandbox wrapper.
    static let sandboxExecPath = "/usr/bin/sandbox-exec"

    /// Cap on retained background-command records (and their log files) PER TASK.
    /// When a task's new background command pushes ITS count above this, that
    /// task's OLDEST finished records are evicted (running ones are never dropped;
    /// other tasks are never touched). Bounds accumulation for a long-lived chat
    /// task that never closes; the per-task / per-folder teardown clears the rest.
    static let maxRetainedBackgroundCommands = 50

    // MARK: - Read-only bypass

    /// Program basenames that only inspect state and never mutate the filesystem
    /// or spawn arbitrary children. When EVERY segment of a (possibly compound)
    /// command resolves to one of these AND the command contains no output
    /// redirection, the permission layer short-circuits to `.allow` — no judge
    /// call, no human approval. Deliberately conservative: a program omitted here
    /// merely takes the normal (judge / approval) path, which is still safe.
    ///
    /// What must NEVER be in here is stated by the two sets below rather than by
    /// this comment. It used to be prose ("excludes `find -delete`, `sed -i`,
    /// `awk system()`, `xargs`, `tee`, `sort -o`") and the prose is what drifted:
    /// on 2026-08-25 the set contained FOUR programs the prose already forbade in
    /// spirit — `command` and `arch` (measured: `arch -arm64 /bin/sh -c …` runs an
    /// arbitrary child), and `rg`/`ripgrep` (`--pre=COMMAND`, which ripgrep's own
    /// help describes as spawning "a process for every file that is searched") —
    /// plus `yq`, which writes in place with `-i` and no redirect. Membership is
    /// now a testable disjointness, not a promise (`BashPermissionServiceTests`,
    /// MARK "Read-only set membership").
    ///
    /// Two entries left on the evidence rule (#85/#87 — silence is not a yes):
    /// `bat` (`--pager <command>`) and `tree` (`-o file`) could not be probed on
    /// the machine of record because neither is installed, and membership requires
    /// POSITIVE evidence of safety. `ripgrep` was additionally never a program
    /// name at all — the binary is `rg` — which is the tell that this set was
    /// assembled from memory rather than from `--help` output.
    ///
    /// Kept with a recorded reason, so the next audit does not re-litigate them:
    /// `date` and `hostname` can set system state but only as root, and this
    /// process is never root; `jq` has no exec primitive and no in-place flag.
    static let readOnlyPrograms: Set<String> = [
        "ls", "pwd", "echo", "cat", "head", "tail", "wc", "nl", "tac", "rev",
        "grep", "egrep", "fgrep", "rg",
        "which", "type", "file", "stat", "basename", "dirname",
        "realpath", "readlink", "du", "df",
        "date", "cal", "whoami", "id", "hostname", "uname", "uptime",
        "printenv", "locale", "tty",
        "cut", "tr", "column", "fold", "expand", "unexpand", "paste",
        "jq", "diff", "comm", "cmp",
        "sw_vers", "ps", "true", "false",
    ]

    /// Programs whose non-flag argv TAIL is itself a command line.
    ///
    /// Two consequences, and they fail through different code:
    ///  1. None of these may sit in `readOnlyPrograms` — the read-only bypass
    ///     decides by program NAME, and for a wrapper the name says nothing about
    ///     what runs.
    ///  2. A deny rule must see THROUGH them. Rules match against the leading
    ///     program of each segment, so without `BashPermissionService.denySegments`
    ///     a user's `rm` deny rule misses `command rm -rf x` — and that half is
    ///     mode-independent, i.e. it reaches the `.manual` default too.
    ///
    /// The membership rule is applicable rather than enumerable: *does the argv
    /// tail become a command line?* That admits `sudo`/`env`/`timeout` (which
    /// `leadingProgram` already declines to strip, for exactly this reason) and
    /// deliberately excludes `git`/`make`/`npm` — those can execute things too,
    /// but not through their argv tail, and admitting them would make the
    /// bare-allow-rule carve-out in `BashPermissionService` far too broad.
    static let commandWrappers: Set<String> = [
        "command", "builtin", "exec", "eval",
        "sudo", "doas", "su", "env",
        "xargs", "parallel", "find", "awk",
        "nice", "nohup", "timeout", "stdbuf", "setsid", "caffeinate", "time", "watch",
        "arch", "chroot", "script", "open", "osascript", "ssh",
        "sh", "bash", "zsh", "dash", "ksh", "fish",
    ]

    /// Programs that stay in `readOnlyPrograms` only while their argv carries
    /// nothing but recognised flags — the value is that allowlist.
    ///
    /// `rg` is the whole reason this exists. Its `--pre=COMMAND` makes it a command
    /// wrapper (ripgrep's own help: "ripgrep will unconditionally spawn a process
    /// for every file that is searched"), so by the rule above it would have to
    /// leave the read-only set entirely — and `rg` is among the most frequent
    /// commands a coding role issues, so that means an approval prompt on nearly
    /// every search in Semi-automatic. Gating on arguments keeps the common case
    /// fast without keeping the hole.
    ///
    /// The allowlist FAILS CLOSED, and that is the whole design: a flag ripgrep
    /// gains in some future release is unknown here, so it is not read-only, so the
    /// command goes to review. The inverse shape — a denylist of `--pre` and
    /// friends — reopens the hole silently the first time upstream adds an
    /// exec-capable flag, which is the failure mode this project already refused
    /// once when it declined an exit-code allowlist in the sandbox layer.
    ///
    /// Long flags are matched up to `=`, so `--pre=sh` is tested as `--pre`.
    /// Bundled short flags (`-ni`) are split per character by the checker.
    static let flagGatedReadOnlyPrograms: [String: Set<String>] = [
        "rg": [
            "-i", "-n", "-l", "-w", "-c", "-v", "-e", "-F", "-s", "-S", "-x", "-o",
            "-A", "-B", "-C", "-m", "-g", "-t", "-T", "-u", "-h", "-V", "-p", "-q",
            "--ignore-case", "--line-number", "--no-line-number", "--files-with-matches",
            "--files-without-match", "--word-regexp", "--count", "--count-matches",
            "--invert-match", "--regexp", "--fixed-strings", "--case-sensitive",
            "--smart-case", "--line-regexp", "--only-matching", "--after-context",
            "--before-context", "--context", "--max-count", "--glob", "--iglob",
            "--type", "--type-not", "--type-list", "--unrestricted", "--hidden",
            "--no-ignore", "--follow", "--max-depth", "--max-filesize", "--multiline",
            "--multiline-dotall", "--json", "--stats", "--color", "--colors",
            "--heading", "--no-heading", "--column", "--byte-offset", "--vimgrep",
            "--null", "--sort", "--sortr", "--threads", "--help", "--version",
            "--quiet", "--with-filename", "--no-filename", "--path-separator",
            "--binary", "--text", "--encoding", "--crlf", "--engine", "--pcre2",
            "--trim", "--field-match-separator", "--field-context-separator",
        ],
    ]

    /// Programs that mutate state with no `>` anywhere on the line, so the
    /// read-only bypass's redirection check cannot see them. None of these may sit
    /// in `readOnlyPrograms`, and `BashPermissionService` names the offender in its
    /// `.ask` reason so the human on the approval card learns WHY a
    /// harmless-looking command stopped short-circuiting.
    static let writesWithoutRedirection: Set<String> = [
        "yq", "sed", "tee", "sort", "bat", "tree",
        "curl", "wget", "install", "ditto", "rsync",
    ]

    /// Shell metacharacters that split a command line into independently-evaluated
    /// segments. The permission layer extracts the leading program from each
    /// segment so a benign-looking `cat x && rm -rf /` can't smuggle a denied
    /// program past a rule that only inspected the first word.
    static let segmentSeparators: Set<Character> = [";", "&", "|", "\n"]
}
