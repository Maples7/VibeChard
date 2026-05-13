import XCTest
@testable import VibeChardCore

final class CleanServiceTests: XCTestCase {

    private let mainRepo = "/repos/Demo"
    private let alphaWT = "/repos/Demo-alpha"
    private let derived = "/repos/Demo-alpha/.agent-build/DerivedData"
    private let moduleCache = "/repos/Demo-alpha/.agent-build/ModuleCache"
    private let swiftpm = "/repos/Demo-alpha/.agent-build/SwiftPM"
    private let testLog = "/repos/Demo-alpha/.vch/last-test.log"

    private func makeService(
        seedingTask raw: String? = "alpha",
        seedDerived: Bool = true,
        seedModuleCache: Bool = true,
        seedSwiftPM: Bool = true,
        seedTestLog: Bool = false,
        scanner: WorktreeHolderScanner? = nil
    ) -> (CleanService, InMemoryFileSystem) {
        let fs = InMemoryFileSystem()
        let workspace = Workspace(mainWorktreePath: mainRepo)
        fs.seedDirectory(mainRepo)
        if let raw {
            let task = try! TaskName(raw)
            fs.seedDirectory(workspace.worktreePath(for: task))
            if seedDerived { fs.seedDirectory(derived) }
            if seedModuleCache { fs.seedDirectory(moduleCache) }
            if seedSwiftPM { fs.seedDirectory(swiftpm) }
            if seedTestLog { fs.seedFile(testLog, data: Data("xcodebuild...".utf8)) }
        }
        return (
            CleanService(workspace: workspace, fs: fs, holderScanner: scanner),
            fs
        )
    }

    // MARK: - default targets

    func testDefaultCleanRemovesDerivedDataAndModuleCacheOnly() throws {
        let (service, fs) = makeService(seedTestLog: true)
        let result = try service.clean(
            task: try TaskName("alpha"),
            options: .init()
        )
        XCTAssertFalse(result.dryRun)
        XCTAssertEqual(result.removed, [derived, moduleCache])
        XCTAssertEqual(result.skipped, [])
        // SwiftPM + log untouched.
        XCTAssertTrue(fs.directoryExists(at: swiftpm))
        XCTAssertTrue(fs.fileExists(at: testLog))
        XCTAssertFalse(fs.directoryExists(at: derived))
        XCTAssertFalse(fs.directoryExists(at: moduleCache))
    }

    // MARK: - flag combinations

    func testIncludeSwiftPMAddsSwiftPMTarget() throws {
        let (service, fs) = makeService()
        let result = try service.clean(
            task: try TaskName("alpha"),
            options: .init(includeSwiftPM: true)
        )
        XCTAssertEqual(result.removed, [derived, moduleCache, swiftpm])
        XCTAssertFalse(fs.directoryExists(at: swiftpm))
    }

    func testIncludeLogsAddsLastTestLog() throws {
        let (service, fs) = makeService(seedTestLog: true)
        let result = try service.clean(
            task: try TaskName("alpha"),
            options: .init(includeLogs: true)
        )
        XCTAssertEqual(result.removed, [derived, moduleCache, testLog])
        XCTAssertFalse(fs.fileExists(at: testLog))
    }

    func testAllOptionRemovesEverything() throws {
        let (service, fs) = makeService(seedTestLog: true)
        _ = try service.clean(
            task: try TaskName("alpha"),
            options: .all
        )
        XCTAssertFalse(fs.directoryExists(at: derived))
        XCTAssertFalse(fs.directoryExists(at: moduleCache))
        XCTAssertFalse(fs.directoryExists(at: swiftpm))
        XCTAssertFalse(fs.fileExists(at: testLog))
    }

    // MARK: - idempotency

    func testCleanIsIdempotentWhenNothingExists() throws {
        let (service, _) = makeService(
            seedDerived: false,
            seedModuleCache: false,
            seedSwiftPM: false
        )
        let result = try service.clean(
            task: try TaskName("alpha"),
            options: .init()
        )
        XCTAssertEqual(result.removed, [])
        XCTAssertEqual(result.skipped, [derived, moduleCache])
    }

    func testRunningCleanTwiceSucceeds() throws {
        let (service, _) = makeService()
        _ = try service.clean(task: try TaskName("alpha"), options: .init())
        let second = try service.clean(task: try TaskName("alpha"), options: .init())
        XCTAssertEqual(second.removed, [])
        XCTAssertEqual(second.skipped, [derived, moduleCache])
    }

    // MARK: - dry-run

    func testDryRunReportsTargetsWithoutDeleting() throws {
        let (service, fs) = makeService()
        let result = try service.clean(
            task: try TaskName("alpha"),
            options: .init(dryRun: true)
        )
        XCTAssertTrue(result.dryRun)
        XCTAssertEqual(result.removed, [derived, moduleCache])
        XCTAssertTrue(fs.directoryExists(at: derived))
        XCTAssertTrue(fs.directoryExists(at: moduleCache))
    }

    // MARK: - guards

    func testCleanThrowsTaskNotFoundWhenWorktreeMissing() {
        let (service, _) = makeService(seedingTask: nil)
        XCTAssertThrowsError(try service.clean(
            task: try TaskName("ghost"),
            options: .init()
        )) { error in
            guard case VibeChardError.taskNotFound = error else {
                return XCTFail("expected taskNotFound, got \(error)")
            }
        }
    }

    func testCleanRefusesWhenAgentBuildHolderActive() {
        let scanner = StubScanner(holders: [
            WorktreeHolder(
                pid: 4321,
                command: "xcodebuild",
                samplePath: "\(derived)/Build/Intermediates.noindex"
            )
        ])
        let (service, fs) = makeService(scanner: scanner)
        XCTAssertThrowsError(try service.clean(
            task: try TaskName("alpha"),
            options: .init()
        )) { error in
            guard case let VibeChardError.cleanBlockedByHolders(task, holders) = error else {
                return XCTFail("expected cleanBlockedByHolders, got \(error)")
            }
            XCTAssertEqual(task, "alpha")
            XCTAssertEqual(holders.count, 1)
            XCTAssertEqual(holders.first?.command, "xcodebuild")
        }
        // No deletion happened.
        XCTAssertTrue(fs.directoryExists(at: derived))
        XCTAssertTrue(fs.directoryExists(at: moduleCache))
    }

    func testCleanIgnoresHoldersOutsideAgentBuildAndDotVch() throws {
        // An editor open at the worktree root or a shell cd'd in
        // shouldn't gate cleanup of `.agent-build/`.
        let scanner = StubScanner(holders: [
            WorktreeHolder(pid: 1, command: "code", samplePath: "\(alphaWT)/README.md"),
            WorktreeHolder(pid: 2, command: "zsh", samplePath: alphaWT),
        ])
        let (service, fs) = makeService(scanner: scanner)
        let result = try service.clean(
            task: try TaskName("alpha"),
            options: .init()
        )
        XCTAssertEqual(result.removed, [derived, moduleCache])
        XCTAssertFalse(fs.directoryExists(at: derived))
    }

    func testDryRunSucceedsEvenWhenHoldersPresent() throws {
        // The whole point of dry-run is to plan ahead while the build
        // is mid-flight.
        let scanner = StubScanner(holders: [
            WorktreeHolder(pid: 99, command: "xcodebuild", samplePath: "\(derived)/foo")
        ])
        let (service, _) = makeService(scanner: scanner)
        let result = try service.clean(
            task: try TaskName("alpha"),
            options: .init(dryRun: true)
        )
        XCTAssertEqual(result.removed, [derived, moduleCache])
    }

    func testTargetsListIsStableAndExpected() {
        let (service, _) = makeService()
        let task = try! TaskName("alpha")
        XCTAssertEqual(
            service.targets(for: task, options: .init()),
            [derived, moduleCache]
        )
        XCTAssertEqual(
            service.targets(for: task, options: .init(includeSwiftPM: true, includeLogs: true)),
            [derived, moduleCache, swiftpm, testLog]
        )
    }

    // MARK: - adopted worktrees at arbitrary paths (#98 follow-up)

    /// For a task adopted via `--adopt-current`, `vch clean` must
    /// scrub `.agent-build/` *inside the adopted worktree* and never
    /// touch anything next to the canonical `<repo>-<task>` path —
    /// which the user may not even own. Regression target: if Clean
    /// ever bypassed the Workspace override and built the targets
    /// from `task.raw`, an adopted task would silently leak caches
    /// into the canonical sidecar path.
    func testCleanScrubsAdoptedAgentBuildAndLeavesCanonicalPathAlone() throws {
        let adoptedPath = "/Users/me/codex-session"
        let task = try TaskName("alpha")
        let workspace = Workspace(mainWorktreePath: mainRepo)
            .withWorktreePath(adoptedPath, for: task)
        let fs = InMemoryFileSystem()
        fs.seedDirectory(mainRepo)
        fs.seedDirectory(adoptedPath)
        let adoptedDerived = "\(adoptedPath)/.agent-build/DerivedData"
        let adoptedModuleCache = "\(adoptedPath)/.agent-build/ModuleCache"
        let adoptedSwiftPM = "\(adoptedPath)/.agent-build/SwiftPM"
        fs.seedDirectory(adoptedDerived)
        fs.seedDirectory(adoptedModuleCache)
        fs.seedDirectory(adoptedSwiftPM)
        // Decoy: a canonical sidecar dir from some past mistake.
        // Clean must NOT touch it.
        fs.seedDirectory("\(mainRepo)-alpha/.agent-build/DerivedData")
        let service = CleanService(workspace: workspace, fs: fs)

        let result = try service.clean(task: task, options: .all)

        XCTAssertEqual(result.removed.sorted(), [
            adoptedDerived,
            adoptedModuleCache,
            adoptedSwiftPM,
        ].sorted())
        XCTAssertFalse(fs.directoryExists(at: adoptedDerived))
        XCTAssertTrue(
            fs.directoryExists(at: "\(mainRepo)-alpha/.agent-build/DerivedData"),
            "Clean must not touch the canonical sidecar path of an adopted task"
        )
    }
}

private final class StubScanner: WorktreeHolderScanner, @unchecked Sendable {
    let holders: [WorktreeHolder]
    init(holders: [WorktreeHolder]) { self.holders = holders }
    func findHolders(of worktreePath: String) throws -> [WorktreeHolder] {
        holders
    }
}
