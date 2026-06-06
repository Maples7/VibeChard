import XCTest
@testable import VibeChardCore

/// Regression tripwire for VibeChard's headline promise: *N parallel
/// agents, each in its own worktree, never collide on a shared Apple
/// toolchain resource* (`DerivedData`, `ModuleCache`, the SwiftPM clone
/// dir, or the `xcresult` bundle), and **nothing vch hands a child
/// process points at a global location** (AGENTS.md rule #9 — every
/// byte vch writes lands inside the task's own `.vch/` or
/// `.agent-build/`).
///
/// The existing `ExecServiceTests` assert the env layout for a *single*
/// task. This suite asserts the *cross-task* invariant — the property
/// that actually keeps two concurrent `xcodebuild` runs from corrupting
/// each other's module cache or racing on `build.db`. It exercises the
/// real injection point (`ExecService.buildEnv`, the env every
/// `vch exec` / `vch <name>` child receives) rather than re-deriving
/// paths, so a future refactor that quietly repoints a cache at a
/// shared/global root fails here instead of in a user's parallel
/// session.
final class IsolationGuaranteeTests: XCTestCase {

    /// Env keys whose values MUST be unique per task. If any two tasks
    /// ever share one of these, parallel `xcodebuild` runs race.
    private static let isolationBearingKeys = [
        "VCH_DERIVED_DATA_PATH",
        "VCH_SPM_CLONE_DIR",
        "VCH_RESULT_BUNDLE_PATH",
        "VCH_RESULT_BUNDLE_DIR",
        "CLANG_MODULE_CACHE_PATH",
        "SWIFTPM_CACHE_DIR",
        "VCH_TASK_ROOT",
    ]

    /// Global Apple-toolchain locations that vch exists to *avoid*
    /// contending on. No isolated path may ever resolve under one of
    /// these (the simulator-clone exception in rule #9 lives under
    /// `CoreSimulator/Devices` and is never an env path here).
    private static let forbiddenGlobalFragments = [
        "/Library/Developer/Xcode/DerivedData",
        "/Library/Developer/CoreSimulator",
        "/Library/Caches/org.swift.swiftpm",
    ]

    private func makeService(_ workspace: Workspace) -> ExecService {
        // buildEnv is a pure transform over `workspace` + `task`; it
        // does not stat the filesystem, so no seeding is needed. We
        // pass no DeveloperDirResolver: DEVELOPER_DIR is intentionally
        // a *shared* value (same Xcode for every task) and is therefore
        // not part of the isolation contract under test.
        ExecService(workspace: workspace, git: FakeGitClient(), fs: InMemoryFileSystem())
    }

    private func env(_ service: ExecService, _ workspace: Workspace, _ raw: String) throws -> [String: String] {
        let task = try TaskName(raw)
        return service.buildEnv(
            task: task,
            worktree: workspace.worktreePath(for: task),
            baseEnv: ["PATH": "/usr/bin:/bin"]
        )
    }

    /// `true` when `child` lives inside `parent`'s directory subtree,
    /// using a trailing-slash boundary so `/r/Demo-auth` is correctly
    /// judged *not* to contain `/r/Demo-auth-redesign`.
    private func isContained(_ child: String, in parent: String) -> Bool {
        child == parent || child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }

    // MARK: - Default sibling layout

    func testIsolationPathsArePairwiseDistinctAcrossTasks() throws {
        let workspace = Workspace(mainWorktreePath: "/repos/Demo")
        let service = makeService(workspace)
        // Deliberately include a string-prefix pair ("auth" /
        // "auth-redesign") to prove the guarantee holds even when one
        // task name is a literal prefix of another.
        let names = ["alpha", "beta", "gamma", "auth", "auth-redesign", "feature.x"]
        let envs = try names.map { try env(service, workspace, $0) }

        for key in Self.isolationBearingKeys {
            let values = envs.map { $0[key] ?? "<missing>" }
            XCTAssertFalse(values.contains("<missing>"), "every task must set \(key)")
            XCTAssertEqual(Set(values).count, values.count,
                           "\(key) must be unique per task; collisions: \(values)")
        }
    }

    func testEveryIsolatedPathIsRootedInsideItsOwnWorktree() throws {
        let workspace = Workspace(mainWorktreePath: "/repos/Demo")
        let service = makeService(workspace)
        for raw in ["alpha", "auth", "auth-redesign", "feature.x"] {
            let task = try TaskName(raw)
            let worktree = workspace.worktreePath(for: task)
            let e = try env(service, workspace, raw)
            for key in Self.isolationBearingKeys {
                let path = try XCTUnwrap(e[key])
                XCTAssertTrue(isContained(path, in: worktree),
                              "\(key)=\(path) must live inside worktree \(worktree)")
            }
            // The shim symlinks must be reachable via the task's own
            // prepended bin dir, and it must win PATH resolution.
            let path = try XCTUnwrap(e["PATH"])
            XCTAssertEqual(path.split(separator: ":").first.map(String.init),
                           workspace.vchBinDir(for: task),
                           "<wt>/.vch/bin must be the first PATH entry")
        }
    }

    func testNoIsolatedPathEscapesToAGlobalAppleToolchainLocation() throws {
        let workspace = Workspace(mainWorktreePath: "/repos/Demo")
        let service = makeService(workspace)
        for raw in ["alpha", "beta", "feature.x"] {
            let e = try env(service, workspace, raw)
            for key in Self.isolationBearingKeys {
                let path = try XCTUnwrap(e[key])
                for fragment in Self.forbiddenGlobalFragments {
                    XCTAssertFalse(path.contains(fragment),
                                   "rule #9: \(key)=\(path) must not resolve under the global \(fragment)")
                }
            }
        }
    }

    func testTaskWorktreesArePairwiseNonNestedSubtrees() throws {
        let workspace = Workspace(mainWorktreePath: "/repos/Demo")
        // "auth" vs "auth-redesign" is the boundary case: the former's
        // path is a string prefix of the latter's, but they are
        // distinct sibling directories, so neither contains the other.
        let names = ["auth", "auth-redesign", "alpha", "feature.x"]
        let worktrees = try names.map { workspace.worktreePath(for: try TaskName($0)) }
        for i in worktrees.indices {
            for j in worktrees.indices where i != j {
                XCTAssertFalse(isContained(worktrees[i], in: worktrees[j]),
                               "\(worktrees[i]) must not be nested inside \(worktrees[j])")
            }
        }
    }

    // MARK: - Adopted / override layout

    func testIsolationHoldsForAdoptedWorktreesInArbitraryDirectories() throws {
        // Agent-created linked worktrees (VS Code / Codex) live wherever
        // the tool put them, registered via `withWorktreePath`. The
        // isolation guarantee must not depend on the `<repo>-<task>`
        // sibling convention.
        var workspace = Workspace(mainWorktreePath: "/repos/Demo")
        workspace = workspace.withWorktreePath("/tmp/agent-sessions/session-1", for: try TaskName("alpha"))
        workspace = workspace.withWorktreePath("/var/folders/xy/codex-scratch", for: try TaskName("beta"))
        let service = makeService(workspace)

        let a = try env(service, workspace, "alpha")
        let b = try env(service, workspace, "beta")

        for key in Self.isolationBearingKeys {
            XCTAssertNotEqual(a[key], b[key],
                              "\(key) must stay isolated across adopted worktrees")
        }
        // Each still rooted in its own (arbitrary) worktree directory.
        XCTAssertTrue(isContained(try XCTUnwrap(a["VCH_DERIVED_DATA_PATH"]), in: "/tmp/agent-sessions/session-1"))
        XCTAssertTrue(isContained(try XCTUnwrap(b["VCH_DERIVED_DATA_PATH"]), in: "/var/folders/xy/codex-scratch"))
    }
}
