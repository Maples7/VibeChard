import Foundation

/// Resolves the active Xcode toolchain root, used to populate
/// `DEVELOPER_DIR` in child environments.
///
/// Background (#31): on hosts with multiple Xcodes installed, a
/// hand-typed `xcrun` / `xcodebuild` inside a `vch <name>` sugar shell
/// can pick the wrong toolchain when the parent shell never exported
/// `DEVELOPER_DIR`. We close that practical gap by injecting whatever
/// `xcode-select -p` reports into the child env, but only when the
/// caller hasn't already set it (user/CI override always wins).
public protocol DeveloperDirResolver: Sendable {
    /// Returns the toolchain root, or `nil` if it can't be determined
    /// (no Xcode installed, command-line tools only, etc.). Callers
    /// must treat `nil` as "leave `DEVELOPER_DIR` alone" — never as
    /// an error condition.
    func resolve() -> String?
}

/// Production resolver. Shells out to `/usr/bin/xcode-select -p` and
/// caches the answer for the lifetime of the process: we expect
/// xcode-select state to be stable across a single `vch` invocation.
public final class XcodeSelectDeveloperDirResolver: DeveloperDirResolver, @unchecked Sendable {
    private let runner: ProcessRunner
    private let lock = NSLock()
    private var cached: String??

    public init(runner: ProcessRunner = DiskProcessRunner()) {
        self.runner = runner
    }

    public func resolve() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let resolved = computeOnce()
        cached = .some(resolved)
        return resolved
    }

    private func computeOnce() -> String? {
        // `/usr/bin/xcode-select` is part of the macOS base install;
        // it's safe to assume the absolute path.
        guard let result = try? runner.run(
            "/usr/bin/xcode-select",
            args: ["-p"],
            cwd: nil,
            env: nil
        ), result.succeeded else {
            return nil
        }
        let trimmed = result.stdoutTrimmed
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Helper used by both `BuildService` and `ExecService` to apply the
/// "inject only when caller didn't set it" policy in one place.
enum DeveloperDirInjection {
    static func apply(
        to env: inout [String: String],
        resolver: DeveloperDirResolver?
    ) {
        guard env["DEVELOPER_DIR"] == nil,
              let dir = resolver?.resolve(),
              !dir.isEmpty else {
            return
        }
        env["DEVELOPER_DIR"] = dir
    }
}
