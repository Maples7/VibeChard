// vch-xcodebuild-shim
//
// Tiny standalone binary that VibeChard places (via symlink) at
// <worktree>/.vch/bin/{xcodebuild,xcrun,swift}. When something inside an
// isolated worktree invokes `xcodebuild`, the OS finds this shim first on
// $PATH; the shim then auto-injects per-task isolation flags and execs
// the real binary.
//
// Hard rules (AGENTS.md #6):
//   • No third-party imports. Foundation only.
//   • Cold start matters — every xcodebuild call inside an vch worktree
//     forks this binary. Keep the work minimal.
//
// All decision logic lives in `Injection.swift` as pure functions; this
// file is the thin OS-facing wrapper.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

@main
struct ShimMain {

    static func main() {
        let argv0 = CommandLine.arguments.first ?? "xcodebuild"
        let userArgs = Array(CommandLine.arguments.dropFirst())
        let tool = InvokedTool.from(argv0: argv0)
        let env = ProcessInfo.processInfo.environment

        let plan = ShimPlanner.plan(invokedAs: tool, userArgs: userArgs, env: env)

        guard let realPath = resolveRealBinary(for: tool, argv0: argv0) else {
            stderr("vch-shim: failed to resolve real \(tool.rawValue)")
            exit(127)
        }

        if env[ShimEnv.debug] != nil {
            stderr(ShimPlanner.debugLine(invokedAs: tool, real: realPath, plan: plan, userArgs: userArgs))
        }

        // Remove vch-owned stale result bundles before xcodebuild
        // starts. xcodebuild refuses to overwrite an existing
        // -resultBundlePath; `vch exec ... xcodebuild test ...`
        // goes through this shim, so the shim must mirror the
        // `vch test` prepare step for the path it injected itself.
        for path in plan.pathsToRemoveBeforeExec where !path.isEmpty {
            if FileManager.default.fileExists(atPath: path) {
                do {
                    try FileManager.default.removeItem(atPath: path)
                } catch {
                    stderr("vch-shim: failed to remove stale result bundle at \(path): \(error.localizedDescription)")
                    exit(1)
                }
            }
        }

        // Create the directories we promised xcodebuild would find.
        for dir in plan.directoriesToEnsure where !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        let argv = ShimPlanner.argv(forReal: realPath, plan: plan, userArgs: userArgs)

        // Mark the chain so a re-entrant invocation under the same shim
        // doesn't double-inject. We mutate our own env, then execv
        // inherits it.
        setenv(ShimEnv.alreadyInjected, "1", 1)

        execvOrFail(realPath, argv: argv)
    }

    /// Resolve the real binary the shim should hand off to.
    ///
    /// • Honors `VCH_SHIM_REAL_<TOOL>` if set (diagnostic/test escape).
    /// • For `xcrun`: `/usr/bin/xcrun` is stable on every macOS we ship for.
    /// • For `xcodebuild` and `swift`: `/usr/bin/xcrun -f <tool>` is the
    ///   canonical resolver (bypasses PATH so we don't recurse).
    private static func resolveRealBinary(for tool: InvokedTool, argv0: String) -> String? {
        if let override = ProcessInfo.processInfo.environment[ShimEnv.realOverrideKey(for: tool)],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return override
        }
        switch tool {
        case .xcrun:
            return "/usr/bin/xcrun"
        case .xcodebuild, .swift:
            return resolveViaXcrun(toolName: tool.rawValue, argv0: argv0)
        }
    }

    private static func resolveViaXcrun(toolName: String, argv0: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["-f", toolName]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Defensive: refuse to exec ourselves if PATH was somehow set up
        // to make xcrun resolve back to our shim.
        let argv0Resolved = (argv0 as NSString).standardizingPath
        if (trimmed as NSString).standardizingPath == argv0Resolved {
            return nil
        }
        return trimmed
    }

    private static func execvOrFail(_ path: String, argv: [String]) -> Never {
        // Build the C-string argv array, terminated by NULL.
        let cStrings: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer {
            for ptr in cStrings { if let p = ptr { free(p) } }
        }
        cStrings.withUnsafeBufferPointer { buf in
            _ = execv(path, buf.baseAddress!)
        }
        // execv only returns on failure.
        let err = String(cString: strerror(errno))
        stderr("vch-shim: execv(\(path)) failed: \(err)")
        exit(127)
    }

    private static func stderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
