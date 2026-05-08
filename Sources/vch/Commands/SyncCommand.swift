import ArgumentParser
import Foundation
import VibeChardCore

/// `vch sync <name>` — fetch the recorded base branch and rebase
/// `agent/<name>` onto it (or `--merge` for users who pushed the
/// task branch). All git work happens inside the task worktree, so
/// the user's main worktree is never disturbed. (#25)
struct SyncCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Rebase (or merge) a task branch onto its recorded base after fetching the upstream."
    )

    @Argument(help: "Task name to sync.",
              completion: .custom(TaskNameCompletion.candidates))
    var name: String

    @Option(name: .long,
            help: "Override the base ref. Accepts anything `git rev-parse` can resolve.")
    var onto: String?

    @Flag(name: .long,
          help: "Rebase the task branch onto the base (default).")
    var rebase: Bool = false

    @Flag(name: .long,
          help: "Merge the base into the task branch (`git merge --no-ff`).")
    var merge: Bool = false

    @Flag(name: .long,
          help: "Skip `git fetch`. Use when offline or to consume a previously-fetched base.")
    var noFetch: Bool = false

    @Flag(name: .long,
          help: "Don't refuse on uncommitted changes; let git decide whether the rebase can proceed.")
    var allowDirty: Bool = false

    @Flag(name: .long,
          help: "Print the planned strategy and ahead/behind counts without modifying any branches.")
    var dryRun: Bool = false

    @Flag(name: [.long, .customShort("q")],
          help: "Suppress progress lines; print only the final result line.")
    var quiet: Bool = false

    func run() throws {
        try CLIBridge.run {
            let task = try TaskName(name)
            let cwd = FileManager.default.currentDirectoryPath
            let workspace = try WorkspaceLocator.locate(cwd: cwd)

            if rebase && merge {
                throw VibeChardError.landConflictingStrategies
            }
            let strategy: SyncPlan.Strategy = merge ? .merge : .rebase

            let service = SyncService(workspace: workspace, git: DiskGitClient())

            let outcome = try service.sync(
                task,
                options: .init(
                    onto: onto,
                    strategy: strategy,
                    allowDirty: allowDirty,
                    noFetch: noFetch,
                    dryRun: dryRun
                ),
                progress: { [quiet] event in
                    if quiet { return }
                    Self.emit(event, taskName: task.raw)
                }
            )

            printOutcome(outcome, taskName: task.raw)
        }
    }

    private static func emit(_ event: SyncService.Event, taskName: String) {
        switch event {
        case let .fetching(remote, branch):
            CLIBridge.eprintln("→ fetching \(remote) \(branch)…")
        case let .fetchSkipped(reason):
            switch reason {
            case .userOptOut:
                CLIBridge.eprintln("→ skipping fetch (--no-fetch)")
            case .noBaseBranch:
                CLIBridge.eprintln("→ skipping fetch (no recorded baseBranch)")
            }
        case let .fallbackToOrigin(baseBranch):
            CLIBridge.eprintln("warning: '\(baseBranch)' has no upstream remote configured; falling back to 'origin'")
            CLIBridge.eprintln("         set with: git branch --set-upstream-to=<remote>/\(baseBranch) \(baseBranch)")
        case let .rebasing(taskBranch, onto):
            CLIBridge.eprintln("→ rebasing \(taskBranch) onto \(onto)…")
        case let .merging(taskBranch, onto):
            CLIBridge.eprintln("→ merging \(onto) into \(taskBranch) (--no-ff)…")
        case let .alreadyUpToDate(taskBranch, onto):
            CLIBridge.eprintln("✓ \(taskBranch) is already up to date with \(onto)")
        case let .dryRunPlan(strategy, baseLabel, ahead, behind):
            let verb = strategy == .rebase ? "rebase" : "merge"
            CLIBridge.eprintln("would \(verb) onto '\(baseLabel)' — ahead \(ahead), behind \(behind)")
        }
        _ = taskName
    }

    private func printOutcome(_ outcome: SyncService.Outcome, taskName: String) {
        let strategyLabel = outcome.strategy == .rebase ? "rebase" : "merge"

        if outcome.dryRun {
            print("dry-run: would \(strategyLabel) 'agent/\(taskName)' onto '\(outcome.baseLabel)' (\(outcome.baseSHA.prefix(7)))")
            print("  ahead:  \(outcome.aheadCount) commit\(outcome.aheadCount == 1 ? "" : "s")")
            print("  behind: \(outcome.behindCount) commit\(outcome.behindCount == 1 ? "" : "s")")
            return
        }

        if outcome.appliedCommits == 0 && outcome.behindCount == 0 {
            // No-op success. The progress event already said so; keep
            // stdout minimal. (One stable line so scripts can grep.)
            print("up-to-date 'agent/\(taskName)' onto '\(outcome.baseLabel)' (\(outcome.baseSHA.prefix(7)))")
            return
        }

        print("✓ \(strategyLabel)d 'agent/\(taskName)' onto '\(outcome.baseLabel)' (\(outcome.baseSHA.prefix(7)))")
        print("  applied: \(outcome.appliedCommits) commit\(outcome.appliedCommits == 1 ? "" : "s")")
    }
}
