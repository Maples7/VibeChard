import Foundation

/// Result of running an external command.
public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { exitCode == 0 }
    public var stdoutTrimmed: String {
        stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Abstracted shell-out so unit tests can replace it with a fake.
public protocol ProcessRunner: Sendable {
    /// Run `executable` with `args` and `cwd`. Captures stdout and stderr
    /// fully; suitable for short-lived commands like git/xcrun. Long-lived
    /// processes (Q6 `vch exec`) use a different path.
    func run(
        _ executable: String,
        args: [String],
        cwd: String?,
        env: [String: String]?
    ) throws -> ProcessResult
}

public extension ProcessRunner {
    func run(_ executable: String, args: [String]) throws -> ProcessResult {
        try run(executable, args: args, cwd: nil, env: nil)
    }
    func run(_ executable: String, args: [String], cwd: String) throws -> ProcessResult {
        try run(executable, args: args, cwd: cwd, env: nil)
    }
}

/// Production implementation backed by `Foundation.Process`.
public struct DiskProcessRunner: ProcessRunner {
    public init() {}

    public func run(
        _ executable: String,
        args: [String],
        cwd: String?,
        env: [String: String]?
    ) throws -> ProcessResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        if let cwd, !cwd.isEmpty {
            // Defensive: NSTask.setCurrentDirectoryURL crashes hard if the
            // path is empty or already deleted. Surface a clean error.
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
                throw VibeChardError.externalCommandFailed(
                    cmd: ([executable] + args).joined(separator: " "),
                    exitCode: -1,
                    stderr: "working directory does not exist: \(cwd) (your shell may be cd'd into a removed worktree)"
                )
            }
            proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        if let env {
            proc.environment = env
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            throw VibeChardError.externalCommandFailed(
                cmd: ([executable] + args).joined(separator: " "),
                exitCode: -1,
                stderr: "failed to spawn: \(error)"
            )
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        return ProcessResult(
            exitCode: proc.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
