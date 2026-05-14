import Foundation

/// Locate the installed Agent runbook relative to the running `vch` binary.
///
/// Probes `<realpath(executablePath)>/../../share/doc/vch/agent-runbook.md`
/// — the standard Homebrew doc convention (`<prefix>/share/doc/<formula>/`).
/// Returns `nil` when the file is absent or when `executablePath` has no
/// directory component (bare name like `"vch"`).
public enum RunbookLocator {

    public static let fileName = "agent-runbook.md"

    /// Returns the absolute path to the installed runbook, or `nil` if the
    /// file is not readable at the expected Homebrew doc location.
    ///
    /// - Parameters:
    ///   - executablePath: Path to the running `vch` binary. Pass
    ///     `CommandLine.arguments.first ?? ""` from the CLI entry-point.
    ///   - fs: Filesystem abstraction (real disk by default; inject an
    ///     `InMemoryFileSystem` in tests).
    public static func installedPath(
        executablePath: String,
        fs: FileSystem = DiskFileSystem()
    ) -> String? {
        let trimmed = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains("/") else { return nil }

        let resolved = resolve(trimmed)
        // Walk up two levels: bin/ → <prefix>
        let binDir = (resolved as NSString).deletingLastPathComponent
        let prefix = (binDir as NSString).deletingLastPathComponent
        let candidate = ((prefix as NSString)
            .appendingPathComponent("share/doc/vch") as NSString)
            .appendingPathComponent(fileName)

        guard fs.fileExists(at: candidate) else { return nil }
        return candidate
    }

    private static func resolve(_ path: String) -> String {
        guard let cstr = realpath(path, nil) else { return path }
        defer { free(cstr) }
        return String(cString: cstr)
    }
}
