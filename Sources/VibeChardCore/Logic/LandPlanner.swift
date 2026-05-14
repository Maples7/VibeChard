import Foundation

/// Pure-data result of evaluating `vch land`'s pre-flight + message
/// resolution against a snapshot of git state. Kept separate from
/// `LandService` so the decision tree is unit-testable without a real
/// repo on disk. (#7)
public enum LandPlan {
    /// Strategy flags, mirroring `--no-ff|--ff-only|--squash`.
    public enum Strategy: String, Sendable, Equatable {
        case noFF
        case ffOnly
        case squash
    }

    /// Inputs to the planner — everything the planner needs to decide,
    /// already gathered from disk by `LandService`. No git or
    /// filesystem calls happen inside the planner.
    public struct Inputs: Equatable, Sendable {
        public let task: TaskName
        /// The actual git branch being merged. For vch-created tasks
        /// this equals `task.branchName` (`agent/<name>`); for tasks
        /// adopted via `vch new [<name>] --adopt-current` it's whatever
        /// branch was checked out at adopt time (e.g. `feature/codex`).
        /// Used in the merge commit message and the `noOp` reason so
        /// both reflect the branch git actually operates on, not the
        /// vch task name. (#98 follow-up)
        public let taskBranch: String
        public let intoOption: String?
        public let recordedBaseBranch: String?
        public let currentMainBranch: String?
        public let strategy: Strategy
        public let userMessage: String?
        public let allowDirty: Bool
        public let dryRun: Bool
        public let removeAfter: Bool
        public let dirtyPathsOnMain: [String]
        public let taskDiffPaths: [String]
        public let taskAheadCount: Int
        public let taskHeadSubject: String?

        public init(
            task: TaskName,
            taskBranch: String,
            intoOption: String?,
            recordedBaseBranch: String?,
            currentMainBranch: String?,
            strategy: Strategy,
            userMessage: String?,
            allowDirty: Bool,
            dryRun: Bool,
            removeAfter: Bool,
            dirtyPathsOnMain: [String],
            taskDiffPaths: [String],
            taskAheadCount: Int,
            taskHeadSubject: String?
        ) {
            self.task = task
            self.taskBranch = taskBranch
            self.intoOption = intoOption
            self.recordedBaseBranch = recordedBaseBranch
            self.currentMainBranch = currentMainBranch
            self.strategy = strategy
            self.userMessage = userMessage
            self.allowDirty = allowDirty
            self.dryRun = dryRun
            self.removeAfter = removeAfter
            self.dirtyPathsOnMain = dirtyPathsOnMain
            self.taskDiffPaths = taskDiffPaths
            self.taskAheadCount = taskAheadCount
            self.taskHeadSubject = taskHeadSubject
        }
    }

    /// Final, executable plan after every pre-flight check passed.
    public struct Resolved: Equatable, Sendable {
        public let into: String
        public let strategy: Strategy
        public let message: String
        public let removeAfter: Bool
        public let dryRun: Bool

        public init(
            into: String,
            strategy: Strategy,
            message: String,
            removeAfter: Bool,
            dryRun: Bool
        ) {
            self.into = into
            self.strategy = strategy
            self.message = message
            self.removeAfter = removeAfter
            self.dryRun = dryRun
        }
    }

    /// Decision the planner returned. `proceed` carries everything
    /// `LandService` needs to invoke git; `abort` carries enough
    /// context for `LandService` to throw a typed `VibeChardError`.
    public enum Decision: Equatable, Sendable {
        case proceed(Resolved)
        case abort(Reason)

        public enum Reason: Equatable, Sendable {
            case mainNotOnInto(currentBranch: String?, want: String)
            case mergeOverlap(paths: [String])
            case noOp(taskBranch: String, into: String)
            case noIntoInferred
        }
    }
}

public enum LandPlanner {
    /// Evaluate the inputs and return either a fully-resolved plan or
    /// a reason for aborting.
    public static func plan(_ inputs: LandPlan.Inputs) -> LandPlan.Decision {
        // Resolve `--into`. Priority: explicit option → recorded base
        // branch from state.json → current branch on the main worktree.
        // If all three are nil (detached HEAD + brand-new state.json
        // schema migration), refuse rather than guess.
        let resolvedInto: String?
        if let explicit = inputs.intoOption, !explicit.isEmpty {
            resolvedInto = explicit
        } else if let recorded = inputs.recordedBaseBranch, !recorded.isEmpty {
            resolvedInto = recorded
        } else {
            resolvedInto = inputs.currentMainBranch
        }
        guard let into = resolvedInto else {
            return .abort(.noIntoInferred)
        }

        // Main worktree's HEAD must equal `into`. Detached HEAD or a
        // sibling branch both fail. We do not auto-checkout.
        if inputs.currentMainBranch != into {
            return .abort(.mainNotOnInto(
                currentBranch: inputs.currentMainBranch,
                want: into
            ))
        }

        // Task branch must be strictly ahead of `into`.
        if inputs.taskAheadCount == 0 {
            return .abort(.noOp(
                taskBranch: inputs.taskBranch,
                into: into
            ))
        }

        // Refuse when dirty paths in the main worktree intersect the
        // task branch's diff. Non-overlapping dirty state is fine.
        if !inputs.allowDirty {
            let dirty = Set(inputs.dirtyPathsOnMain)
            let diff = Set(inputs.taskDiffPaths)
            let overlap = dirty.intersection(diff)
            if !overlap.isEmpty {
                return .abort(.mergeOverlap(paths: overlap.sorted()))
            }
        }

        // Resolve the merge commit message. Use `taskBranch` (which is
        // `agent/<name>` for vch-created tasks and whatever the user
        // adopted for `--adopt-current` tasks) so the commit log
        // accurately names the branch that was merged. (#98 follow-up)
        let message: String
        if let user = inputs.userMessage, !user.isEmpty {
            message = user
        } else if let subject = inputs.taskHeadSubject, !subject.isEmpty {
            message = "Merge \(inputs.taskBranch): \(subject)"
        } else {
            // No commits with a usable subject (extremely rare — branch
            // exists but only has merge commits). Fall back to a stable
            // default.
            message = "Merge \(inputs.taskBranch)"
        }

        return .proceed(LandPlan.Resolved(
            into: into,
            strategy: inputs.strategy,
            message: message,
            removeAfter: inputs.removeAfter,
            dryRun: inputs.dryRun
        ))
    }
}
