import Foundation
import VibeChardCore
#if canImport(Darwin)
import Darwin
#endif

/// Shared launcher for any `ExecPlan`.
///
/// Two modes:
///
/// * `run(_:)`  — fork+wait via `Process()`. Used by `vch build` and
///   `vch test` because they need the wall-clock duration to persist
///   `lastBuild` / `lastTest` records into `state.json`. Suitable for
///   non-interactive children that don't need the controlling tty.
///
/// * `runReplacing(_:)` — `execve`-replace the vch process. Used by
///   `vch exec` (and its `vch <name>` sugar form). The child becomes
///   the SAME process — same pid, same pgrp, same controlling tty —
///   so an interactive shell can drive the terminal normally and a
///   real ^C reaches it without the SIG_IGN inheritance trap that
///   `Process()` falls into.
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

    /// Tee variant used by `vch test` (#9). Pipes the child's stdout
    /// and stderr through vch:
    ///
    /// 1. **Tee**: every byte is appended to `logURL` so users can
    ///    always reach the full firehose later via `vch logs <name>
    ///    --test`. The file is truncated at the start of each run.
    /// 2. **Parse**: every complete line is forwarded to `onLine` so
    ///    the caller can run a `TestOutputSummarizer` over the stream.
    /// 3. **Mirror** (optional): when `mirror` is true the bytes are
    ///    also written through to vch's own stdout/stderr — this is
    ///    what `--verbose` opts into. When `mirror` is false the
    ///    child's output is silent at the terminal until the caller
    ///    prints a summary at the end.
    ///
    /// Unlike `run(_:)` we cannot inherit the child's tty, but
    /// xcodebuild test output is purely line-oriented, so users don't
    /// notice the difference.
    static func runTee(
        _ plan: ExecPlan,
        logURL: URL,
        mirror: Bool,
        onLine: @escaping (String) -> Void
    ) throws -> RunResult {
        // Make sure the parent dir exists.
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Truncate-and-create.
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let logFH = try? FileHandle(forWritingTo: logURL) else {
            throw VibeChardError.externalCommandFailed(
                cmd: plan.argv.joined(separator: " "),
                exitCode: 127,
                stderr: "could not open \(logURL.path) for writing"
            )
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = plan.argv
        proc.currentDirectoryURL = URL(fileURLWithPath: plan.cwd)
        proc.environment = plan.env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError  = errPipe

        // Line accumulator. We append all bytes from both streams into
        // one buffer, since the parser doesn't care which stream a
        // line came from. NSLock guards against the (theoretical)
        // case where stdout and stderr drain on different threads.
        let lock = NSLock()
        var buffer = Data()
        let drainOneStream: (FileHandle, FileHandle?) -> Void = { fh, mirrorFH in
            while true {
                let chunk = fh.availableData
                if chunk.isEmpty { return }
                // Persist to log + optionally mirror, both unconditional.
                try? logFH.write(contentsOf: chunk)
                if let mirrorFH {
                    try? mirrorFH.write(contentsOf: chunk)
                }
                lock.lock()
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[..<nl]
                    let line = String(decoding: lineData, as: UTF8.self)
                    buffer.removeSubrange(...nl)
                    lock.unlock()
                    onLine(line)
                    lock.lock()
                }
                lock.unlock()
            }
        }

        // Suppress vch's own SIGINT/SIGTERM so Ctrl+C reaches the child.
        let prevInt  = signal(SIGINT,  SIG_IGN)
        let prevTerm = signal(SIGTERM, SIG_IGN)
        defer {
            signal(SIGINT,  prevInt)
            signal(SIGTERM, prevTerm)
            try? logFH.close()
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

        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        group.enter()
        queue.async {
            defer { group.leave() }
            drainOneStream(outPipe.fileHandleForReading, mirror ? FileHandle.standardOutput : nil)
        }
        group.enter()
        queue.async {
            defer { group.leave() }
            drainOneStream(errPipe.fileHandleForReading, mirror ? FileHandle.standardError : nil)
        }

        proc.waitUntilExit()
        group.wait()

        // Flush any trailing bytes that didn't end with a newline.
        lock.lock()
        if !buffer.isEmpty {
            let line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll()
            lock.unlock()
            onLine(line)
        } else {
            lock.unlock()
        }

        let duration = Date().timeIntervalSince(started)
        let code: Int32
        switch proc.terminationReason {
        case .exit:           code = proc.terminationStatus
        case .uncaughtSignal: code = 128 + proc.terminationStatus
        @unknown default:     code = proc.terminationStatus
        }
        return RunResult(exitCode: code, durationSeconds: duration)
    }

    /// `execve`-replace the vch process with the plan's argv.
    ///
    /// Why not `Process()` + `waitUntilExit()`?
    ///
    /// 1. `Process()` does not transfer the controlling terminal to
    ///    the child. An interactive shell launched that way never
    ///    becomes the foreground process group, so it can't draw a
    ///    prompt or read user input — looks like "vch hung".
    /// 2. To keep ^C from killing vch itself, the `run(_:)` path
    ///    sets `SIGINT` / `SIGTERM` to `SIG_IGN` before spawning.
    ///    POSIX preserves `SIG_IGN` across `exec`, so an interactive
    ///    child shell would inherit a permanently-ignored ^C.
    ///
    /// Replacing via `execve` sidesteps both: the child IS vch (same
    /// pid, same pgrp, same controlling tty), with default signal
    /// dispositions because we never touch them on this path.
    ///
    /// Spawned through `/usr/bin/env` so the prepended `<wt>/.vch/bin`
    /// in `plan.env["PATH"]` is honored when resolving the actual
    /// command — same convention as `run(_:)`.
    static func runReplacing(_ plan: ExecPlan) -> Never {
        // execve doesn't accept a working directory, so chdir first.
        if chdir(plan.cwd) != 0 {
            let err = String(cString: strerror(errno))
            FileHandle.standardError.write(
                Data("vch: chdir(\(plan.cwd)): \(err)\n".utf8)
            )
            exit(127)
        }

        let exe = "/usr/bin/env"
        let argvStrs = [exe] + plan.argv
        var cArgv: [UnsafeMutablePointer<CChar>?] = argvStrs.map { strdup($0) }
        cArgv.append(nil)

        // Sort env pairs for deterministic ordering (mostly cosmetic;
        // helps when debugging a misbehaving child via `truss`/`dtruss`).
        let envPairs = plan.env.map { "\($0.key)=\($0.value)" }.sorted()
        var cEnv: [UnsafeMutablePointer<CChar>?] = envPairs.map { strdup($0) }
        cEnv.append(nil)

        _ = execve(exe, cArgv, cEnv)

        // execve only returns on failure — if we got here, exec didn't.
        let err = String(cString: strerror(errno))
        FileHandle.standardError.write(
            Data("vch: execve(\(exe)): \(err)\n".utf8)
        )
        exit(127)
    }
}
