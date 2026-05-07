import ArgumentParser
import Foundation
import VibeChardCore

/// `vch land <name>` — merge a task branch back into its base, then
/// remove the task worktree. Default strategy is `--no-ff`. Pre-flight
/// refuses on overlapping dirty state, no-op merges, and a wrong main
/// branch. (#7)
struct LandCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "land",
        abstract: "Merge a task branch back into its base and remove the worktree."
    )

    @Argument(help: "Task name to land.",
              completion: .custom(TaskNameCompletion.candidates))
    var name: String

    @Option(name: .long,
            help: "Branch to merge into. Defaults to the branch the main worktree was on at `vch new`, or the current branch if unrecorded.")
    var into: String?

    @Flag(name: .long,
          help: "Always create a merge commit (default).")
    var noFf: Bool = false

    @Flag(name: .long,
          help: "Refuse if a fast-forward isn't possible.")
    var ffOnly: Bool = false

    @Flag(name: .long,
          help: "Squash the task branch's commits into a single commit on `--into`.")
    var squash: Bool = false

    @Option(name: .long,
            help: "Override the default merge commit message.")
    var message: String?

    @Flag(name: .long,
          help: "Don't remove the worktree after a successful merge.")
    var keep: Bool = false

    @Flag(name: .long,
          help: "Allow merging even if the main worktree has dirty paths that overlap with the task branch's diff.")
    var allowDirty: Bool = false

    @Flag(name: .long,
          help: "Print the planned merge but don't modify any branches.")
    var dryRun: Bool = false

    func run() throws {
        try CLIBridge.run {
            let task = try TaskName(name)
            let cwd = FileManager.default.currentDirectoryPath
            let workspace = try WorkspaceLocator.locate(cwd: cwd)

            let strategyCount = [noFf, ffOnly, squash].filter { $0 }.count
            if strategyCount > 1 {
                throw VibeChardError.landConflictingStrategies
            }
            let strategy: LandPlan.Strategy = ffOnly ? .ffOnly
                : squash ? .squash
                : .noFF

            let service = LandService(workspace: workspace, git: DiskGitClient())
            let outcome = try service.land(task, options: .init(
                into: into,
                strategy: strategy,
                message: message,
                allowDirty: allowDirty,
                dryRun: dryRun,
                keep: keep
            ))

            printOutcome(outcome, taskName: task.raw)
        }
    }

    private func printOutcome(_ outcome: LandService.Outcome, taskName: String) {
        let strategyLabel: String
        switch outcome.strategy {
        case .noFF:   strategyLabel = "--no-ff"
        case .ffOnly: strategyLabel = "--ff-only"
        case .squash: strategyLabel = "--squash"
        }

        if !outcome.merged {
            // --dry-run path. Spell out exactly what would happen.
            print("would land 'agent/\(taskName)' into '\(outcome.into)' (\(strategyLabel))")
            print("  message: \(outcome.message)")
            if outcome.touchedPaths.isEmpty {
                print("  touched: <none>")
            } else {
                print("  touched: \(outcome.touchedPaths.count) file\(outcome.touchedPaths.count == 1 ? "" : "s")")
                for path in outcome.touchedPaths.prefix(20) {
                    print("    \(path)")
                }
                if outcome.touchedPaths.count > 20 {
                    print("    … (+\(outcome.touchedPaths.count - 20) more)")
                }
            }
            return
        }

        print("✓ merged 'agent/\(taskName)' into '\(outcome.into)' (\(strategyLabel))")
        print("  message: \(outcome.message)")
        if outcome.removed {
            print("✓ removed worktree")
        } else if let err = outcome.removeError {
            CLIBridge.eprintln("warning: merge succeeded but worktree removal failed: \(err)")
            CLIBridge.eprintln("        run `vch rm \(taskName)` after fixing the issue")
        } else {
            print("  worktree kept (--keep)")
        }
    }
}
