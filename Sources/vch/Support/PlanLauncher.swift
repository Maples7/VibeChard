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
        let idleTimeout: IdleTimeout?
    }

    struct IdleTimeout {
        let pid: Int32
        let idleSeconds: Double
        let elapsedSeconds: Double
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
        let restoreSignalForwarding = installChildSignalForwarding(to: proc)
        defer { restoreSignalForwarding() }

        proc.waitUntilExit()
        let duration = Date().timeIntervalSince(started)

        let code: Int32
        switch proc.terminationReason {
        case .exit:           code = proc.terminationStatus
        case .uncaughtSignal: code = 128 + proc.terminationStatus
        @unknown default:     code = proc.terminationStatus
        }
        return RunResult(exitCode: code, durationSeconds: duration, idleTimeout: nil)
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
        idleTimeout: TimeInterval? = nil,
        shouldEnforceIdleTimeout: @escaping () -> Bool = { true },
        heartbeatInterval: TimeInterval? = nil,
        onHeartbeat: ((_ elapsedSeconds: TimeInterval, _ secondsSinceLastOutput: TimeInterval) -> Void)? = nil,
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
        let activityLock = NSLock()
        var buffer = Data()
        var lastActivityAt = Date()
        func markActivity() {
            activityLock.lock()
            lastActivityAt = Date()
            activityLock.unlock()
        }
        func secondsSinceLastActivity() -> Double {
            activityLock.lock()
            let idle = Date().timeIntervalSince(lastActivityAt)
            activityLock.unlock()
            return idle
        }
        let drainOneStream: (FileHandle, FileHandle?) -> Void = { fh, mirrorFH in
            while true {
                let chunk = fh.availableData
                if chunk.isEmpty { return }
                markActivity()
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

        defer { try? logFH.close() }

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
        let restoreSignalForwarding = installChildSignalForwarding(to: proc)
        defer { restoreSignalForwarding() }

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

        var idleTimeoutResult: IdleTimeout?
        let idleLimit = idleTimeout ?? 0
        let wantsIdleWatchdog = idleLimit > 0
        // Heartbeat is purely a progress signal, so it's pointless when
        // the caller already mirrors the firehose (`--verbose`).
        let heartbeatEvery = mirror ? 0 : (heartbeatInterval ?? 0)
        let wantsHeartbeat = heartbeatEvery > 0 && onHeartbeat != nil
        if wantsIdleWatchdog || wantsHeartbeat {
            // A lightweight polling loop keeps this path independent of
            // RunLoop state while the pipe-drain workers own stream reads.
            // Poll fast enough to honor the tighter of the two cadences.
            var cadences: [Double] = []
            if wantsIdleWatchdog { cadences.append(idleLimit) }
            if wantsHeartbeat { cadences.append(heartbeatEvery) }
            let checkInterval = min(max((cadences.min() ?? 1.0) / 10, 0.05), 1.0)
            var nextHeartbeatAt = started.addingTimeInterval(heartbeatEvery)
            while proc.isRunning {
                let now = Date()
                // Emit a heartbeat on its own cadence, regardless of
                // whether the child is currently producing output — that
                // silence is exactly what makes a long run look hung.
                if wantsHeartbeat, now >= nextHeartbeatAt {
                    onHeartbeat?(now.timeIntervalSince(started), secondsSinceLastActivity())
                    nextHeartbeatAt = now.addingTimeInterval(heartbeatEvery)
                }
                // The caller decides when an idle period is meaningful;
                // for `vch test`, this stays false until test execution starts.
                if wantsIdleWatchdog, shouldEnforceIdleTimeout() {
                    let idleSeconds = secondsSinceLastActivity()
                    if idleSeconds >= idleLimit {
                        idleTimeoutResult = IdleTimeout(
                            pid: proc.processIdentifier,
                            idleSeconds: idleSeconds,
                            elapsedSeconds: Date().timeIntervalSince(started)
                        )
                        proc.terminate()
                        if !waitForExit(proc, timeout: 2.0) {
#if canImport(Darwin)
                            _ = Darwin.kill(proc.processIdentifier, SIGKILL)
#endif
                        }
                        break
                    }
                }
                Thread.sleep(forTimeInterval: checkInterval)
            }
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
        if idleTimeoutResult != nil {
            code = 124
        } else {
            switch proc.terminationReason {
            case .exit:           code = proc.terminationStatus
            case .uncaughtSignal: code = 128 + proc.terminationStatus
            @unknown default:     code = proc.terminationStatus
            }
        }
        return RunResult(exitCode: code, durationSeconds: duration, idleTimeout: idleTimeoutResult)
    }

    private static func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !process.isRunning
    }

#if canImport(Darwin)
    /// Forward hangups/interrupts/termination received by the wrapper to the
    /// already-running child. Install this only after `Process.run()`:
    /// ignored signal dispositions are inherited across exec, and a
    /// child `xcodebuild` that ignores SIGTERM is exactly the orphaned
    /// process failure mode this launcher must avoid.
    private static func installChildSignalForwarding(to process: Process) -> () -> Void {
        let previousHup = signal(SIGHUP, SIG_IGN)
        let previousInt = signal(SIGINT, SIG_IGN)
        let previousTerm = signal(SIGTERM, SIG_IGN)
        let queue = DispatchQueue(label: "dev.vibechard.planlauncher.signals")

        let hupSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: queue)
        hupSource.setEventHandler {
            forward(SIGHUP, to: process)
        }
        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
        intSource.setEventHandler {
            forward(SIGINT, to: process)
        }
        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        termSource.setEventHandler {
            forward(SIGTERM, to: process)
        }
        hupSource.resume()
        intSource.resume()
        termSource.resume()

        return {
            hupSource.cancel()
            intSource.cancel()
            termSource.cancel()
            signal(SIGHUP, previousHup)
            signal(SIGINT, previousInt)
            signal(SIGTERM, previousTerm)
        }
    }

    private static func forward(_ signalNumber: Int32, to process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        _ = Darwin.kill(pid, signalNumber)
    }
#else
    private static func installChildSignalForwarding(to process: Process) -> () -> Void {
        {}
    }
#endif

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
