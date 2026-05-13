import XCTest
@testable import VibeChardCore

final class BugReportServiceTests: XCTestCase {

    // MARK: - happy path

    func testCollectIncludesManifestVersionWorktreeListAndProbes() throws {
        let workspace = Workspace(mainWorktreePath: "/Users/test/Repo")
        let git = FakeGitClient()
        let fs = InMemoryFileSystem()
        let runner = ScriptedRunner(scripts: [
            "/usr/bin/sw_vers": .stdout("ProductName:\tmacOS\nProductVersion:\t14.5\n"),
            "/usr/bin/xcode-select": .stdout("/Applications/Xcode.app/Contents/Developer\n"),
            "/usr/bin/xcrun": .stdout("/Applications/Xcode.app/.../xcodebuild\n"),
            "/usr/bin/swift": .stdout("Apple Swift version 5.10\n"),
        ])
        let service = BugReportService(
            workspace: workspace,
            git: git,
            fs: fs,
            runner: runner,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            homeDir: { "/Users/test" }
        )

        let entries = try service.collect()
        let paths = entries.map(\.path)

        XCTAssertEqual(paths.first, "MANIFEST.txt", "MANIFEST is the table-of-contents and must lead")
        XCTAssertTrue(paths.contains("vch-version.txt"))
        XCTAssertTrue(paths.contains("git/worktree-list.txt"))
        XCTAssertTrue(paths.contains("system/sw_vers.txt"))
        XCTAssertTrue(paths.contains("system/xcode-select-p.txt"))
        XCTAssertTrue(paths.contains("system/xcrun-f-xcodebuild.txt"))
        XCTAssertTrue(paths.contains("system/swift-version.txt"))
    }

    // MARK: - per-task state.json + last-test.log

    func testCollectIncludesEachTasksStateAndLastTestLog() throws {
        let workspace = Workspace(mainWorktreePath: "/Users/test/Repo")
        let git = FakeGitClient()
        git.entries = [
            WorktreeEntry(path: "/Users/test/Repo", branch: "main"),
            WorktreeEntry(path: "/Users/test/Repo-feature", branch: "agent/feature"),
        ]
        let fs = InMemoryFileSystem()
        let state = TaskState(
            name: "feature",
            branch: "agent/feature",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            baseRef: "deadbeef"
        )
        try fs.writeFileAtomic(state.jsonData(), to: "/Users/test/Repo-feature/.vch/state.json")
        fs.seedFile(
            "/Users/test/Repo-feature/.vch/last-test.log",
            data: Data("[2025-01-01T00:00Z] tests passed\n".utf8)
        )

        let service = BugReportService(
            workspace: workspace,
            git: git,
            fs: fs,
            runner: ScriptedRunner(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            homeDir: { "/Users/test" }
        )
        let entries = try service.collect()
        let paths = entries.map(\.path)
        XCTAssertTrue(paths.contains("tasks/feature/state.json"))
        XCTAssertTrue(paths.contains("tasks/feature/last-test.log"))

        // Main worktree is filtered out, not bundled as a "task".
        XCTAssertFalse(paths.contains { $0.contains("tasks/Repo") })
    }

    func testCollectIncludesAdoptedWorktreeAtArbitraryPath() throws {
        let workspace = Workspace(mainWorktreePath: "/Users/test/Repo")
        let git = FakeGitClient()
        git.entries = [
            WorktreeEntry(path: "/Users/test/Repo", branch: "main"),
            WorktreeEntry(path: "/Users/test/codex-session", branch: "feature/codex"),
        ]
        let fs = InMemoryFileSystem()
        let state = TaskState(
            name: "codex-task",
            branch: "feature/codex",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            baseRef: "deadbeef",
            worktreeOwnership: .adopted
        )
        try fs.writeFileAtomic(
            state.jsonData(),
            to: "/Users/test/codex-session/.vch/state.json"
        )

        let service = BugReportService(
            workspace: workspace,
            git: git,
            fs: fs,
            runner: ScriptedRunner(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            homeDir: { "/Users/test" }
        )

        let paths = try service.collect().map(\.path)
        XCTAssertTrue(paths.contains("tasks/codex-task/state.json"))
    }

    func testLastTestLogIsCappedToTailBytes() throws {
        let workspace = Workspace(mainWorktreePath: "/Users/test/Repo")
        let git = FakeGitClient()
        git.entries = [
            WorktreeEntry(path: "/Users/test/Repo", branch: "main"),
            WorktreeEntry(path: "/Users/test/Repo-feature", branch: "agent/feature"),
        ]
        let fs = InMemoryFileSystem()
        let state = TaskState(name: "feature", branch: "agent/feature",
                              createdAt: Date(timeIntervalSince1970: 1), baseRef: "")
        try fs.writeFileAtomic(state.jsonData(), to: "/Users/test/Repo-feature/.vch/state.json")
        // 1024 bytes of payload, cap at 100. Leading 'A's should be
        // dropped; trailing 'Z's preserved.
        let big = Data(repeating: UInt8(ascii: "A"), count: 924)
            + Data(repeating: UInt8(ascii: "Z"), count: 100)
        fs.seedFile("/Users/test/Repo-feature/.vch/last-test.log", data: big)

        let service = BugReportService(
            workspace: workspace,
            git: git,
            fs: fs,
            runner: ScriptedRunner(),
            now: { Date(timeIntervalSince1970: 0) },
            homeDir: { "/Users/test" },
            lastTestLogTailBytes: 100
        )
        let entries = try service.collect()
        let log = entries.first { $0.path == "tasks/feature/last-test.log" }
        XCTAssertNotNil(log)
        XCTAssertEqual(log?.data.count, 100)
        XCTAssertEqual(log?.data.first, UInt8(ascii: "Z"))
        XCTAssertEqual(log?.data.last, UInt8(ascii: "Z"))
    }

    // MARK: - $HOME scrubbing

    func testHomePathsAreScrubbedFromTextualEntries() throws {
        let workspace = Workspace(mainWorktreePath: "/Users/jane/Repo")
        let git = FakeGitClient()
        git.entries = [
            WorktreeEntry(path: "/Users/jane/Repo", branch: "main"),
            WorktreeEntry(path: "/Users/jane/Repo-feature", branch: "agent/feature"),
        ]
        let fs = InMemoryFileSystem()
        // Seed a state file whose JSON path mentions the username.
        fs.seedFile(
            "/Users/jane/Repo-feature/.vch/state.json",
            data: Data(#"{"name":"feature","cwd":"/Users/jane/Repo-feature/sub"}"#.utf8)
        )

        let service = BugReportService(
            workspace: workspace,
            git: git,
            fs: fs,
            runner: ScriptedRunner(scripts: [
                "/usr/bin/sw_vers": .stdout("/Users/jane in stdout for some reason\n"),
            ]),
            now: { Date(timeIntervalSince1970: 0) },
            homeDir: { "/Users/jane" }
        )
        let entries = try service.collect()

        for entry in entries {
            let text = String(data: entry.data, encoding: .utf8) ?? ""
            XCTAssertFalse(
                text.contains("/Users/jane"),
                "entry \(entry.path) leaked /Users/jane"
            )
        }
        let state = entries.first { $0.path == "tasks/feature/state.json" }!
        let stateText = String(data: state.data, encoding: .utf8) ?? ""
        XCTAssertTrue(stateText.contains("$HOME/Repo-feature/sub"))
    }

    // MARK: - resilience

    func testCollectSurvivesProcessRunnerFailures() throws {
        let workspace = Workspace(mainWorktreePath: "/Users/test/Repo")
        let git = FakeGitClient()
        let fs = InMemoryFileSystem()
        let runner = ScriptedRunner(scripts: [
            "/usr/bin/xcrun": .throwing,
        ])
        let service = BugReportService(
            workspace: workspace,
            git: git,
            fs: fs,
            runner: runner,
            now: { Date(timeIntervalSince1970: 0) },
            homeDir: { "/Users/test" }
        )
        let entries = try service.collect()
        let xcrun = entries.first { $0.path == "system/xcrun-f-xcodebuild.txt" }
        XCTAssertNotNil(xcrun)
        let body = String(data: xcrun?.data ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("error:"),
                      "process failures should be recorded inline rather than aborting collect()")
    }

    func testCollectAddsNoteWhenStateFileMissing() throws {
        let workspace = Workspace(mainWorktreePath: "/Users/test/Repo")
        let git = FakeGitClient()
        git.entries = [
            WorktreeEntry(path: "/Users/test/Repo", branch: "main"),
            WorktreeEntry(path: "/Users/test/Repo-orphan", branch: "agent/orphan"),
        ]
        let fs = InMemoryFileSystem()
        // Intentionally do NOT write state.json for "orphan".

        let service = BugReportService(
            workspace: workspace,
            git: git,
            fs: fs,
            runner: ScriptedRunner(),
            now: { Date(timeIntervalSince1970: 0) },
            homeDir: { "/Users/test" }
        )
        let entries = try service.collect()
        let manifest = entries.first { $0.path == "MANIFEST.txt" }!
        let manifestText = String(data: manifest.data, encoding: .utf8) ?? ""
        XCTAssertTrue(manifestText.contains("orphan: no state.json on disk"))
        // The bundle still includes the worktree-list etc.; missing
        // state is a note, not a failure.
        XCTAssertTrue(entries.contains { $0.path == "git/worktree-list.txt" })
    }

    // MARK: - default output name

    func testDefaultOutputNameUsesUTCStampAndTgzExtension() {
        let workspace = Workspace(mainWorktreePath: "/Users/test/Repo")
        let service = BugReportService(
            workspace: workspace,
            git: FakeGitClient(),
            fs: InMemoryFileSystem(),
            runner: ScriptedRunner(),
            // Wed, 14 Mar 2018 14:40:00 UTC
            now: { Date(timeIntervalSince1970: 1_521_038_400) },
            homeDir: { "/Users/test" }
        )
        XCTAssertEqual(service.defaultOutputName(),
                       "vch-bug-report-20180314T144000Z.tgz")
    }

    // MARK: - warm-templates.json (#47)

    func testCollectIncludesWarmTemplatesJSONWhenSimctlInjected() throws {
        let workspace = Workspace(mainWorktreePath: "/Users/test/Repo")
        let fs = InMemoryFileSystem()
        let runner = ScriptedRunner()
        let simctl = FakeSimctl()
        simctl.allDevicesOverride = [
            SimDevice(udid: "WARM",
                      name: "vch-warm[iPhone 16:iOS 26.4]",
                      runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
                      runtimeVersion: .init(major: 26, minor: 4),
                      isAvailable: true,
                      state: "Shutdown"),
        ]
        let service = BugReportService(
            workspace: workspace,
            git: FakeGitClient(),
            fs: fs,
            runner: runner,
            simctl: simctl,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            homeDir: { "/Users/test" }
        )
        let entries = try service.collect()
        let warm = entries.first { $0.path == "warm-templates.json" }
        XCTAssertNotNil(warm, "warm-templates.json must be in the bundle when simctl is wired")

        let body = String(data: warm!.data, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("\"WARM\""))
        XCTAssertTrue(body.contains("\"iPhone 16\""))
        XCTAssertTrue(body.contains("\"iOS 26.4\""))
        XCTAssertTrue(body.contains("\"ok\""))
    }

    /// Without an injected simctl, warm-templates.json is silently
    /// skipped (so existing tests that don't care still work). This
    /// is the supported "minimal" wiring for callers that don't have
    /// a `SimctlClient` handy.
    func testCollectSkipsWarmTemplatesJSONWhenNoSimctl() throws {
        let workspace = Workspace(mainWorktreePath: "/Users/test/Repo")
        let service = BugReportService(
            workspace: workspace,
            git: FakeGitClient(),
            fs: InMemoryFileSystem(),
            runner: ScriptedRunner(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            homeDir: { "/Users/test" }
        )
        let entries = try service.collect()
        XCTAssertFalse(entries.contains { $0.path == "warm-templates.json" })
    }
}

// MARK: - test doubles

private final class ScriptedRunner: ProcessRunner, @unchecked Sendable {
    enum Outcome {
        case stdout(String)
        case throwing
    }
    var scripts: [String: Outcome]

    init(scripts: [String: Outcome] = [:]) {
        self.scripts = scripts
    }

    func run(
        _ executable: String,
        args: [String],
        cwd: String?,
        env: [String: String]?
    ) throws -> ProcessResult {
        switch scripts[executable] ?? .stdout("") {
        case .stdout(let s):
            return ProcessResult(exitCode: 0, stdout: s, stderr: "")
        case .throwing:
            throw VibeChardError.externalCommandFailed(
                cmd: executable,
                exitCode: 127,
                stderr: "scripted failure"
            )
        }
    }
}
