// ShimIntegrationTests
//
// End-to-end checks for `vch-xcodebuild-shim`. The shim binary is
// declared as a dependency in `Package.swift`, so SwiftPM builds it
// alongside this test bundle. We exec it under a controlled
// environment with `VCH_SHIM_REAL_XCODEBUILD` pointing at a synthetic
// xcodebuild script that just dumps its argv. This validates the full
// pipeline:
//   • argv0-based tool dispatch (xcodebuild vs xcrun vs swift)
//   • env-var driven flag injection
//   • "user already passed it" skip behavior
//   • mkdir -p of the isolation directories
//   • re-entrancy guard (VCH_SHIM_INJECTED)
//
// We can't @testable-import an executable target, and AGENTS.md hard
// rule #6 forbids extracting a library. End-to-end via `Process` is
// the cleanest path that respects those constraints.

import Foundation
import XCTest

final class ShimIntegrationTests: XCTestCase {

    // MARK: - Locate the pre-built shim binary

    /// SwiftPM places `vch-xcodebuild-shim` next to the test bundle
    /// (`<bin>/<package>PackageTests.xctest`), since the test target
    /// declares it as a dependency. We resolve via the test bundle's
    /// own URL so we don't have to shell out to `swift build`.
    private static func shimPath() throws -> String {
        let testBundleURL = Bundle(for: ShimIntegrationTests.self).bundleURL
        let binDir = testBundleURL.deletingLastPathComponent()
        let candidate = binDir.appendingPathComponent("vch-xcodebuild-shim")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw NSError(domain: "ShimIntegrationTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "vch-xcodebuild-shim not found next to test bundle at \(candidate.path) — Package.swift dependency missing?"
            ])
        }
        return candidate.path
    }

    // MARK: - Test fixture

    private var tmp: URL!
    private var shim: String!
    private var argvFile: URL!
    private var fakeReal: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        shim = try Self.shimPath()
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vch-shim-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        argvFile = tmp.appendingPathComponent("argv.txt")
        fakeReal = tmp.appendingPathComponent("fake-xcodebuild.sh")
        // The fake "real xcodebuild" simply dumps each arg on its own
        // line. The shim execv's into this with full argv.
        let script = """
        #!/bin/bash
        printf '%s\\n' "$@" > '\(argvFile.path)'
        exit 0
        """
        try script.write(to: fakeReal, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: fakeReal.path
        )
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Make `<tmp>/<name>` a symlink to the shim, and return its path.
    private func makeShimSymlink(named name: String) throws -> String {
        let link = tmp.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: URL(fileURLWithPath: shim)
        )
        return link.path
    }

    /// Run the shim under `argv0` with `userArgs` and `env`. Returns the
    /// argv that the fake xcodebuild observed (one entry per line).
    private func runShim(
        argv0: String,
        userArgs: [String],
        extraEnv: [String: String] = [:]
    ) throws -> (exitCode: Int32, capturedArgv: [String], stderr: String) {
        var env = ProcessInfo.processInfo.environment
        // Reset the re-entrancy marker — it might leak in if the test
        // runner already ran us under a vch shell.
        env.removeValue(forKey: "VCH_SHIM_INJECTED")
        // Default: point real-xcodebuild override at our fake. Tests
        // can override.
        env["VCH_SHIM_REAL_XCODEBUILD"] = fakeReal.path
        env["VCH_SHIM_REAL_XCRUN"] = fakeReal.path
        env["VCH_SHIM_REAL_SWIFT"] = fakeReal.path
        for (k, v) in extraEnv { env[k] = v }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: argv0)
        proc.arguments = userArgs
        proc.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()

        let stderrText = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let captured: [String]
        if FileManager.default.fileExists(atPath: argvFile.path) {
            captured = try String(contentsOf: argvFile, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .dropLast()  // trailing empty after final newline
                .map(String.init)
        } else {
            captured = []
        }
        return (proc.terminationStatus, captured, stderrText)
    }

    // MARK: - Tests

    func test_xcodebuild_injects_all_three_flags_when_env_set() throws {
        let xc = try makeShimSymlink(named: "xcodebuild")
        let derived = tmp.appendingPathComponent("DerivedData").path
        let spm = tmp.appendingPathComponent("SourcePackages").path
        let resultBundle = tmp.appendingPathComponent("R.xcresult").path

        let res = try runShim(
            argv0: xc,
            userArgs: ["-version"],
            extraEnv: [
                "VCH_DERIVED_DATA_PATH": derived,
                "VCH_SPM_CLONE_DIR": spm,
                "VCH_RESULT_BUNDLE_PATH": resultBundle,
            ]
        )
        XCTAssertEqual(res.exitCode, 0, "stderr: \(res.stderr)")
        XCTAssertEqual(res.capturedArgv, [
            "-derivedDataPath", derived,
            "-clonedSourcePackagesDirPath", spm,
            "-resultBundlePath", resultBundle,
            "-version",
        ])

        // The shim should mkdir -p the dirs (parent for resultBundle).
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: derived, isDirectory: &isDir) && isDir.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: spm, isDirectory: &isDir) && isDir.boolValue)
        // Result bundle path itself must NOT exist (xcodebuild creates it).
        XCTAssertFalse(FileManager.default.fileExists(atPath: resultBundle))
        // Parent should exist.
        let parent = (resultBundle as NSString).deletingLastPathComponent
        XCTAssertTrue(FileManager.default.fileExists(atPath: parent, isDirectory: &isDir) && isDir.boolValue)
    }

    func test_xcodebuild_only_injects_what_env_provides() throws {
        let xc = try makeShimSymlink(named: "xcodebuild")
        let derived = tmp.appendingPathComponent("DerivedData").path

        let res = try runShim(
            argv0: xc,
            userArgs: ["clean", "-scheme", "App"],
            extraEnv: ["VCH_DERIVED_DATA_PATH": derived]
        )
        XCTAssertEqual(res.exitCode, 0, "stderr: \(res.stderr)")
        XCTAssertEqual(res.capturedArgv, [
            "-derivedDataPath", derived,
            "clean", "-scheme", "App",
        ])
    }

    func test_xcodebuild_skips_flags_user_already_passed() throws {
        let xc = try makeShimSymlink(named: "xcodebuild")
        let envDerived = tmp.appendingPathComponent("env-derived").path
        let userDerived = tmp.appendingPathComponent("user-derived").path
        let envSpm = tmp.appendingPathComponent("env-spm").path

        let res = try runShim(
            argv0: xc,
            userArgs: ["-derivedDataPath", userDerived, "build"],
            extraEnv: [
                "VCH_DERIVED_DATA_PATH": envDerived,
                "VCH_SPM_CLONE_DIR": envSpm,
            ]
        )
        XCTAssertEqual(res.exitCode, 0, "stderr: \(res.stderr)")
        // Derived was user-supplied → skipped. SPM still injected.
        XCTAssertEqual(res.capturedArgv, [
            "-clonedSourcePackagesDirPath", envSpm,
            "-derivedDataPath", userDerived,
            "build",
        ])
        // Skipped flag's env directory should NOT have been created
        // (we don't touch dirs we didn't inject).
        XCTAssertFalse(FileManager.default.fileExists(atPath: envDerived),
                       "shim must not mkdir paths it didn't inject")
    }

    func test_xcrun_does_not_inject_anything() throws {
        let xcrun = try makeShimSymlink(named: "xcrun")
        let derived = tmp.appendingPathComponent("DerivedData").path

        let res = try runShim(
            argv0: xcrun,
            userArgs: ["-f", "swift"],
            extraEnv: ["VCH_DERIVED_DATA_PATH": derived]
        )
        XCTAssertEqual(res.exitCode, 0, "stderr: \(res.stderr)")
        XCTAssertEqual(res.capturedArgv, ["-f", "swift"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: derived))
    }

    func test_swift_does_not_inject_xcodebuild_flags() throws {
        let swift = try makeShimSymlink(named: "swift")
        let derived = tmp.appendingPathComponent("DerivedData").path

        let res = try runShim(
            argv0: swift,
            userArgs: ["build"],
            extraEnv: ["VCH_DERIVED_DATA_PATH": derived]
        )
        XCTAssertEqual(res.exitCode, 0, "stderr: \(res.stderr)")
        XCTAssertEqual(res.capturedArgv, ["build"])
    }

    func test_already_injected_marker_blocks_double_injection() throws {
        let xc = try makeShimSymlink(named: "xcodebuild")
        let derived = tmp.appendingPathComponent("DerivedData").path

        let res = try runShim(
            argv0: xc,
            userArgs: ["-version"],
            extraEnv: [
                "VCH_DERIVED_DATA_PATH": derived,
                "VCH_SHIM_INJECTED": "1",
            ]
        )
        XCTAssertEqual(res.exitCode, 0, "stderr: \(res.stderr)")
        XCTAssertEqual(res.capturedArgv, ["-version"])
    }

    func test_debug_env_emits_summary_to_stderr() throws {
        let xc = try makeShimSymlink(named: "xcodebuild")
        let derived = tmp.appendingPathComponent("DerivedData").path

        let res = try runShim(
            argv0: xc,
            userArgs: ["-version"],
            extraEnv: [
                "VCH_DERIVED_DATA_PATH": derived,
                "VCH_SHIM_DEBUG": "1",
            ]
        )
        XCTAssertEqual(res.exitCode, 0, "stderr: \(res.stderr)")
        XCTAssertTrue(res.stderr.contains("vch-shim[xcodebuild]"),
                      "expected debug header, got: \(res.stderr)")
        XCTAssertTrue(res.stderr.contains("-derivedDataPath \(derived)"),
                      "expected injected flag in debug line, got: \(res.stderr)")
    }
}
