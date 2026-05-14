import XCTest
@testable import VibeChardCore

final class RunbookLocatorTests: XCTestCase {

    /// Minimal `FileSystem` stub — `RunbookLocator` only calls `fileExists`.
    private final class StubFS: FileSystem, @unchecked Sendable {
        var existing: Set<String> = []

        func fileExists(at path: String) -> Bool { existing.contains(path) }
        func directoryExists(at path: String) -> Bool { false }
        func createDirectory(at path: String) throws {}
        func readFile(at path: String) throws -> Data { Data() }
        func writeFileAtomic(_ data: Data, to path: String) throws {}
        func removeItem(at path: String) throws {}
        func symlinkDestination(at path: String) -> String? { nil }
        func createSymbolicLink(at linkPath: String, withDestination destination: String) throws {}
        func copyItem(from source: String, to destination: String) throws {}
        func cloneItem(from source: String, to destination: String) throws {}
    }

    // Use a fake prefix so realpath(3) cannot resolve it to a real Cellar
    // path on a machine with vch already installed — same pattern as
    // ShimLocatorTests.
    private let fakePrefix = "/opt/vch-test"

    func testInstalledPathReturnsCandidateWhenFileExists() {
        let fs = StubFS()
        let expected = "\(fakePrefix)/share/doc/vch/agent-runbook.md"
        fs.existing = [expected]

        let result = RunbookLocator.installedPath(
            executablePath: "\(fakePrefix)/bin/vch",
            fs: fs
        )
        XCTAssertEqual(result, expected)
    }

    func testInstalledPathReturnsNilWhenFileMissing() {
        let fs = StubFS()   // nothing seeded
        let result = RunbookLocator.installedPath(
            executablePath: "\(fakePrefix)/bin/vch",
            fs: fs
        )
        XCTAssertNil(result)
    }

    func testInstalledPathReturnsNilForBareExecutableName() {
        let fs = StubFS()
        let result = RunbookLocator.installedPath(
            executablePath: "vch",
            fs: fs
        )
        XCTAssertNil(result, "bare name has no '/' so prefix inference is impossible")
    }

    func testInstalledPathReturnsNilForEmptyString() {
        let fs = StubFS()
        let result = RunbookLocator.installedPath(
            executablePath: "",
            fs: fs
        )
        XCTAssertNil(result)
    }

    func testInstalledPathReturnsNilForWhitespaceOnlyString() {
        let fs = StubFS()
        let result = RunbookLocator.installedPath(
            executablePath: "   ",
            fs: fs
        )
        XCTAssertNil(result)
    }
}
