import XCTest
@testable import VibeChardCore

/// Real-disk tests for `DiskFileSystem`. These pin defensive behaviours
/// that protect user data from silent loss — fakes don't catch
/// regressions here because `InMemoryFileSystem` reimplements the same
/// guards independently.
final class DiskFileSystemTests: XCTestCase {

    private var tmp: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vch-fs-test-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(atPath: tmp) }
        try super.tearDownWithError()
    }

    // MARK: - createSymbolicLink

    func testCreateSymbolicLinkRefusesWhenRegularFileExists() throws {
        // Real-world hazard: a stray regular file at a managed symlink
        // path (e.g. `.agent-build/<task>` left behind by a manual
        // tinker). Must not silently delete it — the file may be the
        // user's only copy of something.
        let blocker = "\(tmp!)/agent-build-blocker"
        XCTAssertTrue(FileManager.default.createFile(
            atPath: blocker,
            contents: Data("important data".utf8)
        ))

        let fs = DiskFileSystem()
        XCTAssertThrowsError(
            try fs.createSymbolicLink(at: blocker, withDestination: "/dev/null")
        ) { err in
            guard case let VibeChardError.externalCommandFailed(cmd, exitCode, stderr) = err else {
                return XCTFail("expected externalCommandFailed, got \(err)")
            }
            XCTAssertEqual(cmd, "createSymbolicLink")
            XCTAssertEqual(exitCode, 17, "exit 17 = EEXIST so wrappers can branch on it")
            XCTAssertTrue(
                stderr.contains("non-symlink already exists") && stderr.contains(blocker),
                "stderr should name what's blocking; got: \(stderr)"
            )
        }
        // Untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocker))
        XCTAssertEqual(try String(contentsOfFile: blocker), "important data")
    }

    func testCreateSymbolicLinkIsIdempotentForMatchingDestination() throws {
        // Re-running `vch new` repeatedly must not bump symlink mtimes
        // or noisily error if the link already points where we want.
        let target = "\(tmp!)/destination"
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        let link = "\(tmp!)/link"

        let fs = DiskFileSystem()
        try fs.createSymbolicLink(at: link, withDestination: target)
        try fs.createSymbolicLink(at: link, withDestination: target) // re-run: must not throw

        let resolved = try FileManager.default.destinationOfSymbolicLink(atPath: link)
        XCTAssertEqual(resolved, target)
    }

    func testCreateSymbolicLinkReplacesStaleSymlink() throws {
        // When the symlink already exists pointing somewhere else
        // (worktree was moved, or the user `rm -rf`'d the destination
        // dir), `vch` updates it in place.
        let oldTarget = "\(tmp!)/old"
        let newTarget = "\(tmp!)/new"
        try FileManager.default.createDirectory(atPath: oldTarget, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: newTarget, withIntermediateDirectories: true)
        let link = "\(tmp!)/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: oldTarget)

        let fs = DiskFileSystem()
        try fs.createSymbolicLink(at: link, withDestination: newTarget)

        let resolved = try FileManager.default.destinationOfSymbolicLink(atPath: link)
        XCTAssertEqual(resolved, newTarget)
    }
}
