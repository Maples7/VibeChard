import ArgumentParser
import Foundation
import VibeChardCore

// MARK: - vch open

/// `vch open [<name>] [--with <ide>]` — launch an IDE on a task's
/// worktree. With no `<name>` and run from inside a vch-managed
/// worktree, the task is inferred from the cwd.
///
/// Auto-detects `.xcworkspace`/`.xcodeproj`/`Package.swift` to pick a
/// reasonable default (Xcode for project files, VS Code for SwiftPM-
/// only repos), but the user can always override with `--with` or
/// the `VCH_OPEN_DEFAULT` env var.
///
/// Spawns the IDE detached and returns immediately — vch is never the
/// parent of a long-running GUI app.
struct OpenCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Open a task's worktree in an IDE (Xcode, VS Code, …)."
    )

    @Argument(
        help: ArgumentHelp(
            "Task name. Omit to use the worktree containing $PWD.",
            valueName: "name"
        ),
        completion: .custom(TaskNameCompletion.candidates)
    )
    var name: String?

    @Option(
        name: .long,
        help: ArgumentHelp(
            "IDE to open with. Aliases: xcode, code, vscode, cursor. "
                + "Anything else is passed to `open -a`. "
                + "Defaults to $VCH_OPEN_DEFAULT, then auto-detect.",
            valueName: "ide"
        )
    )
    var with: String?

    @Flag(name: .long, help: "Print the command vch would run, but don't spawn it.")
    var dryRun: Bool = false

    func run() throws {
        try CLIBridge.run {
            let cwd = FileManager.default.currentDirectoryPath
            let env = ProcessInfo.processInfo.environment

            // Resolve both the workspace and, if applicable, the task
            // name implied by cwd. Avoids two separate locator calls.
            let resolved = try WorkspaceLocator.resolveCurrent(cwd: cwd)
            let workspace = resolved.workspace

            let task: TaskName
            if let explicit = name?.trimmingCharacters(in: .whitespaces),
               !explicit.isEmpty {
                task = try TaskName(explicit)
            } else if let inferred = resolved.taskName {
                task = inferred
            } else {
                throw VibeChardError.missingArgument(
                    "task name (run `vch open <name>` or invoke from inside a vch worktree)"
                )
            }

            let worktreePath = workspace.worktreePath(for: task)
            let fs = DiskFileSystem()
            guard fs.directoryExists(at: worktreePath) else {
                throw VibeChardError.taskNotFound(name: task.raw)
            }

            // List the worktree root so OpenService can decide kind.
            // We deliberately don't recurse — top-level matches cover
            // the supported project layouts.
            let rootContents: [String]
            do {
                rootContents = try FileManager.default
                    .contentsOfDirectory(atPath: worktreePath)
            } catch {
                throw VibeChardError.externalCommandFailed(
                    cmd: "list \(worktreePath)",
                    exitCode: 1,
                    stderr: "couldn't read worktree contents: "
                        + "\(error.localizedDescription)"
                )
            }

            let kind = OpenService.detectProjectKind(
                rootContents: rootContents,
                worktreePath: worktreePath
            )
            let ide = OpenService.resolveIDE(
                requested: with,
                env: env,
                projectKind: kind
            )
            let argv = OpenService.buildArgv(
                ide: ide,
                projectKind: kind,
                worktreePath: worktreePath,
                commandExists: { Self.isOnPath($0, env: env) }
            )

            if dryRun {
                print(argv.joined(separator: " "))
                return
            }

            try Self.spawnDetached(argv)
        }
    }

    /// Returns true if `name` resolves to a regular file inside any
    /// directory listed in `PATH`. We don't follow symlinks to verify
    /// executability — `Process` will surface that as a launch error.
    static func isOnPath(_ name: String, env: [String: String]) -> Bool {
        let raw = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in raw.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return true
            }
        }
        return false
    }

    /// Launch `argv` and return immediately. We do NOT `waitUntilExit`
    /// because GUI apps are long-running and detaching is the whole
    /// point. `/usr/bin/open` and `code`/`cursor` fork themselves and
    /// our `Process()` returns once the launcher exits, so we don't
    /// keep a zombie either way.
    static func spawnDetached(_ argv: [String]) throws {
        guard let head = argv.first else {
            throw VibeChardError.missingArgument("argv")
        }
        let proc = Process()
        // Absolute path → run directly. Otherwise spawn through env
        // so PATH lookup honors the parent's PATH (same convention as
        // PlanLauncher.run).
        if head.hasPrefix("/") {
            proc.executableURL = URL(fileURLWithPath: head)
            proc.arguments = Array(argv.dropFirst())
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = argv
        }
        do {
            try proc.run()
        } catch {
            throw VibeChardError.externalCommandFailed(
                cmd: argv.joined(separator: " "),
                exitCode: 127,
                stderr: "failed to launch: \(error.localizedDescription)"
            )
        }
        // For `/usr/bin/open` and the `code`/`cursor` launcher stubs,
        // `waitUntilExit` is fast (the launcher itself returns after
        // dispatching to LaunchServices / electron). We do wait so any
        // immediate launch error (e.g. "no such application") surfaces
        // as a non-zero exit instead of a silent miss.
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            throw ArgumentParser.ExitCode(proc.terminationStatus)
        }
    }
}
