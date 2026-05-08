import XCTest
@testable import VibeChardCore

/// Real-disk tests for `DiskProcessRunner`. The defensive behaviour we
/// pin here is rare to hit in normal flows but very real: shells often
/// stay `cd`'d inside a removed worktree (you `vch rm foo` from inside
/// `agent-foo/Demo`), and the next `vch <anything>` will then try to
/// run with a dangling `cwd`. Without this guard, `Foundation.Process`
/// crashes hard inside `setCurrentDirectoryURL` rather than throwing a
/// readable error.
final class DiskProcessRunnerTests: XCTestCase {

    func testRunThrowsWhenCwdDirectoryDoesNotExist() {
        let runner = DiskProcessRunner()
        let bogus = NSTemporaryDirectory()
            + "vch-proc-test-no-such-dir-\(UUID().uuidString)"
        // Sanity: we did not accidentally create it.
        XCTAssertFalse(FileManager.default.fileExists(atPath: bogus))

        XCTAssertThrowsError(
            try runner.run("/bin/echo", args: ["hi"], cwd: bogus, env: nil)
        ) { err in
            guard case let VibeChardError.externalCommandFailed(cmd, exitCode, stderr) = err else {
                return XCTFail("expected externalCommandFailed, got \(err)")
            }
            XCTAssertEqual(exitCode, -1,
                           "synthetic exit code so wrappers don't confuse this with a real signal")
            XCTAssertTrue(
                stderr.contains("working directory does not exist"),
                "stderr should explain what happened; got: \(stderr)"
            )
            XCTAssertTrue(
                stderr.contains(bogus),
                "stderr should name the offending path so the user can `cd` away; got: \(stderr)"
            )
            XCTAssertTrue(cmd.contains("/bin/echo"),
                          "cmd should embed the executable name; got: \(cmd)")
        }
    }

    func testRunThrowsWhenCwdIsRegularFileInsteadOfDirectory() throws {
        // A pre-existing regular file at the cwd path is just as
        // crash-y for `setCurrentDirectoryURL` as a missing one.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vch-proc-test-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let regularFile = "\(tmp)/not-a-dir"
        XCTAssertTrue(FileManager.default.createFile(atPath: regularFile, contents: Data("x".utf8)))

        let runner = DiskProcessRunner()
        XCTAssertThrowsError(
            try runner.run("/bin/echo", args: ["hi"], cwd: regularFile, env: nil)
        ) { err in
            guard case let VibeChardError.externalCommandFailed(_, exitCode, stderr) = err else {
                return XCTFail("expected externalCommandFailed, got \(err)")
            }
            XCTAssertEqual(exitCode, -1)
            XCTAssertTrue(stderr.contains("working directory does not exist"))
        }
    }

    func testRunSucceedsWithValidCwd() throws {
        // Belt-and-suspenders: make sure the guard doesn't reject good
        // cwd inputs. Catches a dumb regression like `if cwd_exists`
        // becoming `if !cwd_exists`.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vch-proc-test-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let runner = DiskProcessRunner()
        let result = try runner.run("/bin/echo", args: ["hi"], cwd: tmp, env: nil)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdoutTrimmed, "hi")
    }
}
