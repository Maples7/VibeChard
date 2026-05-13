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

    // MARK: - DEVELOPER_DIR injection (#31)

    func testBuildEnvInjectsDeveloperDirFromResolverWhenAbsent() {
        let fs = InMemoryFileSystem()
        let workspace = Workspace(mainWorktreePath: mainRepo)
        fs.seedDirectory(workspace.worktreePath(for: try! TaskName("alpha")))
        let service = ExecService(
            workspace: workspace, git: FakeGitClient(), fs: fs,
            developerDir: StubDeveloperDir("/Apps/Xcode.app/Contents/Developer")
        )
        let env = service.buildEnv(
            task: try! TaskName("alpha"),
            worktree: "/repos/Demo-alpha",
            baseEnv: [:]
        )
        XCTAssertEqual(env["DEVELOPER_DIR"],
                       "/Apps/Xcode.app/Contents/Developer")
    }

    func testBuildEnvPreservesUserDeveloperDirOverride() {
        let fs = InMemoryFileSystem()
        let workspace = Workspace(mainWorktreePath: mainRepo)
        fs.seedDirectory(workspace.worktreePath(for: try! TaskName("alpha")))
        let service = ExecService(
            workspace: workspace, git: FakeGitClient(), fs: fs,
            developerDir: StubDeveloperDir("/Apps/Xcode.app/Contents/Developer")
        )
        let env = service.buildEnv(
            task: try! TaskName("alpha"),
            worktree: "/repos/Demo-alpha",
            baseEnv: ["DEVELOPER_DIR": "/Custom/Xcode-beta.app/Contents/Developer"]
        )
        XCTAssertEqual(env["DEVELOPER_DIR"],
                       "/Custom/Xcode-beta.app/Contents/Developer")
    }

    func testBuildEnvOmitsDeveloperDirWhenNoResolver() {
        // Default init (no resolver, today's behavior) must stay
        // deterministic for the existing unit test corpus.
        let (service, _, _) = makeService(seedingTask: "alpha")
        let env = service.buildEnv(
            task: try! TaskName("alpha"),
            worktree: "/repos/Demo-alpha",
            baseEnv: [:]
        )
        XCTAssertNil(env["DEVELOPER_DIR"])
    }

    // MARK: - adopted worktrees at arbitrary paths (#98 follow-up)

    /// `vch new <name> --adopt-current` is followed (when `--exec` is
    /// passed) by an `ExecService.prepare` call against a Workspace
    /// whose `taskWorktreePaths` overrides the conventional path.
    /// Every artefact ExecService installs must land inside the
    /// adopted worktree, not next to the canonical
    /// `<repo>-<task>` path.
    func testPrepareUsesAdoptedWorktreeAsCwdAndInstallsShimsThere() throws {
        let adoptedPath = "/Users/me/codex-session"
        let task = try TaskName("alpha")
        let workspace = Workspace(mainWorktreePath: mainRepo)
            .withWorktreePath(adoptedPath, for: task)
        let fs = InMemoryFileSystem()
        let git = FakeGitClient()
        fs.seedDirectory(mainRepo)
        fs.seedDirectory(adoptedPath)
        let service = ExecService(workspace: workspace, git: git, fs: fs)

        let plan = try service.prepare(
            task: task,
            command: ["/bin/sh", "-c", "echo hi"],
            shimPath: "/opt/vch/libexec/vch-xcodebuild-shim",
            baseEnv: ["PATH": "/usr/bin"]
        )

        XCTAssertEqual(plan.cwd, adoptedPath)
        XCTAssertEqual(plan.installedShimSymlinks, [
            "\(adoptedPath)/.vch/bin/xcodebuild",
            "\(adoptedPath)/.vch/bin/xcrun",
            "\(adoptedPath)/.vch/bin/swift",
        ])
        XCTAssertEqual(
            fs.symlink(at: "\(adoptedPath)/.vch/bin/xcodebuild"),
            "/opt/vch/libexec/vch-xcodebuild-shim"
        )
        XCTAssertTrue(fs.directoryExists(at: "\(adoptedPath)/.agent-build/DerivedData"))
        // The canonical path must not have been created behind the
        // user's back; if it has, the override is being bypassed.
        XCTAssertFalse(
            fs.directoryExists(at: "\(mainRepo)-alpha/.vch/bin"),
            "ExecService leaked .vch/bin to the conventional path"
        )
    }

    /// `buildEnv` is the single function the CLI calls to populate
    /// shim and tooling vars. For adopted tasks every `VCH_*` env
    /// var must be rooted at the override, including the PATH
    /// prepend.
    func testBuildEnvRootsShimVarsAtAdoptedWorktree() {
        let adoptedPath = "/Users/me/codex-session"
        let task = try! TaskName("alpha")
        let workspace = Workspace(mainWorktreePath: mainRepo)
            .withWorktreePath(adoptedPath, for: task)
        let fs = InMemoryFileSystem()
        fs.seedDirectory(adoptedPath)
        let service = ExecService(workspace: workspace, git: FakeGitClient(), fs: fs)

        let env = service.buildEnv(
            task: task,
            worktree: adoptedPath,
            baseEnv: ["PATH": "/usr/bin"]
        )
        XCTAssertEqual(env["VCH_TASK_ROOT"], adoptedPath)
        XCTAssertEqual(env["VCH_DERIVED_DATA_PATH"],
                       "\(adoptedPath)/.agent-build/DerivedData")
        XCTAssertEqual(env["CLANG_MODULE_CACHE_PATH"],
                       "\(adoptedPath)/.agent-build/ModuleCache")
        XCTAssertEqual(env["SWIFTPM_CACHE_DIR"],
                       "\(adoptedPath)/.agent-build/SwiftPM")
        XCTAssertEqual(env["PATH"], "\(adoptedPath)/.vch/bin:/usr/bin")
    }
}

private struct StubDeveloperDir: DeveloperDirResolver {
    let value: String?
    init(_ value: String?) { self.value = value }
    func resolve() -> String? { value }
}
