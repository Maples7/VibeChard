import XCTest
@testable import VibeChardCore

final class RunServiceTests: XCTestCase {

    private func makeWorkspace() -> Workspace {
        Workspace(mainWorktreePath: "/tmp/repo")
    }

    private func makeFakeSettings(_ json: String) -> FakeBuildSettingsLister {
        FakeBuildSettingsLister(stub: Data(json.utf8))
    }

    private let goodSettingsJSON = #"""
    [
      {
        "action": "build",
        "target": "App",
        "buildSettings": {
          "PRODUCT_BUNDLE_IDENTIFIER": "com.example.app",
          "FULL_PRODUCT_NAME": "App.app",
          "WRAPPER_NAME": "App.app",
          "TARGET_BUILD_DIR": "/products/Debug-iphonesimulator",
          "BUILT_PRODUCTS_DIR": "/products/Debug-iphonesimulator"
        }
      }
    ]
    """#

    // MARK: - resolveTarget

    func test_resolveTarget_returnsBundleIDAndAppPath_whenSettingsExist() throws {
        let workspace = makeWorkspace()
        let fs = InMemoryFileSystem()
        try fs.createDirectory(at: "/products/Debug-iphonesimulator/App.app")

        let svc = RunService(
            workspace: workspace,
            simctl: FakeSimctl(),
            settingsLister: makeFakeSettings(goodSettingsJSON),
            fs: fs
        )
        let task = try TaskName("alpha")
        let target = try svc.resolveTarget(
            task: task,
            scheme: "App",
            configuration: "Debug",
            simulatorUDID: "UDID-1"
        )
        XCTAssertEqual(target.bundleID, "com.example.app")
        XCTAssertEqual(
            target.appPath,
            "/products/Debug-iphonesimulator/App.app"
        )
    }

    func test_resolveTarget_passesDestinationAndDerivedDataToLister() throws {
        let workspace = makeWorkspace()
        let fs = InMemoryFileSystem()
        try fs.createDirectory(at: "/products/Debug-iphonesimulator/App.app")
        let lister = makeFakeSettings(goodSettingsJSON)
        let svc = RunService(
            workspace: workspace,
            simctl: FakeSimctl(),
            settingsLister: lister,
            fs: fs
        )
        let task = try TaskName("alpha")
        _ = try svc.resolveTarget(
            task: task,
            scheme: "App",
            configuration: "Debug",
            simulatorUDID: "UDID-1"
        )
        XCTAssertEqual(lister.lastCwd, workspace.worktreePath(for: task))
        XCTAssertEqual(lister.lastScheme, "App")
        XCTAssertEqual(lister.lastConfiguration, "Debug")
        XCTAssertEqual(
            lister.lastDestination,
            "platform=iOS Simulator,id=UDID-1"
        )
        XCTAssertEqual(
            lister.lastDerivedDataPath,
            workspace.derivedDataDir(for: task)
        )
    }

    func test_resolveTarget_throws_runBundleIDNotFound_whenSettingMissing() throws {
        let json = #"""
        [
          {
            "target": "App",
            "buildSettings": {
              "FULL_PRODUCT_NAME": "App.app",
              "WRAPPER_NAME": "App.app",
              "TARGET_BUILD_DIR": "/p"
            }
          }
        ]
        """#
        let svc = RunService(
            workspace: makeWorkspace(),
            simctl: FakeSimctl(),
            settingsLister: makeFakeSettings(json),
            fs: InMemoryFileSystem()
        )
        XCTAssertThrowsError(try svc.resolveTarget(
            task: try TaskName("alpha"),
            scheme: "App",
            configuration: nil,
            simulatorUDID: "UDID-1"
        )) { err in
            guard case VibeChardError.runBundleIDNotFound(let scheme) = err else {
                return XCTFail("expected runBundleIDNotFound, got \(err)")
            }
            XCTAssertEqual(scheme, "App")
        }
    }

    func test_resolveTarget_throws_runAppBundleNotFound_whenAppMissingOnDisk() throws {
        let svc = RunService(
            workspace: makeWorkspace(),
            simctl: FakeSimctl(),
            settingsLister: makeFakeSettings(goodSettingsJSON),
            fs: InMemoryFileSystem() // no /products/... dir
        )
        XCTAssertThrowsError(try svc.resolveTarget(
            task: try TaskName("alpha"),
            scheme: "App",
            configuration: "Debug",
            simulatorUDID: "UDID-1"
        )) { err in
            guard case VibeChardError.runAppBundleNotFound(let path) = err else {
                return XCTFail("expected runAppBundleNotFound, got \(err)")
            }
            XCTAssertEqual(path, "/products/Debug-iphonesimulator/App.app")
        }
    }

    func test_resolveTarget_throws_runAppBundleNotFound_whenTargetBuildDirMissing() throws {
        let json = #"""
        [
          {
            "target": "App",
            "buildSettings": {
              "PRODUCT_BUNDLE_IDENTIFIER": "com.example.app"
            }
          }
        ]
        """#
        let svc = RunService(
            workspace: makeWorkspace(),
            simctl: FakeSimctl(),
            settingsLister: makeFakeSettings(json),
            fs: InMemoryFileSystem()
        )
        XCTAssertThrowsError(try svc.resolveTarget(
            task: try TaskName("alpha"),
            scheme: "App",
            configuration: nil,
            simulatorUDID: "UDID-1"
        )) { err in
            guard case VibeChardError.runAppBundleNotFound = err else {
                return XCTFail("expected runAppBundleNotFound, got \(err)")
            }
        }
    }

    func test_resolveTarget_propagatesListerFailure() throws {
        let lister = FakeBuildSettingsLister(stub: Data())
        lister.throwError = .externalCommandFailed(
            cmd: "xcodebuild -showBuildSettings", exitCode: 65,
            stderr: "scheme not found"
        )
        let svc = RunService(
            workspace: makeWorkspace(),
            simctl: FakeSimctl(),
            settingsLister: lister,
            fs: InMemoryFileSystem()
        )
        XCTAssertThrowsError(try svc.resolveTarget(
            task: try TaskName("alpha"),
            scheme: "Nope",
            configuration: nil,
            simulatorUDID: "UDID-1"
        )) { err in
            guard case VibeChardError.externalCommandFailed(_, let code, _) = err else {
                return XCTFail("expected externalCommandFailed, got \(err)")
            }
            XCTAssertEqual(code, 65)
        }
    }

    // MARK: - installAndLaunch

    func test_installAndLaunch_callsSimctlWithBundleAndArgs() throws {
        let simctl = FakeSimctl()
        let svc = RunService(
            workspace: makeWorkspace(),
            simctl: simctl,
            settingsLister: makeFakeSettings(goodSettingsJSON),
            fs: InMemoryFileSystem()
        )
        try svc.installAndLaunch(
            target: .init(
                bundleID: "com.example.app",
                appPath: "/p/App.app"
            ),
            simulatorUDID: "UDID-9",
            launchArgs: ["-UsePreviewSampleData"]
        )
        XCTAssertEqual(simctl.installCalls.count, 1)
        XCTAssertEqual(simctl.installCalls.first?.udid, "UDID-9")
        XCTAssertEqual(simctl.installCalls.first?.appPath, "/p/App.app")
        XCTAssertEqual(simctl.launchCalls.count, 1)
        XCTAssertEqual(simctl.launchCalls.first?.udid, "UDID-9")
        XCTAssertEqual(simctl.launchCalls.first?.bundleID, "com.example.app")
        XCTAssertEqual(
            simctl.launchCalls.first?.args,
            ["-UsePreviewSampleData"]
        )
    }

    func test_installAndLaunch_skipsLaunchIfInstallFails() throws {
        let simctl = FakeSimctl()
        simctl.installThrows = .externalCommandFailed(
            cmd: "simctl install", exitCode: 1, stderr: "boom"
        )
        let svc = RunService(
            workspace: makeWorkspace(),
            simctl: simctl,
            settingsLister: makeFakeSettings(goodSettingsJSON),
            fs: InMemoryFileSystem()
        )
        XCTAssertThrowsError(try svc.installAndLaunch(
            target: .init(bundleID: "x", appPath: "/y"),
            simulatorUDID: "U",
            launchArgs: []
        ))
        XCTAssertEqual(simctl.launchCalls.count, 0)
    }

    // MARK: - adopted worktrees at arbitrary paths (#98 follow-up)

    /// `vch run` against an adopted task must look up build settings
    /// using the adopted worktree as cwd and the adopted DerivedData
    /// dir as the `-derivedDataPath` argument. If RunService still
    /// resolved either from `<repo>-<task>`, xcodebuild would either
    /// fail with "scheme not found" or pick up a stale .app from the
    /// wrong DerivedData. Both failures would be silent at the
    /// CLI surface, hence this regression guard.
    func test_resolveTarget_usesAdoptedWorktreeForCwdAndDerivedData() throws {
        let adoptedPath = "/Users/me/codex-session"
        let task = try TaskName("alpha")
        let workspace = Workspace(mainWorktreePath: "/tmp/repo")
            .withWorktreePath(adoptedPath, for: task)
        let fs = InMemoryFileSystem()
        try fs.createDirectory(at: "/products/Debug-iphonesimulator/App.app")
        let lister = makeFakeSettings(goodSettingsJSON)
        let svc = RunService(
            workspace: workspace,
            simctl: FakeSimctl(),
            settingsLister: lister,
            fs: fs
        )

        _ = try svc.resolveTarget(
            task: task,
            scheme: "App",
            configuration: "Debug",
            simulatorUDID: "UDID-1"
        )
        XCTAssertEqual(lister.lastCwd, adoptedPath)
        XCTAssertEqual(
            lister.lastDerivedDataPath,
            "\(adoptedPath)/.agent-build/DerivedData",
            "derivedDataPath must be inside the adopted worktree, not <repo>-<task>"
        )
    }
}

// MARK: - test doubles

final class FakeBuildSettingsLister: BuildSettingsLister, @unchecked Sendable {
    var stub: Data
    var throwError: VibeChardError?

    var lastCwd: String?
    var lastScheme: String?
    var lastConfiguration: String?
    var lastDestination: String?
    var lastDerivedDataPath: String?

    init(stub: Data) { self.stub = stub }

    func showBuildSettings(
        cwd: String,
        scheme: String,
        configuration: String?,
        destination: String?,
        derivedDataPath: String?
    ) throws -> Data {
        lastCwd = cwd
        lastScheme = scheme
        lastConfiguration = configuration
        lastDestination = destination
        lastDerivedDataPath = derivedDataPath
        if let err = throwError { throw err }
        return stub
    }
}
