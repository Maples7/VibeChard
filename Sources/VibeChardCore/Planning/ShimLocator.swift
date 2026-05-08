import Foundation

/// Locate the `vch-xcodebuild-shim` binary that should be symlinked
/// into a worktree's `.vch/bin/`. The lookup order is:
///
///   1. `$VCH_SHIM_PATH` (test/diagnostic escape hatch)
///   2. sibling of the running `vch` binary
///      (covers `swift build` dev layout)
///   3. `<bin-parent>/libexec/vch-xcodebuild-shim`
///      (covers Homebrew layout from Q10)
///
/// All paths are resolved with `realpath(3)` so symlinked installs
/// (the brew cellar pattern) work transparently.
public enum ShimLocator {

    public static let binaryName = "vch-xcodebuild-shim"

    public static func locate(
        vchExecutablePath: String,
        env: [String: String],
        fs: FileSystem = DiskFileSystem()
    ) -> String? {
        if let override = env["VCH_SHIM_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty,
           fs.fileExists(at: override) {
            return resolve(override)
        }

        let resolvedVch = resolve(vchExecutablePath)
        let parent = (resolvedVch as NSString).deletingLastPathComponent

        let sibling = (parent as NSString).appendingPathComponent(binaryName)
        if fs.fileExists(at: sibling) {
            return sibling
        }

        // Brew layout: <prefix>/bin/vch + <prefix>/libexec/<binary>.
        let libexec = ((parent as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("libexec")
        let inLibexec = (libexec as NSString).appendingPathComponent(binaryName)
        if fs.fileExists(at: inLibexec) {
            return inLibexec
        }

        return nil
    }

    /// Public so callers (M3 ExecCommand) can pre-resolve the running
    /// `vch`'s own path before handing it off.
    public static func currentExecutablePath() -> String {
        // `Bundle.main.executablePath` is the canonical macOS API; it
        // wraps `_NSGetExecutablePath` and follows symlinks.
        if let p = Bundle.main.executablePath {
            return p
        }
        return CommandLine.arguments.first ?? "vch"
    }

    private static func resolve(_ path: String) -> String {
        // `realpath(3)` returns nil if any path component is missing.
        // Fall back to the input so the caller can still surface a
        // useful error.
        guard let cstr = realpath(path, nil) else { return path }
        defer { free(cstr) }
        return String(cString: cstr)
    }
}
