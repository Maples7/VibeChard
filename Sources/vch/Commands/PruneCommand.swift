import ArgumentParser
import Foundation
import VibeChardCore

/// `vch prune` — list (and optionally remove) every vch task whose
/// branch has been fully merged into its base. Default is dry-run; the
/// user opts in to apply with `--rm`. (#67)
///
/// The "is this safe to delete?" decision lives in `PrunePlanner`. This
/// command only wires `TaskService` + `DiskWorktreeHolderScanner` into
/// the planner, renders the plan, and invokes `removeTask` for each
/// prunable row when applying.
struct PruneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prune",
        abstract: "List (or remove) every task whose branch is already merged into its base."
    )

    @Flag(name: .long,
          help: "Print what would be removed without removing anything. Default behaviour.")
    var dryRun: Bool = false

    @Flag(name: .long,
          help: "Actually remove the prunable tasks. Mutually exclusive with --dry-run.")
    var rm: Bool = false

    @Flag(name: .long,
          help: "Allow pruning even when a worktree has uncommitted changes. Maps to `vch rm --allow-dirty`.")
    var allowDirty: Bool = false

    @Flag(name: .long,
          help: "Allow pruning even when an editor / shell is holding files inside a worktree. Maps to `vch rm --force`.")
    var force: Bool = false

    @Flag(name: .long,
          help: "Keep the per-task simulator clone for each pruned task (default: delete it).")
    var keepSim: Bool = false

    @Flag(name: .long,
          help: "Emit machine-readable JSON instead of a human-friendly summary.")
    var json: Bool = false

    func run() throws {
        try CLIBridge.run {
            // --dry-run is the default; --rm is the explicit opt-in.
            // Refuse to guess if both are passed.
            if dryRun, rm {
                CLIBridge.eprintln("vch prune: --dry-run and --rm are mutually exclusive")
                throw ArgumentParser.ExitCode(ExitCode.usage)
            }
            let apply = rm

            let cwd = FileManager.default.currentDirectoryPath
            let workspace = try WorkspaceLocator.locate(cwd: cwd)
            let service = TaskService(
                workspace: workspace,
                git: DiskGitClient()
            )

            // Same enrichment path as `vch list --git-status`. We
            // always need git enrichment here — the merge gate is
            // the whole point of prune — so there's no flag to
            // disable it.
            let summaries = try service.listTasks().map { s in
                s.with(gitStatus: service.gitStatus(forSummary: s))
            }

            // Holder scan is best-effort: a flaky lsof should not
            // block the listing, but it should not silently allow a
            // prune either. Treat scan failure as "no holders" only
            // when the user has opted into --force; otherwise surface
            // it via the standard skip path so the user can decide.
            let scanner = DiskWorktreeHolderScanner()
            let inputs: [PrunePlanner.Input] = summaries.map { s in
                let holders: [WorktreeHolder]
                if let found = try? scanner.findHolders(of: s.path) {
                    holders = found
                } else {
                    holders = []
                }
                return PrunePlanner.Input(summary: s, holders: holders)
            }

            let plan = PrunePlanner.plan(
                inputs: inputs,
                options: PrunePlanner.Options(
                    allowDirty: allowDirty,
                    force: force
                )
            )

            // Snapshot simulator records BEFORE any removal so we
            // can delete the per-task clones after the worktree is
            // gone. Mirror `vch rm`'s best-effort policy: a missing
            // or corrupt state.json never blocks the prune.
            var simRecords: [String: TaskState.SimulatorRecord] = [:]
            if apply, !keepSim {
                for d in plan.prunable {
                    if let task = try? TaskName(d.summary.name),
                       let sim = readSimulatorRecord(workspace: workspace, task: task) {
                        simRecords[d.summary.name] = sim
                    }
                }
            }

            // Apply phase. We continue past per-task failures so a
            // single weird worktree doesn't strand the rest. Each
            // failure is logged and reported, and the command exits
            // non-zero at the end if any apply failed.
            var applied: [String] = []
            var failures: [(name: String, message: String)] = []
            if apply {
                for d in plan.prunable {
                    do {
                        let task = try TaskName(d.summary.name)
                        try service.removeTask(
                            task,
                            options: TaskService.RemoveOptions(
                                allowDirty: allowDirty,
                                // Branches in `prunable` are by
                                // definition fully merged, so plain
                                // `git branch -d` should always
                                // succeed. Keep `allowUnmergedBranch`
                                // off so any stale branch surprise
                                // surfaces as a hard failure rather
                                // than a silent `-D`.
                                allowUnmergedBranch: false
                            )
                        )
                        applied.append(d.summary.name)
                        if !keepSim, let sim = simRecords[d.summary.name] {
                            let simctl = DiskSimctlClient()
                            do {
                                try simctl.delete(udid: sim.cloneUDID)
                            } catch {
                                CLIBridge.eprintln(
                                    "warning: could not delete simulator clone \(sim.cloneUDID) for '\(d.summary.name)': \(error)"
                                )
                            }
                        }
                    } catch {
                        failures.append((d.summary.name, "\(error)"))
                    }
                }
            }

            if json {
                printJSON(plan: plan, apply: apply, applied: applied, failures: failures)
            } else {
                printHuman(plan: plan, apply: apply, applied: applied, failures: failures)
            }

            if !failures.isEmpty {
                throw ArgumentParser.ExitCode(ExitCode.business)
            }
        }
    }

    // MARK: - rendering

    private func printHuman(
        plan: PrunePlanner.Plan,
        apply: Bool,
        applied: [String],
        failures: [(name: String, message: String)]
    ) {
        if plan.decisions.isEmpty {
            print("(no vch tasks)")
            return
        }
        let prunable = plan.prunable
        let skipped  = plan.skipped

        if prunable.isEmpty {
            print("nothing prunable — every task either has unmerged commits, is dirty, or is held open")
        } else {
            let verb = apply ? "removed" : "would remove"
            for d in prunable {
                if apply, applied.contains(d.summary.name) {
                    print("\(verb): \(d.summary.name)  (\(d.summary.branch))")
                } else if !apply {
                    print("\(verb): \(d.summary.name)  (\(d.summary.branch))")
                }
            }
        }

        for d in skipped {
            CLIBridge.eprintln("skip \(d.summary.name): \(reasonLabel(d.skip!))")
        }

        if !failures.isEmpty {
            CLIBridge.eprintln("")
            for f in failures {
                CLIBridge.eprintln("error: failed to prune '\(f.name)': \(f.message)")
            }
        }

        if !apply, !prunable.isEmpty {
            CLIBridge.eprintln("")
            CLIBridge.eprintln("(dry run — re-run with --rm to apply)")
        }
    }

    private func reasonLabel(_ reason: PrunePlanner.SkipReason) -> String {
        switch reason {
        case .mergeStatusUnknown:
            return "merge status unknown (no recorded base or git failed; rebuild via `vch state <name>`)"
        case .notMerged(let ahead):
            let plural = ahead == 1 ? "commit" : "commits"
            return "\(ahead) \(plural) not yet on base"
        case .dirty:
            return "worktree has uncommitted changes (use --allow-dirty to override)"
        case .heldOpen(let holders):
            // Mirror `vch remove`'s `pid:command` rendering so the
            // user has a single mental model.
            let rendered = holders.prefix(3).map { "\($0.pid):\($0.command)" }.joined(separator: ", ")
            let suffix = holders.count > 3 ? " (+\(holders.count - 3) more)" : ""
            return "held open by \(rendered)\(suffix) (use --force to override)"
        }
    }

    private func printJSON(
        plan: PrunePlanner.Plan,
        apply: Bool,
        applied: [String],
        failures: [(name: String, message: String)]
    ) {
        struct DecisionJSON: Encodable {
            let name: String
            let branch: String
            let path: String
            let skip: String?
            let detail: String?
        }
        struct FailureJSON: Encodable {
            let name: String
            let message: String
        }
        struct Payload: Encodable {
            let mode: String
            let decisions: [DecisionJSON]
            let applied: [String]
            let failures: [FailureJSON]
        }

        let decisions: [DecisionJSON] = plan.decisions.map { d in
            let skip: String?
            let detail: String?
            switch d.skip {
            case nil:
                skip = nil; detail = nil
            case .mergeStatusUnknown?:
                skip = "merge_status_unknown"; detail = nil
            case .notMerged(let ahead)?:
                skip = "not_merged"; detail = "ahead=\(ahead)"
            case .dirty?:
                skip = "dirty"; detail = nil
            case .heldOpen(let holders)?:
                skip = "held_open"
                detail = holders.map { "\($0.pid):\($0.command)" }.joined(separator: ",")
            }
            return DecisionJSON(
                name: d.summary.name,
                branch: d.summary.branch,
                path: d.summary.path,
                skip: skip,
                detail: detail
            )
        }
        let payload = Payload(
            mode: apply ? "apply" : "dry-run",
            decisions: decisions,
            applied: applied,
            failures: failures.map { FailureJSON(name: $0.name, message: $0.message) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(payload),
           let str = String(data: data, encoding: .utf8) {
            print(str)
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
