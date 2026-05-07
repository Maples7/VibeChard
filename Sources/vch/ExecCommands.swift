import ArgumentParser
import Foundation
import VibeChardCore

// MARK: - vch exec

/// `vch exec <name> -- <cmd...>` — fork+wait an arbitrary command
/// inside a task's isolated worktree, with the M2 shim pre-installed
/// on PATH and isolation env vars set. Foreground only (per Q6/B1).
struct ExecCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "exec",
        abstract: "Run a command inside a task's isolated worktree."
    )

    @Argument(help: "Task name to enter.",
              completion: .custom(TaskNameCompletion.candidates))
    var name: String

    @Argument(parsing: .captureForPassthrough,
              help: "Command (and its args) to run. Use `--` to separate from vch flags.")
    var command: [String] = []

    func run() throws {
        try CLIBridge.run {
            let task = try TaskName(name)
            let cwd = FileManager.default.currentDirectoryPath
            let workspace = try WorkspaceLocator.locate(cwd: cwd)
            let env = ProcessInfo.processInfo.environment

            let shimPath = try Self.resolveShimPath(env: env)

            let service = ExecService(workspace: workspace, git: DiskGitClient())
            let plan = try service.prepare(
                task: task,
                command: command,
                shimPath: shimPath,
                baseEnv: env
            )

            // Replace vch with the child via `execve` — see
            // `PlanLauncher.runReplacing` for the rationale (interactive
            // shell needs the controlling tty + default ^C handling).
            PlanLauncher.runReplacing(plan)
        }
    }

    static func resolveShimPath(env: [String: String]) throws -> String {
        let vchPath = ShimLocator.currentExecutablePath()
        guard let shim = ShimLocator.locate(vchExecutablePath: vchPath, env: env) else {
            throw VibeChardError.externalCommandFailed(
                cmd: "locate vch-xcodebuild-shim",
                exitCode: 1,
                stderr: "couldn't find \(ShimLocator.binaryName) next to \(vchPath) "
                    + "or in ../libexec; set VCH_SHIM_PATH to override"
            )
        }
        return shim
    }
}

/// Run an `ExecPlan` and return the child's exit code (or 128+signal
/// if it died from a signal). Implementation lives in
/// `PlanLauncher.run` so M4 (`vch build` / `vch test`) shares it.

// MARK: - vch shellenv

struct ShellEnvCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shellenv",
        abstract: "Print eval-able shell helpers (vch_cd, vch_new, vch_clean)."
    )

    func run() throws {
        print(ShellEnvScript.zshBash)
    }
}

// MARK: - `vch <name>` sugar dispatcher

/// Implements the `vch <name>` shorthand documented in Q9 (entry 5):
/// equivalent to `vch exec <name> -- $SHELL`.
///
/// Implementation strategy: `VchCLI.main()` peeks at `argv[1]` and, if
/// it's an unrecognized non-flag token, rewrites the argv to `["exec",
/// <name>, "--", $SHELL]` *before* handing off to the standard
/// ArgumentParser dispatch. This keeps the rest of the CLI surface
/// (and its `--help`) identical.
enum TaskShortcutDispatcher {

    /// Reserved subcommand tokens (matches Q4.5 + this CLI's actual
    /// registered subcommands).
    private static let knownSubcommands: Set<String> = [
        "version", "new", "list", "ls", "path", "remove", "rm", "repair",
        "exec", "shellenv", "open", "state", "completions",
        // Reserved for future milestones (so we don't accidentally
        // treat them as task names today and break later).
        "build", "test", "logs", "sim", "doctor",
        "help",
    ]

    /// Returns a rewritten argv if the input is a sugar invocation,
    /// otherwise nil. `arguments` should NOT include argv[0] (vch
    /// itself); pass `Array(CommandLine.arguments.dropFirst())`.
    static func rewriteIfSugar(_ arguments: [String], env: [String: String]) -> [String]? {
        guard let first = arguments.first else { return nil }
        if first.hasPrefix("-") { return nil }
        if knownSubcommands.contains(first) { return nil }
        // Validation deferred to TaskName; if user typed gibberish it
        // surfaces as a familiar `invalidTaskName` error.

        let shell = env["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = (shell?.isEmpty == false) ? shell! : "/bin/zsh"

        // Forward any extra args after the task name as additional
        // shell args (rare, but harmless).
        var rewritten = ["exec", first, "--", target]
        rewritten.append(contentsOf: arguments.dropFirst())
        return rewritten
    }
}
