import Foundation
import VibeChardCore
#if canImport(Darwin)
import Darwin
#endif

/// Shared launcher for any `ExecPlan`. Used by `vch exec` (M3) and
/// `vch build` / `vch test` (M4). Inherits stdio, ignores SIGINT
/// /SIGTERM in vch itself so Ctrl+C reaches the child only.
///
/// Returns the child's exit code (or 128+signal if it died from a
/// signal). Also returns the wall-clock duration so callers like M4
/// can persist `lastBuild` / `lastTest` records.
enum PlanLauncher {

    struct RunResult {
        let exitCode: Int32
        let durationSeconds: Double
    }

    static func run(_ plan: ExecPlan) throws -> RunResult {
        // Launch via `/usr/bin/env` so PATH lookup honors `plan.env`
        // (e.g. the prepended `<wt>/.vch/bin/` that holds shim symlinks
        // in M3). For M4 the argv starts with a plain `xcodebuild`
        // resolved against the parent process PATH — env handles both.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = plan.argv
        proc.currentDirectoryURL = URL(fileURLWithPath: plan.cwd)
        proc.environment = plan.env
        // Inherit stdin/stdout/stderr from vch — `Process` does this
        // when we leave the *Pipe* properties untouched.

        // Suppress vch's own SIGINT/SIGTERM handling so Ctrl+C goes to
        // the child only.
        let prevInt  = signal(SIGINT,  SIG_IGN)
        let prevTerm = signal(SIGTERM, SIG_IGN)
        defer {
            signal(SIGINT,  prevInt)
            signal(SIGTERM, prevTerm)
        }

        let started = Date()
        do {
            try proc.run()
        } catch {
            throw VibeChardError.externalCommandFailed(
                cmd: plan.argv.joined(separator: " "),
                exitCode: 127,
                stderr: "failed to launch: \(error.localizedDescription)"
            )
        }
        proc.waitUntilExit()
        let duration = Date().timeIntervalSince(started)

        let code: Int32
        switch proc.terminationReason {
        case .exit:           code = proc.terminationStatus
        case .uncaughtSignal: code = 128 + proc.terminationStatus
        @unknown default:     code = proc.terminationStatus
        }
        return RunResult(exitCode: code, durationSeconds: duration)
    }
}
