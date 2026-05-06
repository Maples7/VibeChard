import XCTest
@testable import VibeChardCore

final class ExecServiceTests: XCTestCase {

    private let mainRepo = "/repos/Demo"

    private func makeService(
        seedingMain: Bool = true,
        seedingTask raw: String? = nil
    ) -> (ExecService, InMemoryFileSystem, FakeGitClient) {
        let fs = InMemoryFileSystem()
        let git = FakeGitClient()
        let workspace = Workspace(mainWorktreePath: mainRepo)
        if seedingMain { fs.seedDirectory(mainRepo) }
        if let raw {
            let wt = workspace.worktreePath(for: try! TaskName(raw))
            fs.seedDirectory(wt)
        }
        return (ExecService(workspace: workspace, git: git, fs: fs), fs, git)
    }

    // MARK: - prepare()

    func testPrepareInstallsThreeShimSymlinksIdempotently() throws {
        let (service, fs, _) = makeService(seedingTask: "alpha")

        let plan1 = try service.prepare(
            task: try TaskName("alpha"),
            command: ["/bin/bash", "-l"],
            shimPath: "/opt/vch/libexec/vch-xcodebuild-shim",
            baseEnv: [:]
        )
        XCTAssertEqual(plan1.installedShimSymlinks, [
            "/repos/Demo-alpha/.vch/bin/xcodebuild",
            "/repos/Demo-alpha/.vch/bin/xcrun",
            "/repos/Demo-alpha/.vch/bin/swift",
        ])
        XCTAssertEqual(fs.symlink(at: "/repos/Demo-alpha/.vch/bin/xcodebuild"),
                       "/opt/vch/libexec/vch-xcodebuild-shim")
        XCTAssertEqual(fs.symlink(at: "/repos/Demo-alpha/.vch/bin/swift"),
                       "/opt/vch/libexec/vch-xcodebuild-shim")

        // Re-running prepare must NOT throw, and must update the
        // symlink target if the shim moved (e.g. brew upgrade).
        let plan2 = try service.prepare(
            task: try TaskName("alpha"),
            command: ["/bin/bash"],
            shimPath: "/opt/vch/libexec/vch-xcodebuild-shim-v2",
            baseEnv: [:]
        )
        XCTAssertEqual(plan2.installedShimSymlinks.count, 3)
        XCTAssertEqual(fs.symlink(at: "/repos/Demo-alpha/.vch/bin/xcodebuild"),
                       "/opt/vch/libexec/vch-xcodebuild-shim-v2")
    }

    func testPrepareCreatesAgentBuildScratchDirs() throws {
        let (service, fs, _) = makeService(seedingTask: "alpha")
        _ = try service.prepare(
            task: try TaskName("alpha"),
            command: ["/bin/sh"],
            shimPath: "/opt/vch/libexec/vch-xcodebuild-shim",
            baseEnv: [:]
        )
        XCTAssertTrue(fs.directoryExists(at: "/repos/Demo-alpha/.vch/bin"))
        XCTAssertTrue(fs.directoryExists(at: "/repos/Demo-alpha/.agent-build/DerivedData"))
        XCTAssertTrue(fs.directoryExists(at: "/repos/Demo-alpha/.agent-build/SwiftPM"))
        XCTAssertTrue(fs.directoryExists(at: "/repos/Demo-alpha/.agent-build/ModuleCache"))
    }

    func testPrepareThrowsWhenWorktreeMissing() throws {
        let (service, _, _) = makeService(seedingTask: nil)
        XCTAssertThrowsError(try service.prepare(
            task: try TaskName("ghost"),
            command: ["/bin/sh"],
            shimPath: "/opt/shim",
            baseEnv: [:]
        )) { error in
            guard case VibeChardError.taskNotFound = error else {
                return XCTFail("expected taskNotFound, got \(error)")
            }
        }
    }

    func testPrepareThrowsOnEmptyCommand() throws {
        let (service, _, _) = makeService(seedingTask: "alpha")
        XCTAssertThrowsError(try service.prepare(
            task: try TaskName("alpha"),
            command: [],
            shimPath: "/opt/shim",
            baseEnv: [:]
        )) { error in
            guard case VibeChardError.missingArgument = error else {
                return XCTFail("expected missingArgument, got \(error)")
            }
        }
    }

    // MARK: - buildEnv()

    func testBuildEnvPrependsBinDirToPATHWithoutWipingExistingPath() {
        let (service, _, _) = makeService(seedingTask: "alpha")
        let env = service.buildEnv(
            task: try! TaskName("alpha"),
            worktree: "/repos/Demo-alpha",
            baseEnv: ["PATH": "/usr/local/bin:/usr/bin", "HOME": "/Users/me"]
        )
        XCTAssertEqual(env["PATH"], "/repos/Demo-alpha/.vch/bin:/usr/local/bin:/usr/bin")
        // Pre-existing keys must be preserved.
        XCTAssertEqual(env["HOME"], "/Users/me")
    }

    func testBuildEnvSuppliesADefaultPATHWhenBaseEnvHasNone() {
        let (service, _, _) = makeService(seedingTask: "alpha")
        let env = service.buildEnv(
            task: try! TaskName("alpha"),
            worktree: "/repos/Demo-alpha",
            baseEnv: [:]
        )
        XCTAssertTrue(env["PATH"]!.hasPrefix("/repos/Demo-alpha/.vch/bin:"))
        XCTAssertTrue(env["PATH"]!.contains("/usr/bin"))
    }

    func testBuildEnvSetsAllShimAndToolEnvVars() {
        let (service, _, _) = makeService(seedingTask: "alpha")
        let env = service.buildEnv(
            task: try! TaskName("alpha"),
            worktree: "/repos/Demo-alpha",
            baseEnv: [:]
        )
        XCTAssertEqual(env["VCH_DERIVED_DATA_PATH"], "/repos/Demo-alpha/.agent-build/DerivedData")
        XCTAssertEqual(env["VCH_SPM_CLONE_DIR"],     "/repos/Demo-alpha/.agent-build/SwiftPM")
        XCTAssertEqual(env["VCH_RESULT_BUNDLE_PATH"], "/repos/Demo-alpha/.agent-build/Result.xcresult")
        XCTAssertEqual(env["CLANG_MODULE_CACHE_PATH"], "/repos/Demo-alpha/.agent-build/ModuleCache")
        XCTAssertEqual(env["SWIFTPM_CACHE_DIR"],       "/repos/Demo-alpha/.agent-build/SwiftPM")
        XCTAssertEqual(env["VCH_TASK_NAME"],          "alpha")
        XCTAssertEqual(env["VCH_TASK_ROOT"],          "/repos/Demo-alpha")
        XCTAssertEqual(env["VCH_RESULT_BUNDLE_DIR"],  "/repos/Demo-alpha/.agent-build")
    }
}
