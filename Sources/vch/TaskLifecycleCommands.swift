import ArgumentParser
import Foundation
import VibeChardCore

// MARK: - vch new

struct NewCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "new",
        abstract: "Create a new isolated worktree + branch for a task."
    )

    @Argument(help: "Task name (used as <repo>-<name> dir and agent/<name> branch).")
    var name: String

    @Option(name: .long, help: "Base ref for the new branch (default: HEAD).")
    var base: String?

    @Flag(
        name: .long,
        help: ArgumentHelp(
            "Also copy git-untracked, non-ignored files (e.g. .env, "
                + ".vscode/settings.json) from the main worktree into the "
                + "new one. Tracked files come from the branch checkout; "
                + "ignored files (build outputs, node_modules, etc.) are "
                + "skipped."
        )
    )
    var copyUntracked: Bool = false

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Command to run inside the new worktree once it's ready. "
                + "Passed to `/bin/sh -c`, so quoting works as in the shell. "
                + "Replaces vch via execve — vch is no longer the parent.",
            valueName: "cmd"
        )
    )
    var exec: String?

    func run() throws {
        try CLIBridge.run {
            let task = try TaskName(name)
            let cwd = FileManager.default.currentDirectoryPath
            let workspace = try WorkspaceLocator.locate(cwd: cwd)
            let service = TaskService(
                workspace: workspace,
                git: DiskGitClient()
            )
            let path = try service.newTask(
                task,
                baseRef: base,
                copyUntracked: copyUntracked
            )
            print(path)

            // BYO Agent integration point (AGENTS.md rule #2):
            // hand off to /bin/sh -c "<cmd>" inside the new worktree
            // with isolation env active. We `execve` instead of fork+
            // wait so the agent IS vch (same pid/pgrp/tty), matching
            // `vch exec` semantics.
            if let cmd = exec?.trimmingCharacters(in: .whitespaces),
               !cmd.isEmpty {
                let env = ProcessInfo.processInfo.environment
                let shimPath = try ExecCommand.resolveShimPath(env: env)
                let execService = ExecService(
                    workspace: workspace,
                    git: DiskGitClient()
                )
                let plan = try execService.prepare(
                    task: task,
                    command: ["/bin/sh", "-c", cmd],
                    shimPath: shimPath,
                    baseEnv: env
                )
                PlanLauncher.runReplacing(plan)
            }
        }
    }
}

// MARK: - vch list

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List vch-managed worktrees.",
        aliases: ["ls"]
    )

    @Flag(name: .long, help: "Emit machine-readable JSON instead of a table.")
    var json: Bool = false

    @Flag(name: .shortAndLong, help: "Add columns: PATH, BASE.")
    var verbose: Bool = false

    func run() throws {
        try CLIBridge.run {
            let cwd = FileManager.default.currentDirectoryPath
            let workspace = try WorkspaceLocator.locate(cwd: cwd)
            let service = TaskService(
                workspace: workspace,
                git: DiskGitClient()
            )
            let summaries = try service.listTasks()
            if json {
                try printSummariesJSON(summaries)
            } else {
                printSummariesTable(summaries, verbose: verbose)
            }
        }
    }

    private func printSummariesJSON(_ summaries: [TaskSummary]) throws {
        let payload = summaries.map(JSONEntry.init(_:))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        if let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }

    private func printSummariesTable(_ summaries: [TaskSummary], verbose: Bool) {
        if summaries.isEmpty {
            print("(no vch tasks; use `vch new <name>`)")
            return
        }
        let header: [String]
        let rows: [[String]]
        if verbose {
            header = ["NAME", "BRANCH", "BASE", "SIM", "CREATED", "BUILD", "PATH"]
            rows = summaries.map { s in
                [
                    s.name,
                    s.branch,
                    s.baseRef ?? "-",
                    s.simulatorName ?? "-",
                    s.createdAt.map(humanDate) ?? "-",
                    buildStatusLabel(s),
                    s.path,
                ]
            }
        } else {
            header = ["NAME", "BRANCH", "SIM", "CREATED", "BUILD"]
            rows = summaries.map { s in
                [
                    s.name,
                    s.branch,
                    s.simulatorName ?? "-",
                    s.createdAt.map(humanDate) ?? "-",
                    buildStatusLabel(s),
                ]
            }
        }
        // Width is computed on the *uncolored* text. Colors are
        // applied AFTER padding so ANSI escape codes don't break
        // alignment (their byte length is invisible to the terminal).
        let widths: [Int] = (0..<header.count).map { col in
            max(header[col].count, rows.map { $0[col].count }.max() ?? 0)
        }
        let colorize = ANSI.defaultEnabledForStdout()
        func paint(_ raw: String, padded: String, column: String, isHeader: Bool) -> String {
            if isHeader {
                return ANSI.wrap(padded, .header, enabled: colorize)
            }
            switch column {
            case "NAME":
                return ANSI.wrap(padded, .name, enabled: colorize)
            case "BRANCH":
                return ANSI.wrap(padded, .branch, enabled: colorize)
            case "SIM":
                return ANSI.wrap(padded, raw == "-" ? .placeholder : .sim, enabled: colorize)
            case "BUILD":
                switch raw {
                case "ok":   return ANSI.wrap(padded, .ok, enabled: colorize)
                case "fail": return ANSI.wrap(padded, .fail, enabled: colorize)
                default:     return ANSI.wrap(padded, .placeholder, enabled: colorize)
                }
            case "BASE", "CREATED":
                if raw == "-" {
                    return ANSI.wrap(padded, .placeholder, enabled: colorize)
                }
                return padded
            default:
                return padded
            }
        }
        func format(_ row: [String], isHeader: Bool) -> String {
            row.enumerated()
                .map { (i, cell) in
                    let padded = cell.padding(toLength: widths[i], withPad: " ", startingAt: 0)
                    return paint(cell, padded: padded, column: header[i], isHeader: isHeader)
                }
                .joined(separator: "  ")
        }
        print(format(header, isHeader: true))
        for row in rows { print(format(row, isHeader: false)) }
    }

    private func humanDate(_ date: Date) -> String {
        // Local time + offset (e.g. 2026-05-07T10:22:17+08:00) so users
        // don't have to mentally convert UTC. Still a valid ISO 8601
        // string. JSON output keeps UTC via JSONEncoder's .iso8601.
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: date)
    }

    private func buildStatusLabel(_ s: TaskSummary) -> String {
        guard let success = s.lastBuildSucceeded else { return "-" }
        return success ? "ok" : "fail"
    }

    private struct JSONEntry: Encodable {
        let name: String
        let branch: String
        let path: String
        let createdAt: Date?
        let baseRef: String?
        let simulator: String?
        let lastBuild: BuildJSON?

        struct BuildJSON: Encodable {
            let success: Bool
            let finishedAt: Date
        }

        init(_ s: TaskSummary) {
            self.name = s.name
            self.branch = s.branch
            self.path = s.path
            self.createdAt = s.createdAt
            self.baseRef = s.baseRef
            self.simulator = s.simulatorName
            if let success = s.lastBuildSucceeded, let when = s.lastBuildAt {
                self.lastBuild = BuildJSON(success: success, finishedAt: when)
            } else {
                self.lastBuild = nil
            }
        }
    }
}

// MARK: - vch path

struct PathCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "path",
        abstract: "Print the absolute path of a task's worktree."
    )

    @Argument(help: "Task name to resolve.",
              completion: .custom(TaskNameCompletion.candidates))
    var name: String

    func run() throws {
        try CLIBridge.run {
            let task = try TaskName(name)
            let cwd = FileManager.default.currentDirectoryPath
            let workspace = try WorkspaceLocator.locate(cwd: cwd)
            let service = TaskService(workspace: workspace, git: DiskGitClient())
            let path = try service.pathForTask(task)
            print(path)
        }
    }
}

// MARK: - vch state

struct StateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "state",
        abstract: "Show a task's persisted state (.vch/state.json)."
    )

    @Argument(help: "Task name to inspect.",
              completion: .custom(TaskNameCompletion.candidates))
    var name: String

    @Flag(name: .long, help: "Emit raw JSON (the full state.json contents).")
    var json: Bool = false

    @Option(name: .long,
            help: "Print just one field's value (dotted path, e.g. 'simulator.udid'). Designed for $(vch state <task> --field simulator.udid).")
    var field: String?

    func run() throws {
        try CLIBridge.run {
            let task = try TaskName(name)
            let cwd = FileManager.default.currentDirectoryPath
            let workspace = try WorkspaceLocator.locate(cwd: cwd)
            let service = TaskService(workspace: workspace, git: DiskGitClient())
            let state = try service.stateForTask(task)
            let path = workspace.worktreePath(for: task)
            if let field {
                try emitField(field, state: state, worktreePath: path)
                return
            }
            if json {
                let data = try state.jsonData()
                if let str = String(data: data, encoding: .utf8) {
                    print(str)
                }
            } else {
                printHumanReadable(state, worktreePath: path)
            }
        }
    }

    /// `vch state <task> --field <dotted>` (#8). Exit codes follow
    /// `git config --get` so scripts can branch cleanly:
    ///   0 = field present, value printed
    ///   1 = field is part of the schema but unset for this task
    ///   2 = unknown field name (typo / version skew)
    private func emitField(_ name: String, state: TaskState, worktreePath: String) throws {
        switch TaskStateField.lookup(name, in: state, worktreePath: worktreePath) {
        case .value(let v):
            print(v)
        case .unset:
            CLIBridge.eprintln("field '\(name)' is not set on task '\(state.name)'")
            throw ArgumentParser.ExitCode(ExitCode.business)
        case .unknown:
            CLIBridge.eprintln("unknown state field '\(name)' — see `vch help state` for the supported set")
            throw ArgumentParser.ExitCode(ExitCode.usage)
        }
    }

    private func printHumanReadable(_ s: TaskState, worktreePath: String) {
        // Local time + offset for human-readable output. Use --json for
        // a machine-readable UTC dump.
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        let colorize = ANSI.defaultEnabledForStdout()
        func status(_ ok: Bool) -> String {
            ok ? ANSI.wrap("ok", .ok, enabled: colorize)
               : ANSI.wrap("fail", .fail, enabled: colorize)
        }
        var lines: [(String, String)] = [
            ("name", s.name),
            ("branch", s.branch),
            ("path", worktreePath),
            ("base", s.baseRef),
            ("created", f.string(from: s.createdAt)),
            ("schema", "v\(s.schemaVersion)"),
        ]
        if let scheme = s.scheme {
            lines.append(("scheme", scheme))
        }
        if let sim = s.simulator {
            lines.append(("sim", "\(sim.name) (\(sim.cloneUDID))"))
        }
        if let b = s.lastBuild {
            lines.append(("last build", "\(status(b.success)) at \(f.string(from: b.finishedAt)) (\(formatDuration(b.durationSeconds)))"))
        }
        if let t = s.lastTest {
            lines.append(("last test", "\(status(t.success)) at \(f.string(from: t.finishedAt)) (\(formatDuration(t.durationSeconds)))"))
        }
        if let e = s.lastExec {
            if let exit = e.exitCode, let ended = e.exitedAt {
                let exitStyle: ANSI.Style = (exit == 0) ? .ok : .fail
                let exitLabel = ANSI.wrap("exit \(exit)", exitStyle, enabled: colorize)
                lines.append(("last exec", "\(e.command) → \(exitLabel) at \(f.string(from: ended))"))
            } else {
                lines.append(("last exec", "\(e.command) (started \(f.string(from: e.startedAt)))"))
            }
        }
        let width = lines.map { $0.0.count }.max() ?? 0
        for (k, v) in lines {
            let padded = k.padding(toLength: width, withPad: " ", startingAt: 0)
            print("\(padded)  \(v)")
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 10 {
            return String(format: "%.2fs", seconds)
        }
        return String(format: "%.1fs", seconds)
    }
}

struct RemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a task's worktree and delete its branch.",
        aliases: ["rm"]
    )

    @Argument(help: "Task name to remove.",
              completion: .custom(TaskNameCompletion.candidates))
    var name: String

    @Flag(
        name: .shortAndLong,
        help: "Force removal. Pass once to allow dirty worktrees; pass twice to also force-delete unmerged branches."
    )
    var force: Int

    @Flag(name: .long, help: "Keep the per-task simulator clone (default: delete it).")
    var keepSim: Bool = false

    func run() throws {
        try CLIBridge.run {
            let task = try TaskName(name)
            let cwd = FileManager.default.currentDirectoryPath
            let workspace = try WorkspaceLocator.locate(cwd: cwd)
            let service = TaskService(workspace: workspace, git: DiskGitClient())

            // #10: refuse to delete the worktree out from under an open
            // editor / shell unless the user explicitly forces. We do
            // this BEFORE reading state.json (which is also held by us
            // for the simulator-cleanup step) so the diagnostic lands
            // before we touch anything.
            let wtPath = workspace.worktreePath(for: task)
            if force == 0,
               FileManager.default.fileExists(atPath: wtPath) {
                let scanner = DiskWorktreeHolderScanner()
                if let holders = try? scanner.findHolders(of: wtPath),
                   !holders.isEmpty {
                    throw VibeChardError.worktreeBusy(path: wtPath, holders: holders)
                }
            }

            // Read state.json BEFORE git tears the worktree down so we
            // can clean up the simulator clone afterwards. Best-effort
            // — a missing/corrupt state.json must not block removal.
            let simRecord = readSimulatorRecord(workspace: workspace, task: task)

            let opts: TaskService.RemoveOptions
            switch force {
            case 0: opts = TaskService.RemoveOptions()
            case 1: opts = .forceDirty
            default: opts = .forceAll
            }
            try service.removeTask(task, options: opts)

            if !keepSim, let sim = simRecord {
                let simctl = DiskSimctlClient()
                do {
                    try simctl.delete(udid: sim.cloneUDID)
                    CLIBridge.eprintln("→ deleted simulator clone '\(sim.name)'")
                } catch {
                    // Worktree is already gone; surface but don't fail.
                    CLIBridge.eprintln("warning: could not delete simulator clone \(sim.cloneUDID): \(error)")
                }
            }

            print("removed \(task.raw)")
        }
    }

    private func readSimulatorRecord(
        workspace: Workspace, task: TaskName
    ) -> TaskState.SimulatorRecord? {
        let p = workspace.statePath(for: task)
        guard FileManager.default.fileExists(atPath: p) else { return nil }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: p)) else { return nil }
        return (try? TaskState.parse(data))?.simulator
    }
}

// MARK: - vch repair

struct RepairCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repair",
        abstract: "Prune stale worktrees and surface state-file problems."
    )

    func run() throws {
        try CLIBridge.run {
            let cwd = FileManager.default.currentDirectoryPath
            let workspace = try WorkspaceLocator.locate(cwd: cwd)
            let service = TaskService(workspace: workspace, git: DiskGitClient())
            let report = try service.repair()
            if report.prunedStaleEntries {
                print("pruned stale worktree entries")
            }
            print("checked tasks: \(report.checkedTasks.isEmpty ? "(none)" : report.checkedTasks.joined(separator: ", "))")
            if report.problems.isEmpty {
                print("no problems found")
            } else {
                CLIBridge.eprintln("problems:")
                for problem in report.problems {
                    CLIBridge.eprintln("  - \(problem)")
                }
                throw ArgumentParser.ExitCode(ExitCode.business)
            }
        }
    }
}
