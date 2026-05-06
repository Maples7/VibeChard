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
            let path = try service.newTask(task, baseRef: base)
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
                printSummariesTable(summaries)
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

    private func printSummariesTable(_ summaries: [TaskSummary]) {
        if summaries.isEmpty {
            print("(no vch tasks; use `vch new <name>`)")
            return
        }
        let rows = summaries.map { s -> [String] in
            [
                s.name,
                s.branch,
                s.simulatorName ?? "-",
                s.createdAt.map(humanDate) ?? "-",
                buildStatusLabel(s),
            ]
        }
        let header = ["NAME", "BRANCH", "SIM", "CREATED", "BUILD"]
        let widths: [Int] = (0..<header.count).map { col in
            max(header[col].count, rows.map { $0[col].count }.max() ?? 0)
        }
        func format(_ row: [String]) -> String {
            row.enumerated()
                .map { (i, cell) in cell.padding(toLength: widths[i], withPad: " ", startingAt: 0) }
                .joined(separator: "  ")
        }
        print(format(header))
        for row in rows { print(format(row)) }
    }

    private func humanDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
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

// MARK: - vch remove

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
