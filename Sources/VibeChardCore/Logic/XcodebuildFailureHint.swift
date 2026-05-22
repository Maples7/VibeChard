import Foundation

/// Hints for recognizable xcodebuild failure modes where vch already
/// has a safer recovery command than making the user inspect the full
/// firehose. Pure string matching keeps the CLI shell thin and lets
/// unit tests pin the wording.
public enum XcodebuildFailureHint {
    /// High-level vch command whose xcodebuild log is being inspected.
    public enum Command: String, Sendable {
        case build
        case test
    }

    /// Return an actionable recovery hint when `logText` contains the
    /// CoreSimulator launch-preflight failure commonly surfaced as
    /// `SBMainWorkspace Busy`, or nil when the log does not match.
    public static func simulatorPreflightBusyHint(
        logText: String,
        command: Command,
        taskName: String,
        device: String?
    ) -> String? {
        guard isSimulatorPreflightBusy(logText) else { return nil }

        let resetCommand: String
        if let device, !device.isEmpty {
            resetCommand = "vch sim erase \(shellQuote(taskName)) --device \(shellQuote(device))"
        } else {
            resetCommand = "vch sim erase \(shellQuote(taskName)) --device <template-name>"
        }

        return """
        hint: xcodebuild reported SBMainWorkspace Busy (\"Application failed preflight checks\"). The per-task simulator clone may be wedged between install/launch attempts.
            rerun once with a clean clone: vch \(command.rawValue) \(shellQuote(taskName)) --erase-clone [same flags]
            or reset it explicitly: \(resetCommand)
        """
    }

    /// Return an actionable hint when xcodebuild's log indicates that
    /// the selected scheme could not resolve a simulator destination.
    public static func simulatorDestinationHint(
        logText: String,
        command: Command,
        taskName: String,
        scheme: String?
    ) -> String? {
        guard isSimulatorDestinationFailure(logText) else { return nil }

        let schemeFlag: String
        if let scheme, !scheme.isEmpty {
            schemeFlag = " --scheme \(shellQuote(scheme))"
        } else {
            schemeFlag = " --scheme <scheme>"
        }

        return """
        hint: xcodebuild could not select a simulator destination for this run.
            create or reuse a task clone: vch \(command.rawValue) \(shellQuote(taskName))\(schemeFlag) --device <template-name> [--runtime <version>]
            inspect available templates: xcrun simctl list devices available
        """
    }

    private static func isSimulatorPreflightBusy(_ logText: String) -> Bool {
        guard logText.contains("SBMainWorkspace") else { return false }
        let lower = logText.lowercased()
        return lower.contains("application failed preflight checks")
            || lower.contains("reason: busy")
    }

    private static func isSimulatorDestinationFailure(_ logText: String) -> Bool {
        let lower = logText.lowercased()
        return lower.contains("unable to find a destination")
            || lower.contains("found no destinations")
            || lower.contains("no destinations were found")
            || lower.contains("a destination must be specified")
            || lower.contains("requires a destination")
            || lower.contains("destination specifier")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}