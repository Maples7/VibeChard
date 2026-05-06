import XCTest
@testable import VibeChardCore

final class ShimLocatorTests: XCTestCase {

    /// Minimal `FileSystem` fake that only answers `fileExists` —
    /// that's all `ShimLocator` calls.
    final class StubFS: FileSystem, @unchecked Sendable {
        var existing: Set<String> = []

        func fileExists(at path: String) -> Bool { existing.contains(path) }
        func directoryExists(at path: String) -> Bool { false }
        func createDirectory(at path: String) throws {}
        func readFile(at path: String) throws -> Data { Data() }
        func writeFileAtomic(_ data: Data, to path: String) throws {}
        func removeItem(at path: String) throws {}
        func symlinkDestination(at path: String) -> String? { nil }
        func createSymbolicLink(at linkPath: String, withDestination destination: String) throws {}
    }

    func testEnvOverrideWinsAhead() {
        let fs = StubFS()
        // We rely on realpath() falling back to the input path when the
        // override doesn't exist on disk, so seed it as a real
        // recognizable path.
        fs.existing = ["/tmp/custom-shim", "/Applications/vch/bin/vch-xcodebuild-shim"]
        let path = ShimLocator.locate(
            vchExecutablePath: "/Applications/vch/bin/vch",
            env: ["VCH_SHIM_PATH": "/tmp/custom-shim"],
            fs: fs
        )
        // realpath() of /tmp resolves to /private/tmp on macOS; tolerate either.
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.hasSuffix("/custom-shim"),
                      "expected env-override path, got \(path ?? "nil")")
    }

    func testFallsBackToSiblingOfVchBinary() {
        let fs = StubFS()
        fs.existing = ["/Users/me/proj/.build/release/vch-xcodebuild-shim"]
        let path = ShimLocator.locate(
            vchExecutablePath: "/Users/me/proj/.build/release/vch",
            env: [:],
            fs: fs
        )
        XCTAssertEqual(path, "/Users/me/proj/.build/release/vch-xcodebuild-shim")
    }

    func testFallsBackToBrewLibexecLayout() {
        let fs = StubFS()
        // Use a fake brew prefix (`/opt/vch-test/...`) so `realpath(3)`
        // can't resolve it to a real Cellar path on a developer's
        // machine that already has `vch` installed via the tap. With
        // a real `/opt/homebrew/bin/vch` symlink present, realpath
        // would return the Cellar path and break the layout inference.
        fs.existing = ["/opt/vch-test/libexec/vch-xcodebuild-shim"]
        let path = ShimLocator.locate(
            vchExecutablePath: "/opt/vch-test/bin/vch",
            env: [:],
            fs: fs
        )
        XCTAssertEqual(path, "/opt/vch-test/libexec/vch-xcodebuild-shim")
    }

    func testReturnsNilWhenNothingFound() {
        let fs = StubFS()
        let path = ShimLocator.locate(
            vchExecutablePath: "/usr/local/bin/vch",
            env: [:],
            fs: fs
        )
        XCTAssertNil(path)
    }

    func testEmptyEnvOverrideIsIgnored() {
        let fs = StubFS()
        fs.existing = ["/Users/me/.build/release/vch-xcodebuild-shim"]
        let path = ShimLocator.locate(
            vchExecutablePath: "/Users/me/.build/release/vch",
            env: ["VCH_SHIM_PATH": "  "],
            fs: fs
        )
        XCTAssertEqual(path, "/Users/me/.build/release/vch-xcodebuild-shim")
    }
}
