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
    /// Excludes anything that can write or execute (`find` with `-delete`/`-exec`,
    /// `sed -i`, `awk` `system()`, `xargs`, `tee`, `sort -o`).
    static let readOnlyPrograms: Set<String> = [
        "ls", "pwd", "echo", "cat", "bat", "head", "tail", "wc", "nl", "tac", "rev",
        "grep", "egrep", "fgrep", "rg", "ripgrep",
        "which", "type", "command", "file", "stat", "basename", "dirname",
        "realpath", "readlink", "du", "df",
        "date", "cal", "whoami", "id", "hostname", "uname", "uptime", "arch",
        "printenv", "locale", "tty",
        "cut", "tr", "column", "fold", "expand", "unexpand", "paste",
        "jq", "yq", "diff", "comm", "cmp", "tree",
        "sw_vers", "ps", "true", "false",
    ]

    /// Shell metacharacters that split a command line into independently-evaluated
    /// segments. The permission layer extracts the leading program from each
    /// segment so a benign-looking `cat x && rm -rf /` can't smuggle a denied
    /// program past a rule that only inspected the first word.
    static let segmentSeparators: Set<Character> = [";", "&", "|", "\n"]
}
