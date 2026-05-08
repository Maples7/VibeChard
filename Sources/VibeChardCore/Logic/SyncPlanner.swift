import Foundation

/// Pure-data result of evaluating `vch sync`'s post-fetch decision
/// tree. Kept separate from `SyncService` so the rebase-vs-noop
/// decision is unit-testable without a real repo on disk. (#25)
///
/// Intentionally narrower than `LandPlan`: the abort cases that map
/// to `syncBaseUnresolved` and `syncDirtyWorktree` are caught by
/// `SyncService` *before* IO happens (cheap, local checks) — there's
/// no logic worth modelling in the planner for them. The planner
/// owns only the post-IO branch: "behind == 0 → no-op" vs "behind > 0
/// → proceed".
public enum SyncPlan {
    /// How to bring `agent/<name>` up to date with `<base>`.
    public enum Strategy: String, Sendable, Equatable {
        /// `git rebase <base>` — replays task commits on top of base.
        /// Default; safe because vch task branches are not shared.
        case rebase
        /// `git merge --no-ff <base>` — preserves the task branch tip.
        /// Used when the user has manually pushed `agent/<name>` and
        /// rewriting history would break a remote.
        case merge
    }

    /// Inputs to the planner. `SyncService` gathers everything (incl.
    /// the resolved base SHA and ahead/behind counts) before calling
    /// the planner — so the planner does no IO.
    public struct Inputs: Equatable, Sendable {
        public let strategy: Strategy
        /// The label to *display* (e.g. `origin/main`, or whatever
        /// the user passed via `--onto`). Recorded in
        /// `lastSync.baseLabel`.
        public let baseLabel: String
        /// The 40-char commit SHA `baseLabel` resolved to via
        /// `git rev-parse`. Recorded in `lastSync.baseSHA` because
        /// labels drift but SHAs are stable historical fact.
        public let baseSHA: String
        /// `git rev-list --count <baseSHA>..agent/<task>`. Number of
        /// task commits not yet on base.
        public let aheadCount: Int
        /// `git rev-list --count agent/<task>..<baseSHA>`. Number of
        /// base commits the task branch hasn't yet absorbed. `0`
        /// means already up to date — the planner returns `.noop`.
        public let behindCount: Int
        public let dryRun: Bool

        public init(
            strategy: Strategy,
            baseLabel: String,
            baseSHA: String,
            aheadCount: Int,
            behindCount: Int,
            dryRun: Bool
        ) {
            self.strategy = strategy
            self.baseLabel = baseLabel
            self.baseSHA = baseSHA
            self.aheadCount = aheadCount
            self.behindCount = behindCount
            self.dryRun = dryRun
        }
    }

    /// Final, executable plan.
    public struct Resolved: Equatable, Sendable {
        public let strategy: Strategy
        public let baseLabel: String
        public let baseSHA: String
        public let aheadCount: Int
        public let behindCount: Int
        public let dryRun: Bool

        public init(
            strategy: Strategy,
            baseLabel: String,
            baseSHA: String,
            aheadCount: Int,
            behindCount: Int,
            dryRun: Bool
        ) {
            self.strategy = strategy
            self.baseLabel = baseLabel
            self.baseSHA = baseSHA
            self.aheadCount = aheadCount
            self.behindCount = behindCount
            self.dryRun = dryRun
        }
    }

    public enum Decision: Equatable, Sendable {
        /// `behindCount == 0` — task branch is already at or ahead of
        /// base. `SyncService` writes `lastSync` with
        /// `appliedCommits == 0` and exits 0.
        case noop(Resolved)
        /// `behindCount > 0` — `SyncService` runs `git rebase` (or
        /// `git merge --no-ff`) using `Resolved.baseLabel`.
        case proceed(Resolved)
    }
}

public enum SyncPlanner {
    /// Translate post-IO inputs into a decision. Pure; trivially
    /// unit-testable.
    public static func plan(_ inputs: SyncPlan.Inputs) -> SyncPlan.Decision {
        let resolved = SyncPlan.Resolved(
            strategy: inputs.strategy,
            baseLabel: inputs.baseLabel,
            baseSHA: inputs.baseSHA,
            aheadCount: inputs.aheadCount,
            behindCount: inputs.behindCount,
            dryRun: inputs.dryRun
        )
        if inputs.behindCount == 0 {
            return .noop(resolved)
        }
        return .proceed(resolved)
    }
}
