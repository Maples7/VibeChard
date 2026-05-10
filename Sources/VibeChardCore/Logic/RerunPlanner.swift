import Foundation

/// Pure logic for #46 (`vch test --rerun` / `--rerun-failed`).
///
/// The interesting decision here is what to do with the *prior* extra
/// args when narrowing to failed tests. Two cases motivate the rule:
///
///   1. Last invocation was `vch test foo -- -only-testing:Suite/A`
///      and `Suite/A` failed. `--rerun-failed` should produce
///      `-only-testing:Suite/A` again — i.e. drop the prior filter
///      and substitute the failure-derived ones, even when they
///      happen to be identical.
///
///   2. Last invocation was `vch test foo -- -parallel-testing-enabled NO`
///      and a few tests failed. The `-parallel-testing-enabled` flag
///      is orthogonal to test selection — it must be preserved so the
///      rerun behaves like the run that produced the failures.
///
/// So the rule is: keep everything except `-only-testing:` and
/// `-skip-testing:` selectors (both colon-prefixed and the rare
/// space-separated form), then append `-only-testing:<id>` for each
/// failure identifier.
///
/// All work is pure; no IO. Inputs are already-resolved arrays of
/// strings — one per argv slot — and the output is the new argv.
public enum RerunPlanner {

    /// Strip selector flags (`-only-testing:*`, `-skip-testing:*`,
    /// and their space-separated variants) from `prior`, then append
    /// `-only-testing:<id>` for each `failureIdentifier`. Order of
    /// surviving prior args is preserved; new selectors are appended
    /// at the tail.
    ///
    /// Returns an empty array iff `failureIdentifiers` is empty AND
    /// `prior` had nothing to keep — callers should generally treat
    /// the empty-failures case as `VibeChardError.testNoPriorFailures`
    /// and not call this function at all in that scenario, but the
    /// function itself is total.
    public static func extraArgsForRerunFailed(
        prior: [String],
        failureIdentifiers: [String]
    ) -> [String] {
        var kept: [String] = []
        var i = 0
        while i < prior.count {
            let arg = prior[i]
            if isSelectorFlag(arg) {
                // colon-prefixed form: `-only-testing:Foo` is one
                // argv slot, drop it.
                i += 1
                continue
            }
            if isSelectorFlagBare(arg) {
                // space-separated form: `-only-testing` `Foo` is two
                // argv slots, drop both. Guard the index so a
                // trailing `-only-testing` with no value doesn't
                // crash — just drop the dangling flag.
                i += 1
                if i < prior.count { i += 1 }
                continue
            }
            kept.append(arg)
            i += 1
        }
        // Dedupe identifiers — xcodebuild treats duplicates the same
        // way but the user-facing log line gets cleaner.
        var seen = Set<String>()
        var uniqueIDs: [String] = []
        for id in failureIdentifiers where !seen.contains(id) {
            seen.insert(id)
            uniqueIDs.append(id)
        }
        return kept + uniqueIDs.map { "-only-testing:\($0)" }
    }

    private static func isSelectorFlag(_ arg: String) -> Bool {
        arg.hasPrefix("-only-testing:") || arg.hasPrefix("-skip-testing:")
    }

    private static func isSelectorFlagBare(_ arg: String) -> Bool {
        arg == "-only-testing" || arg == "-skip-testing"
    }

    /// Repair a `testIdentifierString` so it round-trips through
    /// `xcodebuild -only-testing:` (#64).
    ///
    /// Background: under some Xcode 16 swift-testing configurations
    /// xcresulttool emits `Suite/Case()` (two segments) instead of
    /// the documented `Target/Suite/Case()` (three). Feeding the
    /// short form back to xcodebuild fails because the first
    /// segment is parsed as the test-target name, which doesn't
    /// exist (e.g. `Tests in the target "CloudSyncStatusCenterGraceTests"
    /// can't be run because "CloudSyncStatusCenterGraceTests" isn't a
    /// member of the specified test plan or scheme.`).
    ///
    /// Rule:
    ///   • `targetName` empty  → return raw (no info to repair with).
    ///   • `raw` empty         → return raw.
    ///   • first segment of `raw` matches `targetName` exactly
    ///                         → return raw (already prefixed).
    ///   • otherwise           → prepend `targetName + "/"`.
    ///
    /// The check is deliberately exact-match: an identifier whose
    /// first segment looks like a target name but isn't this one
    /// (e.g. when xcodebuild's test plan ships multiple test
    /// targets) is left alone — that case is rare and over-eager
    /// rewriting would risk double-prefixing legitimate three-segment
    /// identifiers.
    public static func normalizeIdentifier(_ raw: String, targetName: String) -> String {
        guard !raw.isEmpty, !targetName.isEmpty else { return raw }
        let firstSegment = raw.split(separator: "/", maxSplits: 1,
                                      omittingEmptySubsequences: false).first
        if firstSegment.map(String.init) == targetName {
            return raw
        }
        return "\(targetName)/\(raw)"
    }
}
