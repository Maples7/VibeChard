// vch-xcodebuild-shim
//
// Tiny standalone binary that VibeChard places (via symlink) at
// <worktree>/.vch/bin/{xcodebuild,xcrun,swift}. When something inside an
// isolated worktree invokes `xcodebuild`, the OS finds this shim first on
// $PATH; the shim then auto-injects per-task isolation flags and execs the
// real binary.
//
// M0 status (this commit): scaffolding only. The shim currently prints a
// diagnostic line and execs the real binary unchanged — enough for the M0
// "swift build -c release succeeds" gate. The real injection logic lands in
// M2 and is mirrored from the validated bash PoC at
// scripts/poc/m0_5-shim/shim/xcodebuild.

import Foundation

@main
struct ShimMain {
    static func main() {
        // The shim is invoked under the name of the tool it replaces (via the
        // symlink), so argv[0] tells us which tool to forward to.
        let args = CommandLine.arguments
        let invokedAs = (args.first as NSString?)?.lastPathComponent ?? "xcodebuild"
        let userArgs = Array(args.dropFirst())

        if ProcessInfo.processInfo.environment["VCH_SHIM_DEBUG"] != nil {
            FileHandle.standardError.write(Data(
                "vch-shim[\(invokedAs)]: scaffold (no injection yet); user-args=\(userArgs)\n"
                    .utf8
            ))
        }

        // Resolve the real binary via /usr/bin/xcrun -f <tool>. This bypasses
        // PATH and so cannot recurse into the shim itself.
        let realPath = resolveRealBinary(named: invokedAs)
        guard let realPath else {
            FileHandle.standardError.write(Data(
                "vch-shim: failed to resolve real \(invokedAs) via /usr/bin/xcrun -f\n".utf8
            ))
            exit(127)
        }

        // exec(2) — replace ourselves with the real binary.
        let argv = ([realPath] + userArgs).map { strdup($0) } + [nil]
        defer { for ptr in argv { if let p = ptr { free(p) } } }
        argv.withUnsafeBufferPointer { buf in
            _ = execv(realPath, buf.baseAddress!)
        }
        // execv only returns on failure.
        let err = String(cString: strerror(errno))
        FileHandle.standardError.write(Data(
            "vch-shim: execv(\(realPath)) failed: \(err)\n".utf8
        ))
        exit(127)
    }

    /// Ask `/usr/bin/xcrun -f <tool>` for the real absolute path. Returns nil
    /// if xcrun reports an error or if the resulting path looks like us
    /// (defensive guard against PATH-shadowing accidents).
    private static func resolveRealBinary(named tool: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["-f", tool]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Defensive: if xcrun somehow points back at us, bail.
        let selfPath = CommandLine.arguments.first ?? ""
        if trimmed == selfPath {
            return nil
        }
        return trimmed
    }
}
