import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// ANSI color/style support for human-readable CLI output.
///
/// Policy (matches widely-used CLI conventions):
///
/// 1. `NO_COLOR` set (any non-empty value) — colors **off**, period.
///    See https://no-color.org. Wins over everything else.
/// 2. `CLICOLOR_FORCE` or `FORCE_COLOR` set to a non-empty, non-"0"
///    value — colors **on**, even when stdout is not a TTY (useful
///    when piping to `less -R` or capturing styled output).
/// 3. Otherwise: colors **on** iff stdout is a TTY.
///
/// The decision is pure (env + TTY bool in, Bool out) so it is fully
/// unit-testable without touching real file descriptors. The CLI calls
/// `ANSI.shouldColorize(env:stdoutIsTTY:)` once at startup and threads
/// the result down to formatters.
///
/// Machine-readable output (e.g. `--json`) MUST NOT use this — JSON
/// stays pristine regardless of the policy above.
public enum ANSI {

    // MARK: - Policy

    /// Pure decision function. No I/O, no globals. Safe to unit-test.
    public static func shouldColorize(
        env: [String: String],
        stdoutIsTTY: Bool
    ) -> Bool {
        // 1. NO_COLOR wins.
        if let v = env["NO_COLOR"], !v.isEmpty {
            return false
        }
        // 2. Explicit force-on.
        if isForceEnabled(env["CLICOLOR_FORCE"]) ||
           isForceEnabled(env["FORCE_COLOR"]) {
            return true
        }
        // 3. Default: only when attached to a terminal.
        return stdoutIsTTY
    }

    private static func isForceEnabled(_ raw: String?) -> Bool {
        guard let v = raw, !v.isEmpty else { return false }
        // Treat "0" / "false" / "no" as "do not force". Anything else
        // (including "1", "true", "yes", "always") opts in.
        switch v.lowercased() {
        case "0", "false", "no", "off": return false
        default: return true
        }
    }

    /// Convenience for callers that want to snapshot the current
    /// process state. Reads `ProcessInfo.environment` and `isatty(1)`.
    public static func defaultEnabledForStdout() -> Bool {
        #if canImport(Darwin)
        let tty = isatty(fileno(stdout)) != 0
        #else
        let tty = false
        #endif
        return shouldColorize(
            env: ProcessInfo.processInfo.environment,
            stdoutIsTTY: tty
        )
    }

    // MARK: - Styles

    /// Semantic styles. We stick to ANSI bright variants to roughly
    /// approximate the soft pastel palette in the marketing assets,
    /// while still mapping cleanly onto every user's terminal theme
    /// (Terminal.app, iTerm2, VS Code, etc. all let users redefine
    /// these). Avoid 256-color or truecolor — they look garish in
    /// some themes and don't compose with user preferences.
    public enum Style {
        /// Reset / no-op. Useful as a sentinel.
        case none
        /// Table headers: gray + bold.
        case header
        /// Task names: bright blue + bold.
        case name
        /// Branch refs: bright magenta (closest standard ANSI to lavender).
        case branch
        /// Simulator names: bright yellow.
        case sim
        /// Success: bright green + bold.
        case ok
        /// Failure: bright red + bold.
        case fail
        /// Placeholder values like "-": dim.
        case placeholder

        fileprivate var codes: [Int] {
            switch self {
            case .none: return []
            case .header: return [1, 90]   // bold + bright black (gray)
            case .name: return [1, 94]     // bold + bright blue
            case .branch: return [95]      // bright magenta
            case .sim: return [93]         // bright yellow
            case .ok: return [1, 92]       // bold + bright green
            case .fail: return [1, 91]     // bold + bright red
            case .placeholder: return [2]  // dim
            }
        }
    }

    /// Wrap `s` in the SGR codes for `style`. Returns `s` unchanged
    /// when `enabled` is false or the style has no codes.
    public static func wrap(_ s: String, _ style: Style, enabled: Bool) -> String {
        guard enabled else { return s }
        let codes = style.codes
        guard !codes.isEmpty else { return s }
        let prefix = "\u{001B}[" + codes.map(String.init).joined(separator: ";") + "m"
        let suffix = "\u{001B}[0m"
        return prefix + s + suffix
    }
}
