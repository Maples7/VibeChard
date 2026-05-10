import Foundation

/// Pure-text classifier for failure modes of `xcrun simctl clone`.
///
/// The protocol-backed `SimctlClient.clone` returns
/// `VibeChardError.externalCommandFailed(cmd:exitCode:stderr:)` for any
/// non-zero exit, which is the right *raw* shape — vch lifts the typed
/// reason out of `stderr` here so callers (`SimulatorService`) can
/// branch on the cause without each one re-parsing the same text.
///
/// We keep this in `Logic/` (not `System/`) because it has no IO and is
/// trivially unit-testable from a fake stderr string. The matched
/// substring is what `simctl clone` emits as of Xcode 16, e.g.:
///
///     An error was encountered processing the command (domain=…, code=149):
///     Unable to clone device in current state: Booted
///
/// (#66)
public enum SimctlCloneErrors {
    /// True iff `stderr` carries the exact phrase simctl uses to refuse
    /// cloning a booted device. Matching is intentionally substring-only:
    /// simctl prefixes the message with locale-independent diagnostic
    /// noise that is not contractually stable, so we anchor on the
    /// noun phrase instead. False matches are vanishingly unlikely
    /// because the phrase contains both "clone device" and "Booted",
    /// but the cost of a false negative is just losing the typed-error
    /// improvement — we still raise `externalCommandFailed`, which
    /// continues to print the full stderr.
    public static func isTemplateBooted(stderr: String) -> Bool {
        return stderr.contains("Unable to clone device in current state: Booted")
    }
}
