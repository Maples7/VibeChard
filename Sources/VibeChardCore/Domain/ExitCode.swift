import Foundation

/// Stable exit-code mapping per the v1 plan (Q9).
///
/// 0   success
/// 1   business error (already exists / not found / dirty / unmerged / …)
/// 2   usage error (invalid args, reserved name, …)
/// 3   external command failed (git / xcodebuild / simctl)
/// 130 propagated SIGINT (set by signal handler, not this enum)
public enum ExitCode {
    public static let success: Int32 = 0
    public static let business: Int32 = 1
    public static let usage: Int32 = 2
    public static let external: Int32 = 3
    public static let interrupted: Int32 = 130
}

public extension VibeChardError {
    /// Map an error to its conventional exit code.
    var exitCode: Int32 {
        switch self {
           case .invalidTaskName, .missingArgument, .xcodebuildContainerConflict,
               .landConflictingStrategies, .newConflictingCdExec,
             .testConflictingRerunFlags, .testRerunWithExtraArgs, .invalidRuntime:
            return ExitCode.usage
        case .worktreeAlreadyExists,
             .taskNotFound,
             .worktreeNotAGitRepository,
             .dirtyWorktree,
             .unmergedBranch,
             .stateFileCorrupt,
             .stateSchemaMismatch,
             .stateFileMissing,
             .adoptCurrentRequiresLinkedWorktree,
             .adoptCurrentAlreadyManaged,
             .simulatorTemplateNotFound,
             .simulatorAlreadyBound,
             .simulatorBindingAmbiguous,
             .simulatorBindingPlatformUnavailable,
             .simulatorPlatformUnknown,
             .simulatorTemplateBooted,
             .warmTemplateAlreadyExists,
             .worktreeBusy,
             .logFileMissing,
             .landMainNotOnInto,
             .landMergeOverlap,
             .landNoOp,
             .landNoIntoInferred,
             .landBranchMissing,
             .runBundleIDNotFound,
             .runAppBundleNotFound,
             .cleanBlockedByHolders,
             .cleanBlockedByTestSession,
             .syncBaseUnresolved,
             .syncDirtyWorktree,
             .testNoPriorRun,
             .testNoPriorFailures,
             .seedSourceTaskNotFound,
             .seedSourceHasNoSwiftPMCache:
            return ExitCode.business
        case .externalCommandFailed,
             .syncRebaseConflict:
            return ExitCode.external
        }
    }
}
