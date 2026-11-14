import Foundation

/// How a role's git TOOLS run git (F6 S2, D-M19, 2026-11-12): with every channel through which
/// the repository itself names a command switched off.
///
/// The `git_*` tools run `/usr/bin/git` OUTSIDE the bash sandbox, with the person's own rights.
/// A role that writes a file of the work tree a hook runs (`pre-commit` calling a script of the
/// tree, husky, lefthook) or that sets a repository option the sandbox does not cover would have
/// the NEXT `git_commit` run it unconfined. So each call carries:
/// - `core.hooksPath=/dev/null` — no hook runs. A role's commit is not the person's: the person's
///   own commits, outside NanoTeams, run their hooks as before;
/// - `core.fsmonitor=false` — `core.fsmonitor` is a shell command git runs on `status`;
/// - `submodule.recurse=false` — a submodule's own config and hooks are not reached;
/// - for the subcommands that print a diff (`diff`, `log`, `show`), `--no-ext-diff --no-textconv`
///   right after the subcommand: an external diff driver or a `textconv` filter named by
///   `.gitattributes` is a command too.
///
/// One seam, so a new git tool cannot forget it: every `Git*Handlers` call goes through
/// `ProcessRunner.runRoleGit`, pinned by `RoleGitInvocationTests`.
nonisolated enum RoleGitInvocation {
    /// The `-c` options every role git call starts with.
    static let hardeningOptions: [String] = [
        "-c", "core.hooksPath=/dev/null",
        "-c", "core.fsmonitor=false",
        "-c", "submodule.recurse=false",
    ]

    /// Subcommands that print a diff, and so would run a diff driver or a textconv filter.
    static let diffPrintingSubcommands: Set<String> = ["diff", "log", "show"]

    /// `arguments` as a role's git tool must run them.
    static func arguments(_ arguments: [String]) -> [String] {
        var result = arguments
        if let subcommand = result.first, diffPrintingSubcommands.contains(subcommand) {
            result.insert(contentsOf: ["--no-ext-diff", "--no-textconv"], at: 1)
        }
        return hardeningOptions + result
    }
}

extension ProcessRunner {
    /// Runs git for a role's git tool — `runGit` with `RoleGitInvocation`'s options.
    nonisolated static func runRoleGit(
        _ arguments: [String],
        in directory: URL,
        timeout: TimeInterval = 60
    ) throws -> Result {
        try runGit(RoleGitInvocation.arguments(arguments), in: directory, timeout: timeout)
    }
}
