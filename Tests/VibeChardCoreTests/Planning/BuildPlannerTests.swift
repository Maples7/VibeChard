import XCTest
@testable import VibeChardCore

final class BuildPlannerTests: XCTestCase {

    private func baseInputs(
        action: String = "build",
        scheme: String? = "App",
        configuration: String? = nil,
        resultBundle: String? = nil,
        udid: String? = nil,
        device: String? = nil,
        extra: [String] = []
    ) -> BuildPlanner.Inputs {
        BuildPlanner.Inputs(
            action: action,
            scheme: scheme,
            configuration: configuration,
            derivedDataPath: "/wt/.agent-build/DerivedData",
            clonedSourcePackagesDir: "/wt/.agent-build/SwiftPM",
            resultBundlePath: resultBundle,
            destinationUDID: udid,
            destinationDevice: device,
            extraArgs: extra
        )
    }

    func testMinimalBuildInjectsSchemeAndIsolationFlagsInExpectedOrder() {
        let argv = BuildPlanner.args(baseInputs())
        XCTAssertEqual(argv, [
            "-scheme", "App",
            "-derivedDataPath", "/wt/.agent-build/DerivedData",
            "-clonedSourcePackagesDirPath", "/wt/.agent-build/SwiftPM",
            "build",
        ])
    }

    func testTestActionIncludesResultBundle() {
        let argv = BuildPlanner.args(baseInputs(
            action: "test",
            resultBundle: "/wt/.agent-build/Result.xcresult"
        ))
        XCTAssertTrue(argv.contains("-resultBundlePath"),
                      "test action must request a result bundle")
        let i = argv.firstIndex(of: "-resultBundlePath")!
        XCTAssertEqual(argv[i + 1], "/wt/.agent-build/Result.xcresult")
        XCTAssertEqual(argv.last, "test")
    }

    func testBuildOmitsResultBundle() {
        let argv = BuildPlanner.args(baseInputs(action: "build"))
        XCTAssertFalse(argv.contains("-resultBundlePath"),
                       "build action must not pass -resultBundlePath")
    }

    func testDeviceFlagBecomesNameDestination() {
        let argv = BuildPlanner.args(baseInputs(device: "iPhone 16"))
        XCTAssertTrue(argv.contains("-destination"))
        let i = argv.firstIndex(of: "-destination")!
        XCTAssertEqual(argv[i + 1], "platform=iOS Simulator,arch=\(BuildPlanner.hostArch),name=iPhone 16")
    }

    func testConfigurationIsPassedThroughBeforeIsolationFlags() {
        let argv = BuildPlanner.args(baseInputs(configuration: "Release"))
        XCTAssertTrue(argv.contains("Release"))
        let cfgIdx = argv.firstIndex(of: "-configuration")!
        let dataIdx = argv.firstIndex(of: "-derivedDataPath")!
        XCTAssertLessThan(cfgIdx, dataIdx,
                          "-configuration must come before vch's injected flags")
    }

    func testExtraArgsAppearBeforeAction() {
        let argv = BuildPlanner.args(baseInputs(extra: ["-quiet", "-skipMacroValidation"]))
        XCTAssertEqual(argv.last, "build")
        let quietIdx = argv.firstIndex(of: "-quiet")!
        let buildIdx = argv.firstIndex(of: "build")!
        XCTAssertLessThan(quietIdx, buildIdx,
                          "user extras must precede the action verb")
    }

    func testNilSchemeEmitsNoSchemeFlag() {
        let argv = BuildPlanner.args(baseInputs(scheme: nil))
        XCTAssertFalse(argv.contains("-scheme"),
                       "absent scheme must produce no -scheme flag")
    }

    func testUDIDDestinationTakesPrecedenceOverDeviceName() {
        let argv = BuildPlanner.args(baseInputs(
            udid: "ABCDEF-1234",
            device: "iPhone 16"
        ))
        let i = argv.firstIndex(of: "-destination")!
        XCTAssertEqual(argv[i + 1], "platform=iOS Simulator,arch=\(BuildPlanner.hostArch),id=ABCDEF-1234")
        // The name= form must not also be emitted — xcodebuild would
        // accept the last but it'd be confusing in test logs.
        XCTAssertFalse(argv.contains { $0.contains("name=iPhone 16") })
    }

    // #5: pin arch alongside the UDID so xcodebuild stops emitting the
    // "Using the first of multiple matching destinations" warning when
    // both arm64 and x86_64 entries exist for the cloned simulator.
    func testUDIDDestinationPinsHostArch() {
        let argv = BuildPlanner.args(baseInputs(udid: "ABCDEF-1234"))
        let i = argv.firstIndex(of: "-destination")!
        XCTAssertTrue(argv[i + 1].contains("arch=\(BuildPlanner.hostArch),"),
                      "destination string must pin host arch (#5); got \(argv[i + 1])")
    }

    func testNoDestinationFlagWhenNeitherUDIDNorDeviceProvided() {
        let argv = BuildPlanner.args(baseInputs())
        XCTAssertFalse(argv.contains("-destination"))
    }
}
