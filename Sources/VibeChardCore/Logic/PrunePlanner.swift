import Foundation

/// Pure logic layer for `vch prune` (#67). Takes a snapshot of every
/// managed task — its summary, computed `GitStatus`, and any current
/// process holders inside the worktree — and decides how to bucket it:
///
/// - `prunable`   — branch is fully merged into its base, worktree is
///                  clean, and nothing holds files inside. Safe to
///                  `vch rm` with default options.
/// - `unmerged`   — branch is not (yet) fully merged into its base, or
///                  the merged status couldn't be determined. Skip.
/// - `dirty`      — branch is merged but the worktree has uncommitted
///                  changes. Skip unless the user explicitly opts in
///                  with `--allow-dirty`.
/// - `held`       — branch is merged but at least one process is
///                  holding files inside the worktree (open editor,
///                  shell, running `vch run`). Skip unless `--force`.
///
/// `vch prune` then renders the plan and either dry-runs (default) or
/// applies it via `TaskService.removeTask`.
public enum PrunePlanner {
    /// One row of decision input. Caller is responsible for populating
    /// `gitStatus.mergedIntoBase`; if it is `nil`, the row is treated
    /// as `.unmerged` (we never silently prune branches whose merge
    /// status we couldn't compute).
    public struct Input: Sendable, Equatable {
        public let summary: TaskSummary
        public let holders: [WorktreeHolder]

        public init(summary: TaskSummary, holders: [WorktreeHolder]) {
            self.summary = summary
            self.holders = holders
        }
    }

    /// Why a task ended up in a non-prunable bucket. Used by the CLI
    /// to render a one-line per-task explanation.
    public enum SkipReason: Sendable, Equatable {
        /// `gitStatus.mergedIntoBase == nil` — usually means no
        /// recorded base branch (detached-HEAD `vch new`) or a
        /// transient git failure. We refuse to guess.
        case mergeStatusUnknown
        /// Branch has commits not yet on its base.
        case notMerged(aheadCount: Int)
        /// `git status --porcelain` produced output.
        case dirty
        /// `lsof +D` reported at least one holder.
        case heldOpen(holders: [WorktreeHolder])
    }

    /// One bucketed task in the resulting plan.
    public struct Decision: Sendable, Equatable {
        public let summary: TaskSummary
        /// `nil` iff the task is prunable.
        public let skip: SkipReason?

        public init(summary: TaskSummary, skip: SkipReason?) {
            self.summary = summary
            self.skip = skip
        }

        public var isPrunable: Bool { skip == nil }
    }

    /// Output of a planning run.
    public struct Plan: Sendable, Equatable {
        public let decisions: [Decision]

        public init(decisions: [Decision]) {
            self.decisions = decisions
        }

        public var prunable: [Decision] { decisions.filter { $0.isPrunable } }
        public var skipped:  [Decision] { decisions.filter { !$0.isPrunable } }
    }

    /// Knobs that loosen the default "only fully-merged, clean,
    /// nobody-is-using-it" rule.
    public struct Options: Sendable, Equatable {
        /// Allow pruning even when the worktree has uncommitted
        /// changes. Maps onto `vch rm --allow-dirty` downstream.
        public let allowDirty: Bool
        /// Allow pruning even when something has files open inside
        /// the worktree. Maps onto `vch rm --force` downstream.
        public let force: Bool

        public init(allowDirty: Bool = false, force: Bool = false) {
            self.allowDirty = allowDirty
            self.force = force
        }
    }

    /// Bucket every input. Order is preserved so the CLI can render
    /// rows in the same order as `vch list` (newest first).
    public static func plan(
        inputs: [Input],
        options: Options = Options()
    ) -> Plan {
        let decisions = inputs.map { input in
            decide(input: input, options: options)
        }
        return Plan(decisions: decisions)
    }

    private static func decide(input: Input, options: Options) -> Decision {
        let s = input.summary
        // Merge status is the gating check. Anything we can't
        // confidently call "fully merged" stays untouched.
        guard let merged = s.gitStatus?.mergedIntoBase else {
            return Decision(summary: s, skip: .mergeStatusUnknown)
        }
        if !merged {
            // `aheadCount` should be present if `mergedIntoBase` is
            // false (both come from the same `git rev-list` call),
            // but fall back to 1 so the message stays meaningful if
            // the wiring ever drifts.
            let ahead = s.gitStatus?.aheadCount ?? 1
            return Decision(summary: s, skip: .notMerged(aheadCount: ahead))
        }
        if (s.gitStatus?.isDirty ?? false), !options.allowDirty {
            return Decision(summary: s, skip: .dirty)
        }
        if !input.holders.isEmpty, !options.force {
            return Decision(summary: s, skip: .heldOpen(holders: input.holders))
        }
        return Decision(summary: s, skip: nil)
    }
}
