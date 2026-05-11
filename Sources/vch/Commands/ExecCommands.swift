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

            let service = ExecService(
                workspace: workspace,
                git: DiskGitClient(),
                developerDir: XcodeSelectDeveloperDirResolver()
            )
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
