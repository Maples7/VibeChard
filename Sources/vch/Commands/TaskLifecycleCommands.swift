import ArgumentParser
import Foundation
import VibeChardCore

// MARK: - vch new

struct NewCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "new",
        abstract: "Create a new isolated worktree + branch for a task."
    )

    @Argument(
        help: ArgumentHelp(
            "Task name (used as <repo>-<name> dir and agent/<name> branch). "
                + "With --adopt-current, omit to use the current linked "
                + "worktree directory name.",
            valueName: "name"
        )
    )
    var name: String?

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
            "COW-clone the SwiftPM bare-mirror cache from a sibling "
                + "vch task so this task's first build skips the "
                + "network fetch of dependency objects (~hundreds of "
                + "MB on real projects). Source task must already "
                + "have built once. Only `repositories/` is seeded — "
                + "checkouts/ is rebuilt locally. APFS-only.",
            valueName: "task"
        ),
        completion: .custom(TaskNameCompletion.candidates)
    )
    var seedSpmFrom: String?

    @Flag(
        name: .long,
        help: ArgumentHelp(
            "Adopt the current linked git worktree instead of creating "
                + "a new sibling worktree. Useful when an agent tool "
                + "already created the worktree; vch only initializes "
                + ".vch/state.json and task-local build isolation."
        )
    )
    var adoptCurrent: Bool = false

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

    @Flag(
        name: .long,
        help: ArgumentHelp(
            "Machine-readable contract for shell wrappers: stdout "
                + "prints ONLY the absolute worktree path; all status, "
                + "progress, and the `vch_new` install hint are routed "
                + "to stderr. Lets fish / nushell / any shell wrap with "
                + "`cd \"$(vch new --cd foo)\"` without parsing. "
                + "Mutually exclusive with --exec."
        )
    )
    var cd: Bool = false

    func run() throws {
        try CLIBridge.run {
            // #32B: --cd freezes stdout to "path only". --exec hands
            // off via execve before we'd ever print, so the two
            // contracts are incompatible — refuse early with usage 2
            // rather than silently dropping one.
            if cd, exec != nil {
                throw VibeChardError.newConflictingCdExec
            }

            if name == nil, !adoptCurrent {
                throw VibeChardError.missingArgument("task name")
            }

            let cwd = FileManager.default.currentDirectoryPath
            let location = try WorkspaceLocator.locateCurrent(cwd: cwd)
            let workspace = location.workspace
            let service = TaskService(
                workspace: workspace,
                git: DiskGitClient()
            )
            let task: TaskName
            if let name {
                task = try TaskName(name)
            } else {
                task = try service.inferTaskNameForAdoptCurrent(
                    currentWorktreePath: location.currentWorktreePath
                )
            }
            let seedTask = try seedSpmFrom.map(TaskName.init)
            let path: String
            let effectiveWorkspace: Workspace
            if adoptCurrent {
                path = try service.adoptCurrentWorktree(
                    task,
                    currentWorktreePath: location.currentWorktreePath,
                    baseRef: base,
                    copyUntracked: copyUntracked,
                    seedSpmFrom: seedTask
                )
                effectiveWorkspace = workspace.withWorktreePath(path, for: task)
            } else {
                path = try service.newTask(
                    task,
                    baseRef: base,
                    copyUntracked: copyUntracked,
                    seedSpmFrom: seedTask
                )
                effectiveWorkspace = workspace
            }
            print(path)

            // #32A: nudge first-time users toward `vch shellenv` so
            // that `vch_new <name>` auto-cds. The decision tree
            // (TTY check + env opt-outs + adopt-current / --exec /
            // --cd suppressions) lives in `NewTaskHint.message` so
            // it stays unit-testable per AGENTS.md discipline #7.
            let env = ProcessInfo.processInfo.environment
            let stdoutIsTTY = isatty(fileno(stdout)) != 0
            if let hint = NewTaskHint.message(
                stdoutIsTTY: stdoutIsTTY,
                env: env,
                adoptCurrent: adoptCurrent,
                execProvided: exec != nil,
                cdProvided: cd
            ) {
                CLIBridge.eprintln(hint)
            }

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
                    workspace: effectiveWorkspace,
                    git: DiskGitClient(),
                    developerDir: XcodeSelectDeveloperDirResolver()
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

    @Flag(
        name: [.long, .customLong("git")],
        help: "Add columns: AHEAD/BEHIND, DIRTY, LAST COMMIT (one git rev-list + status per worktree). Stays off the default path so existing scripts don't slow down."
    )
    var gitStatus: Bool = false

    func run() throws {
        try CLIBridge.run {
            let cwd = FileManager.default.currentDirectoryPath
            let workspace = try WorkspaceLocator.locate(cwd: cwd)
            let service = TaskService(
                workspace: workspace,
                git: DiskGitClient()
            )
            var summaries = try service.listTasks()
            if gitStatus {
                // Sequential is fine for typical 1–5 worktrees
                // (~50ms per worktree). If users hit a bigger fleet
                // we can hoist this into a TaskGroup later — the
                // service method is already pure so the rewrite is
                // local to this CLI layer.
                summaries = summaries.map { s in
                    s.with(gitStatus: service.gitStatus(forSummary: s))
                }
            }
            if json {
                try printSummariesJSON(summaries)
            } else {
                printSummariesTable(summaries, verbose: verbose, gitStatus: gitStatus)
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

    private func printSummariesTable(_ summaries: [TaskSummary], verbose: Bool, gitStatus: Bool) {
        if summaries.isEmpty {
            print("(no vch tasks; use `vch new <name>`)")
            return
        }
        var header: [String]
        var rows: [[String]]
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
        if gitStatus {
            // Inserted before the optional PATH column so PATH stays
            // last (verbose layout) and so the columns read
            // left-to-right as: identity → build → git → path.
            let extraHeader = ["AHEAD/BEHIND", "DIRTY", "MERGED", "LAST COMMIT"]
            let insertAt = verbose ? header.count - 1 : header.count
            header.insert(contentsOf: extraHeader, at: insertAt)
            for (i, s) in summaries.enumerated() {
                let extra = [
                    aheadBehindLabel(s.gitStatus),
                    dirtyLabel(s.gitStatus),
                    mergedLabel(s.gitStatus),
                    lastCommitLabel(s.gitStatus),
                ]
                rows[i].insert(contentsOf: extra, at: insertAt)
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
            case "AHEAD/BEHIND":
                return raw == "-"
                    ? ANSI.wrap(padded, .placeholder, enabled: colorize)
                    : padded
            case "DIRTY":
                switch raw {
                case "yes":  return ANSI.wrap(padded, .fail, enabled: colorize)
                case "no":   return ANSI.wrap(padded, .ok, enabled: colorize)
                default:     return ANSI.wrap(padded, .placeholder, enabled: colorize)
                }
            case "MERGED":
                // Merged → success colour; not-merged → informational
                // (it's the normal state for an active task, not a
                // failure). Unknown stays muted.
                switch raw {
                case "yes": return ANSI.wrap(padded, .ok, enabled: colorize)
                case "no":  return padded
                default:    return ANSI.wrap(padded, .placeholder, enabled: colorize)
                }
            case "LAST COMMIT":
                return raw == "-"
                    ? ANSI.wrap(padded, .placeholder, enabled: colorize)
                    : padded
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

    /// Render `AHEAD/BEHIND` as e.g. `3/0`. `-` means we couldn't
    /// query (no recorded base branch, or git failed).
    private func aheadBehindLabel(_ git: GitStatus?) -> String {
        guard let git, let a = git.aheadCount, let b = git.behindCount else {
            return "-"
        }
        return "\(a)/\(b)"
    }

    /// Three-state label so an unknown git result is visibly distinct
    /// from a known-clean worktree.
    private func dirtyLabel(_ git: GitStatus?) -> String {
        guard let git else { return "-" }
        return git.isDirty ? "yes" : "no"
    }

    /// Three-state label: `yes` (fully merged into base), `no`
    /// (commits not yet on base), `-` (unknown — no recorded base or
    /// git failed). (#67)
    private func mergedLabel(_ git: GitStatus?) -> String {
        guard let git, let merged = git.mergedIntoBase else { return "-" }
        return merged ? "yes" : "no"
    }

    private func lastCommitLabel(_ git: GitStatus?) -> String {
        guard let git, let s = git.lastCommitSubject, !s.isEmpty else {
            return "-"
        }
        // Keep table rows readable; full text still shows up in --json.
        let limit = 60
        if s.count > limit {
            let head = s.prefix(limit - 1)
            return "\(head)…"
        }
        return s
    }

    private struct JSONEntry: Encodable {
        let name: String
        let branch: String
        let path: String
        let createdAt: Date?
        let baseRef: String?
        let baseBranch: String?
        let simulator: String?
        let lastBuild: BuildJSON?
        /// `--git-status`-only payload. Nil keeps the JSON shape
        /// stable for scripts that don't ask for git enrichment.
        let git: GitJSON?

        struct BuildJSON: Encodable {
            let success: Bool
            let finishedAt: Date
        }

        struct GitJSON: Encodable {
            let aheadCount: Int?
            let behindCount: Int?
            let isDirty: Bool
            let lastCommitSubject: String?
            /// `mergedIntoBase` from `GitStatus`. Nil = couldn't
            /// compute; distinct from `false` so scripts can branch
            /// safely. (#67)
            let mergedIntoBase: Bool?
        }

        init(_ s: TaskSummary) {
            self.name = s.name
            self.branch = s.branch
            self.path = s.path
            self.createdAt = s.createdAt
            self.baseRef = s.baseRef
            self.baseBranch = s.baseBranch
            self.simulator = s.simulatorName
            if let success = s.lastBuildSucceeded, let when = s.lastBuildAt {
                self.lastBuild = BuildJSON(success: success, finishedAt: when)
            } else {
                self.lastBuild = nil
            }
            if let g = s.gitStatus {
                self.git = GitJSON(
                    aheadCount: g.aheadCount,
                    behindCount: g.behindCount,
                    isDirty: g.isDirty,
                    lastCommitSubject: g.lastCommitSubject,
                    mergedIntoBase: g.mergedIntoBase
                )
            } else {
                self.git = nil
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
        // Multi-binding (#99): emit one `sim:` line per binding so
        // operators see every clone the task owns. With one binding
        // (the pre-#99 case) the output is unchanged.
        for sim in s.allSimulators {
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
        if let sync = s.lastSync {
            let verb = sync.strategy == "rebase" ? "rebased" : "merged"
            let commitsLabel: String
            if sync.appliedCommits == 0 {
                commitsLabel = "up-to-date"
            } else {
                commitsLabel = "\(verb) \(sync.appliedCommits) commit\(sync.appliedCommits == 1 ? "" : "s")"
            }
            let shortSHA = sync.baseSHA.prefix(7)
            lines.append(("last sync", "\(commitsLabel) onto \(sync.baseLabel) (\(shortSHA)) at \(f.string(from: sync.finishedAt))"))
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
        abstract: "Remove a task and its vch-owned resources.",
        aliases: ["rm"]
    )

    @Argument(help: "Task name to remove.",
              completion: .custom(TaskNameCompletion.candidates))
    var name: String

    @Flag(name: .long,
          help: "Discard uncommitted changes in the worktree and remove anyway.")
    var allowDirty: Bool = false

    @Flag(name: .long,
          help: "Force-remove even when an editor or shell is still holding files inside the worktree.")
    var force: Bool = false

    @Flag(name: .long,
          help: "Delete the branch even if it has commits not merged into its base.")
    var allowUnmerged: Bool = false

    @Flag(name: .long, help: "Keep the per-task simulator clone (default: delete it).")
    var keepSim: Bool = false

    func run() throws {
        try CLIBridge.run {
            let task = try TaskName(name)
            let cwd = FileManager.default.currentDirectoryPath
            let workspace = try WorkspaceLocator.locate(cwd: cwd)
            let service = TaskService(workspace: workspace, git: DiskGitClient())

            let state = readTaskState(workspace: workspace, task: task)

            // #10 / #65: refuse to delete vch-owned files out from
            // under a running process unless the user explicitly
            // forces. vch-created tasks scan the whole worktree before
            // deleting it. Adopted tasks keep the external worktree, so
            // only scan the vch-owned scratch roots we are about to
            // remove.
            //
            // Prior to v0.5.0 this was gated on `--allow-dirty`,
            // which conflated two unrelated concerns. The holder
            // check now has its own `--force` flag, so users with
            // a clean tree but an open editor can override
            // without also being told to discard uncommitted
            // work. `--allow-dirty` no longer affects this check.
            let wtPath = workspace.worktreePath(for: task)
            let holderRoots: [String]
            if state?.worktreeOwnership == .adopted {
                holderRoots = [workspace.vchDir(for: task), workspace.agentBuildDir(for: task)]
            } else {
                holderRoots = [wtPath]
            }
            if !force {
                let scanner = DiskWorktreeHolderScanner()
                for root in holderRoots where FileManager.default.fileExists(atPath: root) {
                    if let holders = try? scanner.findHolders(of: root),
                       !holders.isEmpty {
                        throw VibeChardError.worktreeBusy(path: root, holders: holders)
                    }
                }
            }

            let opts = TaskService.RemoveOptions(
                allowDirty: allowDirty,
                allowUnmergedBranch: allowUnmerged
            )
            try service.removeTask(task, options: opts)

            if !keepSim {
                // Multi-binding (#99): reap every recorded clone.
                // First failure does not block subsequent deletes —
                // each warning is independent and we never abort
                // because the worktree is already gone by this point.
                let bindings = state?.allSimulators ?? []
                if !bindings.isEmpty {
                    let simctl = DiskSimctlClient()
                    for sim in bindings {
                        do {
                            try simctl.delete(udid: sim.cloneUDID)
                            CLIBridge.eprintln("→ deleted simulator clone '\(sim.name)'")
                        } catch {
                            CLIBridge.eprintln("warning: could not delete simulator clone \(sim.cloneUDID): \(error)")
                        }
                    }
                }
            }

            print("removed \(task.raw)")
        }
    }

    private func readTaskState(
        workspace: Workspace, task: TaskName
    ) -> TaskState? {
        let p = workspace.statePath(for: task)
        guard FileManager.default.fileExists(atPath: p) else { return nil }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: p)) else { return nil }
        return try? TaskState.parse(data)
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
