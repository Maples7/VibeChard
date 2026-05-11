import Foundation

/// Merge first-class `--only-testing` / `--skip-testing` selectors
/// (added in response to #86) with any positional `extra` args the
/// user passed after `--`. The output is what gets appended to
/// `xcodebuild test`.
///
/// Background: `xcodebuild` exposes test selection via `-only-testing`
/// and `-skip-testing`, but those are *single-dash* flags. Users
/// (including AI agents) repeatedly typed `vch test … --only-testing
/// <id>` and got an "Unknown option" error from ArgumentParser
/// because vch never claimed those names. The pre-#86 ergonomic
/// answer was "pass it after `--` with a single dash", which is
/// correct but easy to miss — both the `--` separator and the
/// single-dash xcodebuild form are non-obvious. #86 makes
/// `--only-testing <id>` and `--skip-testing <id>` first-class
/// repeatable flags on `vch test` that this helper translates to the
/// canonical `xcodebuild` form.
///
/// Output form: `-only-testing:<id>` / `-skip-testing:<id>` (colon).
/// xcodebuild accepts both colon and space forms; we pick the colon
/// form because (a) it keeps each selector to one argv slot, which is
/// easier to log/diff, and (b) it matches what `RerunPlanner` already
/// emits for `--rerun-failed`, so the recorded `extraArgs` round-trip
/// through `--rerun` consistently.
public enum TestSelectorMerger {

    /// Combine selector flags + verbatim extras into a single argv to
    /// append after `xcodebuild test …`.
    ///
    /// - Parameters:
    ///   - only: identifiers for `-only-testing:<id>` (repeatable).
    ///   - skip: identifiers for `-skip-testing:<id>` (repeatable).
    ///   - extra: positional args from after `--`, forwarded verbatim
    ///     so power users keep full xcodebuild flexibility.
    /// - Returns: argv slice in stable order — `only`, then `skip`,
    ///   then `extra`. xcodebuild treats `-only-testing` as set
    ///   union and `-skip-testing` as set difference, so order is
    ///   not semantically significant; we pick one for predictable
    ///   logs.
    public static func extraArgs(
        only: [String],
        skip: [String],
        extra: [String]
    ) -> [String] {
        var out: [String] = []
        out.reserveCapacity(only.count + skip.count + extra.count)
        for id in only { out.append("-only-testing:\(id)") }
        for id in skip { out.append("-skip-testing:\(id)") }
        out.append(contentsOf: extra)
        return out
    }
}
