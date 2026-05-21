import Foundation
import Darwin

public enum TestSessionProcessKind: String, Codable, Equatable, Sendable {
    case vchTest = "vch-test"
    case xcodebuild
    case xctestHost = "xctest-host"
}

public struct ProcessListEntry: Equatable, Sendable {
    public let pid: Int32
    public let command: String

    public init(pid: Int32, command: String) {
        self.pid = pid
        self.command = command
    }
}

public struct TestSessionProcess: Equatable, Sendable {
    public let pid: Int32
    public let kind: TestSessionProcessKind
    public let command: String

    public init(pid: Int32, kind: TestSessionProcessKind, command: String) {
        self.pid = pid
        self.kind = kind
        self.command = command
    }
}

public struct TestSessionProcessQuery: Equatable, Sendable {
    public let taskName: String
    public let worktreePath: String
    public let derivedDataPath: String
    public let resultBundlePath: String
    public let scheme: String?
    public let simulatorUDIDs: [String]

    public init(
        taskName: String,
        worktreePath: String,
        derivedDataPath: String,
        resultBundlePath: String,
        scheme: String?,
        simulatorUDIDs: [String] = []
    ) {
        self.taskName = taskName
        self.worktreePath = worktreePath
        self.derivedDataPath = derivedDataPath
        self.resultBundlePath = resultBundlePath
        self.scheme = scheme
        self.simulatorUDIDs = simulatorUDIDs
    }
}

public protocol TestSessionProcessScanner: Sendable {
    func findProcesses(for query: TestSessionProcessQuery) throws -> [TestSessionProcess]
}

public protocol ProcessTerminator: Sendable {
    func terminate(pid: Int32) throws
}

public enum ProcessListParser {
    /// Parse `ps -axo pid=,command=` output. The command column may
    /// contain arbitrary spaces, so only the first whitespace-delimited
    /// field is treated as the PID.
    public static func parse(psOutput: String) -> [ProcessListEntry] {
        psOutput.split(separator: "\n", omittingEmptySubsequences: true).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let separator = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                return nil
            }
            let pidText = line[..<separator]
            guard let pid = Int32(pidText) else { return nil }
            let command = line[separator...].trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { return nil }
            return ProcessListEntry(pid: pid, command: command)
        }
    }
}

public enum TestSessionProcessDetector {
    public static func detect(
        entries: [ProcessListEntry],
        taskName: String,
        worktreePath: String,
        derivedDataPath: String,
        resultBundlePath: String,
        scheme: String?,
        simulatorUDIDs: [String] = [],
        selfPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> [TestSessionProcess] {
        var directMatches: [TestSessionProcess] = []
        var hostCandidates: [TestSessionProcess] = []

        for entry in entries {
            guard entry.pid != selfPID else { continue }
            let command = entry.command
            if isVchTestCommand(command, taskName: taskName) {
                directMatches.append(TestSessionProcess(pid: entry.pid, kind: .vchTest, command: command))
                continue
            }
            if isXcodebuildTestCommand(
                command,
                worktreePath: worktreePath,
                derivedDataPath: derivedDataPath,
                resultBundlePath: resultBundlePath
            ) {
                directMatches.append(TestSessionProcess(pid: entry.pid, kind: .xcodebuild, command: command))
                continue
            }
            if isXCTestDevicesHostCommand(
                command,
                scheme: scheme,
                simulatorUDIDs: simulatorUDIDs
            ) {
                hostCandidates.append(TestSessionProcess(pid: entry.pid, kind: .xctestHost, command: command))
            }
        }

        // XCTestDevices hosts are only safe to report when the same
        // scan also found a task-scoped vch/xcodebuild test process;
        // otherwise an unrelated XCTestDevices run for the same app
        // could block or be killed by this task's clean command.
        return directMatches.isEmpty ? [] : directMatches + hostCandidates
    }

    private static func isVchTestCommand(_ command: String, taskName: String) -> Bool {
        guard command.contains("vch") else { return false }
        return command.contains(" test \(taskName)")
    }

    private static func isXcodebuildTestCommand(
        _ command: String,
        worktreePath: String,
        derivedDataPath: String,
        resultBundlePath: String
    ) -> Bool {
        guard command.contains("xcodebuild") else { return false }
        guard command.contains(" test") || command.hasSuffix("test") else { return false }
        let needles = [worktreePath, derivedDataPath, resultBundlePath]
            .filter { !$0.isEmpty }
        return needles.contains { command.contains($0) }
    }

    private static func isXCTestDevicesHostCommand(
        _ command: String,
        scheme: String?,
        simulatorUDIDs: [String]
    ) -> Bool {
        guard command.contains("/Library/Developer/XCTestDevices/") else { return false }
        guard command.contains(".app/") else { return false }
        guard let scheme, !scheme.isEmpty else { return false }
        guard simulatorUDIDs.contains(where: { udid in
            command.contains("/Library/Developer/XCTestDevices/\(udid)/")
        }) else { return false }
        return command.contains("/\(scheme).app/")
            || command.hasSuffix("/\(scheme)")
            || command.contains("/\(scheme) ")
    }
}

public struct DiskTestSessionProcessScanner: TestSessionProcessScanner {
    public let runner: ProcessRunner
    public let psPath: String

    public init(
        runner: ProcessRunner = DiskProcessRunner(),
        psPath: String = "/bin/ps"
    ) {
        self.runner = runner
        self.psPath = psPath
    }

    public func findProcesses(for query: TestSessionProcessQuery) throws -> [TestSessionProcess] {
        let result = try runner.run(
            psPath,
            args: ["-axo", "pid=,command="],
            cwd: nil,
            env: nil
        )
        let entries = ProcessListParser.parse(psOutput: result.stdout)
        return TestSessionProcessDetector.detect(
            entries: entries,
            taskName: query.taskName,
            worktreePath: query.worktreePath,
            derivedDataPath: query.derivedDataPath,
            resultBundlePath: query.resultBundlePath,
            scheme: query.scheme,
            simulatorUDIDs: query.simulatorUDIDs
        )
    }
}

public struct DiskProcessTerminator: ProcessTerminator {
    public init() {}

    public func terminate(pid: Int32) throws {
        if Darwin.kill(pid, SIGTERM) != 0 {
            let savedErrno = errno
            throw VibeChardError.externalCommandFailed(
                cmd: "kill -TERM \(pid)",
                exitCode: Int32(savedErrno),
                stderr: String(cString: strerror(savedErrno))
            )
        }
    }
}