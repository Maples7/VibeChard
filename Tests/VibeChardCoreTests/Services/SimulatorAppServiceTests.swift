import XCTest
@testable import VibeChardCore

final class SimulatorAppServiceTests: XCTestCase {
    func testOpensDeviceHubFromSelectedXcodeInsteadOfDisplayName() {
        let fs = InMemoryFileSystem()
        let appPath = "/Applications/Xcode.app/Contents/Applications/DeviceHub.app"
        fs.seedDirectory(appPath)
        let runner = SimulatorAppRunner()
        let service = SimulatorAppService(
            fs: fs,
            runner: runner,
            developerDir: SimulatorAppDeveloperDir(
                "/Applications/Xcode.app/Contents/Developer"
            )
        )

        XCTAssertEqual(service.open(baseEnv: [:]), .opened(appPath: appPath))
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(runner.invocations.first?.executable, "/usr/bin/open")
        XCTAssertEqual(runner.invocations.first?.args, ["-g", "-a", appPath])
        XCTAssertNil(service.open(baseEnv: [:]).note)
    }

    func testOpensLegacySimulatorAndPrefersItWhenBothAppsExist() {
        let fs = InMemoryFileSystem()
        let appPath = "/Applications/Xcode.app/Contents/Applications/Simulator.app"
        fs.seedDirectory(appPath)
        let runner = SimulatorAppRunner()
        let service = SimulatorAppService(
            fs: fs, runner: runner,
            developerDir: SimulatorAppDeveloperDir("/Applications/Xcode.app/Contents/Developer")
        )

        XCTAssertEqual(service.open(baseEnv: [:]), .opened(appPath: appPath))
        fs.seedDirectory("/Applications/Xcode.app/Contents/Applications/DeviceHub.app")
        XCTAssertEqual(service.open(baseEnv: [:]), .opened(appPath: appPath))
        XCTAssertEqual(runner.invocations.last?.args, ["-g", "-a", appPath])
    }

    func testExplicitDeveloperDirSelectsMatchingXcodeWithSpaces() {
        let fs = InMemoryFileSystem()
        let selected = "/Applications/Xcode.app/Contents/Developer"
        let override = "/Volumes/Developer Tools/Xcode Beta.app/Contents/Developer"
        let appPath = "/Volumes/Developer Tools/Xcode Beta.app/Contents/Applications/DeviceHub.app"
        fs.seedDirectory("/Applications/Xcode.app/Contents/Applications/Simulator.app")
        fs.seedDirectory(appPath)
        let runner = SimulatorAppRunner()
        let service = SimulatorAppService(
            fs: fs, runner: runner,
            developerDir: SimulatorAppDeveloperDir(selected)
        )
        let env = ["DEVELOPER_DIR": override, "PATH": "/usr/bin:/bin"]

        XCTAssertEqual(service.open(baseEnv: env), .opened(appPath: appPath))
        XCTAssertEqual(runner.invocations.first?.args, ["-g", "-a", appPath])
        XCTAssertEqual(runner.invocations.first?.env, env)
    }

    func testAcceptsXcodeAppRootOverrideAndTrailingSlash() {
        let fs = InMemoryFileSystem()
        let appPath = "/Custom/Xcode Beta.app/Contents/Applications/DeviceHub.app"
        fs.seedDirectory(appPath)
        let service = SimulatorAppService(
            fs: fs, runner: SimulatorAppRunner(),
            developerDir: SimulatorAppDeveloperDir(nil)
        )

        for override in ["/Custom/Xcode Beta.app/", "/Custom/Xcode Beta.app/Contents/Developer/"] {
            XCTAssertEqual(
                service.open(baseEnv: ["DEVELOPER_DIR": override]),
                .opened(appPath: appPath)
            )
        }
    }

    func testExplicitMissingOrEmptyDeveloperDirNeverFallsBackToOtherXcode() {
        let fs = InMemoryFileSystem()
        fs.seedDirectory("/Applications/Xcode.app/Contents/Applications/Simulator.app")
        let runner = SimulatorAppRunner()
        let service = SimulatorAppService(
            fs: fs, runner: runner,
            developerDir: SimulatorAppDeveloperDir("/Applications/Xcode.app/Contents/Developer")
        )

        for override in ["/Missing/Xcode.app/Contents/Developer", ""] {
            XCTAssertEqual(service.open(baseEnv: ["DEVELOPER_DIR": override]), .unavailable)
        }
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testUnavailableToolchainOrUIIsNonFatalAndDoesNotInvokeOpen() {
        let fs = InMemoryFileSystem()
        // A simulator UI from another Xcode must not be used.
        fs.seedDirectory("/Applications/Other Xcode.app/Contents/Applications/Simulator.app")
        for dir: String? in [nil, "", "/Library/Developer/CommandLineTools",
                            "/Applications/Xcode.app/Contents/Developer"] {
            let runner = SimulatorAppRunner()
            let service = SimulatorAppService(
                fs: fs, runner: runner,
                developerDir: SimulatorAppDeveloperDir(dir)
            )
            let outcome = service.open(baseEnv: [:])

            XCTAssertEqual(outcome, .unavailable)
            XCTAssertNotNil(outcome.note)
            XCTAssertTrue(runner.invocations.isEmpty)
        }
    }

    func testNonzeroOpenStatusCapturesErrorAndAllowsInstallAndLaunch() throws {
        let fs = InMemoryFileSystem()
        let appPath = "/Applications/Xcode.app/Contents/Applications/DeviceHub.app"
        fs.seedDirectory(appPath)
        let runner = SimulatorAppRunner()
        runner.result = ProcessResult(exitCode: 1, stdout: "", stderr: "No window server\n")
        let service = SimulatorAppService(
            fs: fs, runner: runner,
            developerDir: SimulatorAppDeveloperDir("/Applications/Xcode.app/Contents/Developer")
        )
        let outcome = service.open(baseEnv: [:])

        XCTAssertEqual(outcome, .failed(
            appPath: appPath, reason: "open exited with status 1: No window server\n"
        ))
        XCTAssertNotNil(outcome.note)
        XCTAssertFalse(outcome.note?.contains("No window server") ?? true)

        let simctl = FakeSimctl()
        let runService = RunService(
            workspace: Workspace(mainWorktreePath: "/repo"),
            simctl: simctl,
            settingsLister: FakeBuildSettingsLister(stub: Data()),
            fs: fs
        )
        try runService.installAndLaunch(
            target: .init(bundleID: "com.example.app", appPath: "/products/App.app"),
            simulatorUDID: "UDID-1", launchArgs: ["-UITestMode"]
        )
        XCTAssertEqual(simctl.installCalls.first?.appPath, "/products/App.app")
        XCTAssertEqual(simctl.launchCalls.first?.bundleID, "com.example.app")
        XCTAssertEqual(simctl.launchCalls.first?.args, ["-UITestMode"])
    }

    func testSpawnFailureIsNonFatal() {
        let fs = InMemoryFileSystem()
        let appPath = "/Applications/Xcode.app/Contents/Applications/Simulator.app"
        fs.seedDirectory(appPath)
        let runner = SimulatorAppRunner()
        runner.error = VibeChardError.externalCommandFailed(
            cmd: "open", exitCode: -1, stderr: "failed to spawn"
        )
        let service = SimulatorAppService(
            fs: fs, runner: runner,
            developerDir: SimulatorAppDeveloperDir("/Applications/Xcode.app/Contents/Developer")
        )

        guard case .failed(let path, let reason) = service.open(baseEnv: [:]) else {
            return XCTFail("expected a non-fatal UI failure")
        }
        XCTAssertEqual(path, appPath)
        XCTAssertTrue(reason.contains("failed to spawn"))
    }
}

private struct SimulatorAppDeveloperDir: DeveloperDirResolver {
    let value: String?
    init(_ value: String?) { self.value = value }
    func resolve() -> String? { value }
}

private final class SimulatorAppRunner: ProcessRunner, @unchecked Sendable {
    struct Invocation {
        let executable: String
        let args: [String]
        let env: [String: String]?
    }

    var invocations: [Invocation] = []
    var result = ProcessResult(exitCode: 0, stdout: "", stderr: "")
    var error: Error?

    func run(
        _ executable: String,
        args: [String],
        cwd: String?,
        env: [String: String]?
    ) throws -> ProcessResult {
        invocations.append(Invocation(executable: executable, args: args, env: env))
        if let error { throw error }
        return result
    }
}
