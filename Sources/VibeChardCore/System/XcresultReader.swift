import Foundation

/// Reads an `.xcresult` bundle via `xcrun xcresulttool` and returns
/// the parsed `XcresultSummary`. Abstracted as a protocol so the CLI
/// path can stay testable without mocking the whole `xcresulttool`
/// surface (#45).
public protocol XcresultReader: Sendable {
    /// Run `xcrun xcresulttool get test-results summary --path
    /// <bundle>` and return the raw JSON `Data`. Throws when the
    /// bundle is missing or `xcresulttool` exits non-zero.
    func readSummaryJSON(bundlePath: String) throws -> Data
}

public extension XcresultReader {
    /// Convenience: read + decode the summary in one call.
    func summary(at bundlePath: String) throws -> XcresultSummary {
        let data = try readSummaryJSON(bundlePath: bundlePath)
        return try XcresultSummary.parse(data)
    }
}

/// Production implementation backed by `/usr/bin/xcrun xcresulttool`.
public struct DiskXcresultReader: XcresultReader {
    public let runner: ProcessRunner
    public let xcrunPath: String

    public init(
        runner: ProcessRunner = DiskProcessRunner(),
        xcrunPath: String = "/usr/bin/xcrun"
    ) {
        self.runner = runner
        self.xcrunPath = xcrunPath
    }

    public func readSummaryJSON(bundlePath: String) throws -> Data {
        let result = try runner.run(
            xcrunPath,
            args: [
                "xcresulttool", "get", "test-results", "summary",
                "--path", bundlePath,
                "--compact",
            ]
        )
        guard result.succeeded else {
            throw VibeChardError.externalCommandFailed(
                cmd: "xcrun xcresulttool get test-results summary --path \(bundlePath)",
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
        return Data(result.stdout.utf8)
    }
}
