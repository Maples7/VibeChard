import Foundation

public struct TestExecutionHangDiagnostic: Equatable, Sendable {
    public struct Simulator: Equatable, Sendable {
        public let name: String
        public let udid: String
        public let state: String
        public let runtime: String?

        public init(name: String, udid: String, state: String, runtime: String?) {
            self.name = name
            self.udid = udid
            self.state = state
            self.runtime = runtime
        }
    }

    public let taskName: String
    public let pid: Int32
    public let idleSeconds: Double
    public let elapsedSeconds: Double
    public let command: [String]
    public let simulator: Simulator?
    public let logPath: String
    public let resultBundlePath: String

    public init(
        taskName: String,
        pid: Int32,
        idleSeconds: Double,
        elapsedSeconds: Double,
        command: [String],
        simulator: Simulator?,
        logPath: String,
        resultBundlePath: String
    ) {
        self.taskName = taskName
        self.pid = pid
        self.idleSeconds = idleSeconds
        self.elapsedSeconds = elapsedSeconds
        self.command = command
        self.simulator = simulator
        self.logPath = logPath
        self.resultBundlePath = resultBundlePath
    }

    public func render() -> String {
        var lines: [String] = []
        lines.append("✗ test execution did not complete: no xcodebuild output for \(format(idleSeconds)) after tests started")
        lines.append("   task: \(taskName)")
        lines.append("   xcodebuild PID: \(pid)")
        lines.append("   elapsed: \(format(elapsedSeconds))")
        if let simulator {
            let runtime = simulator.runtime.map { ", runtime: \($0)" } ?? ""
            lines.append("   simulator: \(simulator.name) (\(simulator.udid), state: \(simulator.state)\(runtime))")
        } else {
            lines.append("   simulator: none resolved by vch")
        }
        lines.append("   command: \(command.map(shellQuote).joined(separator: " "))")
        lines.append("   log: \(logPath)")
        lines.append("   result: \(resultBundlePath)")
        lines.append("   recovery:")
        let processPattern = [taskName, String(pid), "xcodebuild", "xctest"]
            .map(regexEscape)
            .joined(separator: "|")
        lines.append("     ps -axo pid,etime,stat,command | rg \(shellQuote(processPattern))")
        lines.append("     vch clean \(shellQuote(taskName)) --kill-stuck-tests")
        lines.append("     For compile-only evidence, rerun the command above with the final xcodebuild action replaced by build-for-testing.")
        return lines.joined(separator: "\n")
    }

    private func format(_ seconds: Double) -> String {
        if seconds < 10 {
            return String(format: "%.1fs", seconds)
        }
        return String(format: "%.0fs", seconds)
    }

    /// Escapes user-facing labels before embedding them in an `rg` pattern.
    /// The rendered command should match literals, not regex metacharacters.
    private func regexEscape(_ value: String) -> String {
        NSRegularExpression.escapedPattern(for: value)
    }

    /// Single-quotes a shell argument and escapes embedded single quotes.
    /// Leaves simple path/flag tokens bare so diagnostics remain readable.
    private func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:=+-")
        if value.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}