import Foundation

/// Streaming parser for `xcodebuild build` output.
///
/// **Why this exists** (#48). `vch test` already routes xcodebuild
/// output through a streaming parser so the user only sees a concise
/// summary unless `--verbose` is set. `vch build`, by contrast, used
/// to stream the full xcodebuild firehose unconditionally — several
/// thousand lines for a clean build. In agent transcripts every
/// `vch build` invocation ended with `| tail -5` to recover the
/// `** BUILD SUCCEEDED **` line. This summarizer closes the asymmetry.
///
/// **Scope**: `xcodebuild` line-oriented stdout for build / archive
/// runs. We capture compiler diagnostics (Swift, Clang, linker, code
/// signing) and the final `** BUILD ... **` banner. We do not parse
/// per-target rollups — xcodebuild doesn't emit a stable per-target
/// duration line, and the summary line below is what the issue
/// actually requested.
///
/// The parser is intentionally tolerant: it does not throw on
/// unrecognized lines, never panics on malformed input, and degrades
/// gracefully to `Status.unknown` when xcodebuild prints output we
/// don't understand. The full firehose is always available in the
/// tee'd `last-build.log`.
public final class BuildOutputSummarizer {

    public enum Status: String, Sendable {
        case succeeded
        case failed
        case unknown
    }

    public struct Diagnostic: Equatable, Sendable {
        public enum Kind: String, Sendable { case error, warning }
        public let kind: Kind
        /// Absolute path the compiler reported. nil for tool-prefix
        /// diagnostics (e.g. `ld: error: ...`).
        public let file: String?
        public let line: Int?
        public let column: Int?
        /// The text after `error:` / `warning:`, verbatim.
        public let message: String

        public init(kind: Kind, file: String?, line: Int?, column: Int?, message: String) {
            self.kind = kind
            self.file = file
            self.line = line
            self.column = column
            self.message = message
        }
    }

    public private(set) var status: Status = .unknown
    public private(set) var diagnostics: [Diagnostic] = []

    public var errorCount: Int { diagnostics.lazy.filter { $0.kind == .error }.count }
    public var warningCount: Int { diagnostics.lazy.filter { $0.kind == .warning }.count }

    public init() {}

    // MARK: - Streaming

    /// Feed one log line (no trailing newline). Safe to call from a
    /// single thread; do not feed concurrently.
    public func feed(_ rawLine: String) {
        // Final status — check first so we don't waste time on regex.
        if rawLine.contains("** BUILD SUCCEEDED **") {
            status = .succeeded
            return
        }
        if rawLine.contains("** BUILD FAILED **") {
            status = .failed
            return
        }

        // `path/to/File.swift:42:9: error: <msg>` or
        // `path/to/File.swift:42: warning: <msg>` (column optional)
        if let d = parseFileDiagnostic(rawLine) {
            appendUnique(d)
            return
        }

        // `ld: error: <msg>` / `clang: warning: <msg>` (single-token
        // tool prefix). Filter out the ld INFO line `ld: warning:
        // ignoring duplicate libraries` — it's noise the linker emits
        // by default and floods the count.
        if let d = parseToolDiagnostic(rawLine) {
            appendUnique(d)
            return
        }

        // Anything else: ignore. Full text is still in last-build.log.
    }

    // MARK: - Render

    /// Render the human-readable summary printed when `--verbose` is
    /// off. Pass the wall-clock duration measured by `PlanLauncher`
    /// since xcodebuild doesn't emit a build-duration line on stdout.
    /// `logPath` (#69/#93) is the path to the tee'd
    /// `last-build.log`. When non-nil, the renderer appends a
    /// trailing `→ log: <path>` line so the full firehose remains
    /// visible even after a long agent transcript has moved past the
    /// launch banner.
    public func render(durationSeconds: Double, colorize: Bool, logPath: String? = nil) -> String {
        var out: [String] = []

        // On failure, list the errors first (the user's eye lands on
        // them). Cap at 20 — anything past that and the user wants
        // `--verbose` anyway.
        if status == .failed {
            let errs = diagnostics.filter { $0.kind == .error }
            for d in errs.prefix(20) {
                out.append(ANSI.wrap(formatDiagnostic(d), .fail, enabled: colorize))
            }
            if errs.count > 20 {
                out.append("    … (+\(errs.count - 20) more errors)")
            }
            if !errs.isEmpty {
                out.append("")
            }
        }

        let durStr = formatDuration(durationSeconds)
        let qualifier = qualifierText()
        let head: String
        switch status {
        case .succeeded:
            let body = qualifier.isEmpty
                ? "✓ build succeeded in \(durStr)   ** BUILD SUCCEEDED **"
                : "✓ build succeeded in \(durStr)   (\(qualifier))   ** BUILD SUCCEEDED **"
            head = ANSI.wrap(body, .ok, enabled: colorize)
        case .failed:
            let body = qualifier.isEmpty
                ? "✗ build failed in \(durStr)   ** BUILD FAILED **"
                : "✗ build failed in \(durStr)   (\(qualifier))   ** BUILD FAILED **"
            head = ANSI.wrap(body, .fail, enabled: colorize)
        case .unknown:
            head = "? build status unknown — see full log"
        }
        out.append(head)
        if let path = logPath, !path.isEmpty {
            out.append("   → log: \(path)")
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Internals

    private func appendUnique(_ d: Diagnostic) {
        // Cheap dedupe: xcodebuild sometimes repeats identical
        // diagnostics across re-runs of the same compile invocation.
        // Linear scan is fine — diagnostics arrays are ≤ a few hundred
        // entries even on broken builds.
        if !diagnostics.contains(d) {
            diagnostics.append(d)
        }
    }

    private func qualifierText() -> String {
        var parts: [String] = []
        if errorCount > 0 {
            parts.append("\(errorCount) error\(errorCount == 1 ? "" : "s")")
        }
        if warningCount > 0 {
            parts.append("\(warningCount) warning\(warningCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: ", ")
    }

    private func formatDiagnostic(_ d: Diagnostic) -> String {
        if let file = d.file {
            let leaf = (file as NSString).lastPathComponent
            switch (d.line, d.column) {
            case (.some(let l), .some(let c)):
                return "✗ \(leaf):\(l):\(c): \(d.message)"
            case (.some(let l), .none):
                return "✗ \(leaf):\(l): \(d.message)"
            default:
                return "✗ \(leaf): \(d.message)"
            }
        }
        return "✗ \(d.message)"
    }

    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 {
            return String(format: "%.2fs", seconds)
        }
        let intSec = Int(seconds.rounded())
        let h = intSec / 3600
        let m = (intSec % 3600) / 60
        let s = intSec % 60
        if h > 0 {
            return String(format: "%dh %02dm", h, m)
        }
        return String(format: "%dm %02ds", m, s)
    }

    // MARK: - Regex helpers (cached compiled instances)

    /// `path/to/File.swift:42:9: error: cannot find 'foo' in scope`
    /// `path/to/File.swift:42: warning: ...` (column optional)
    private static let fileDiagnosticRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: "^(.+?):(\\d+)(?::(\\d+))?: (warning|error): (.*)$")
    }()

    /// `ld: error: ...` / `clang: warning: ...` (single-token prefix)
    private static let toolDiagnosticRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: "^([A-Za-z][A-Za-z0-9_-]*): (warning|error): (.*)$")
    }()

    private func parseFileDiagnostic(_ line: String) -> Diagnostic? {
        let ns = line as NSString
        guard let m = Self.fileDiagnosticRegex.firstMatch(
            in: line, range: NSRange(location: 0, length: ns.length)
        ) else { return nil }
        let file = ns.substring(with: m.range(at: 1))
        // `note:` lines don't get here (regex matches only
        // warning|error), but xcodebuild does sometimes print lines
        // whose `file` segment is actually a tool token (e.g.
        // `error: foo`). Reject path-less captures so they fall
        // through to the tool-prefix branch.
        guard file.contains("/") || file.contains(".") else { return nil }
        let lineNum = Int(ns.substring(with: m.range(at: 2)))
        let colRange = m.range(at: 3)
        let col = colRange.location == NSNotFound ? nil : Int(ns.substring(with: colRange))
        let kindStr = ns.substring(with: m.range(at: 4))
        let msg = ns.substring(with: m.range(at: 5))
        return Diagnostic(
            kind: kindStr == "error" ? .error : .warning,
            file: file,
            line: lineNum,
            column: col,
            message: msg
        )
    }

    private func parseToolDiagnostic(_ line: String) -> Diagnostic? {
        let ns = line as NSString
        guard let m = Self.toolDiagnosticRegex.firstMatch(
            in: line, range: NSRange(location: 0, length: ns.length)
        ) else { return nil }
        let tool = ns.substring(with: m.range(at: 1))
        let kindStr = ns.substring(with: m.range(at: 2))
        let msg = ns.substring(with: m.range(at: 3))
        // Filter the ld dup-libs noise — it's emitted by default for
        // every build and skews the warning count.
        if tool == "ld", kindStr == "warning",
           msg.contains("ignoring duplicate libraries") {
            return nil
        }
        return Diagnostic(
            kind: kindStr == "error" ? .error : .warning,
            file: nil,
            line: nil,
            column: nil,
            message: "\(tool): \(msg)"
        )
    }
}
