import Foundation

/// Writer that turns a `BugReportService.collect()` payload into an
/// on-disk archive. Split from the collector so unit tests can verify
/// content without shelling out to `tar`.
public protocol BugReportArchiver: Sendable {
    /// Write `entries` to `outFileURL`. The archive format is an
    /// implementation detail of the conformer; the production
    /// `DiskTarGzArchiver` writes a gzip-compressed POSIX tar.
    func write(_ entries: [BugReportEntry], to outFileURL: URL) throws
}

/// Default archiver: stages the entries in a unique temp directory,
/// then shells out to `/usr/bin/tar` to produce a `.tgz`. We rely on
/// system `tar` rather than vendoring a pure-Swift archive lib because
/// AGENTS.md rule #4 caps us at two third-party deps and the user
/// already has tar.
public struct DiskTarGzArchiver: BugReportArchiver {
    public let runner: ProcessRunner
    /// Override only used in tests that want to redirect the staging
    /// dir somewhere predictable. Defaults to `FileManager.default
    /// .temporaryDirectory`.
    public let stagingRoot: URL

    public init(
        runner: ProcessRunner = DiskProcessRunner(),
        stagingRoot: URL = FileManager.default.temporaryDirectory
    ) {
        self.runner = runner
        self.stagingRoot = stagingRoot
    }

    public func write(_ entries: [BugReportEntry], to outFileURL: URL) throws {
        let fm = FileManager.default
        let staging = stagingRoot.appendingPathComponent(
            "vch-bug-report-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        for entry in entries {
            // `tar` doesn't tolerate path components with `..`; the
            // service only ever produces clean relative paths but
            // we guard defensively.
            guard !entry.path.contains("..") else {
                throw VibeChardError.externalCommandFailed(
                    cmd: "bug-report stage",
                    exitCode: -1,
                    stderr: "refusing entry with traversal: \(entry.path)"
                )
            }
            let dst = staging.appendingPathComponent(entry.path)
            try fm.createDirectory(
                at: dst.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try entry.data.write(to: dst, options: .atomic)
        }

        // Make sure the parent of `outFileURL` exists. `tar` would
        // otherwise emit a confusing "Cannot stat" error.
        try fm.createDirectory(
            at: outFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let result = try runner.run(
            "/usr/bin/tar",
            args: ["-czf", outFileURL.path, "-C", staging.path, "."],
            cwd: nil,
            env: nil
        )
        guard result.succeeded else {
            throw VibeChardError.externalCommandFailed(
                cmd: "tar -czf \(outFileURL.path)",
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
    }
}
