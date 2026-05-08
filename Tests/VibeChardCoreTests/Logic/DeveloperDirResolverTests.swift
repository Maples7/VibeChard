import XCTest
@testable import VibeChardCore

final class DeveloperDirResolverTests: XCTestCase {

    func testInjectionAddsResolvedValueWhenAbsent() {
        var env: [String: String] = [:]
        DeveloperDirInjection.apply(
            to: &env,
            resolver: ConstantResolver("/Applications/Xcode.app/Contents/Developer")
        )
        XCTAssertEqual(env["DEVELOPER_DIR"],
                       "/Applications/Xcode.app/Contents/Developer")
    }

    func testInjectionPreservesUserOverride() {
        var env: [String: String] = ["DEVELOPER_DIR": "/Custom/Xcode.app/Contents/Developer"]
        DeveloperDirInjection.apply(
            to: &env,
            resolver: ConstantResolver("/Applications/Xcode.app/Contents/Developer")
        )
        XCTAssertEqual(env["DEVELOPER_DIR"],
                       "/Custom/Xcode.app/Contents/Developer")
    }

    func testInjectionLeavesEnvAloneWhenResolverIsNil() {
        var env: [String: String] = ["FOO": "bar"]
        DeveloperDirInjection.apply(to: &env, resolver: nil)
        XCTAssertNil(env["DEVELOPER_DIR"])
        XCTAssertEqual(env["FOO"], "bar")
    }

    func testInjectionLeavesEnvAloneWhenResolverReturnsNil() {
        var env: [String: String] = [:]
        DeveloperDirInjection.apply(to: &env, resolver: ConstantResolver(nil))
        XCTAssertNil(env["DEVELOPER_DIR"])
    }

    func testInjectionIgnoresEmptyResolverOutput() {
        var env: [String: String] = [:]
        DeveloperDirInjection.apply(to: &env, resolver: ConstantResolver(""))
        XCTAssertNil(env["DEVELOPER_DIR"])
    }

    func testXcodeSelectResolverShellsOutAndCachesResult() {
        let runner = RecordingRunner(
            stub: ProcessResult(
                exitCode: 0,
                stdout: "/Applications/Xcode.app/Contents/Developer\n",
                stderr: ""
            )
        )
        let resolver = XcodeSelectDeveloperDirResolver(runner: runner)

        XCTAssertEqual(resolver.resolve(),
                       "/Applications/Xcode.app/Contents/Developer")
        XCTAssertEqual(resolver.resolve(),
                       "/Applications/Xcode.app/Contents/Developer")
        // Cached: only one shell-out per resolver lifetime.
        XCTAssertEqual(runner.callCount, 1)
        XCTAssertEqual(runner.lastInvocation?.executable, "/usr/bin/xcode-select")
        XCTAssertEqual(runner.lastInvocation?.args, ["-p"])
    }

    func testXcodeSelectResolverReturnsNilWhenCommandFails() {
        let runner = RecordingRunner(
            stub: ProcessResult(exitCode: 2, stdout: "", stderr: "xcode-select: error: …")
        )
        let resolver = XcodeSelectDeveloperDirResolver(runner: runner)
        XCTAssertNil(resolver.resolve())
    }

    func testXcodeSelectResolverTreatsEmptyStdoutAsNil() {
        let runner = RecordingRunner(
            stub: ProcessResult(exitCode: 0, stdout: "   \n", stderr: "")
        )
        let resolver = XcodeSelectDeveloperDirResolver(runner: runner)
        XCTAssertNil(resolver.resolve())
    }
}

// MARK: - test doubles

private struct ConstantResolver: DeveloperDirResolver {
    let value: String?
    init(_ value: String?) { self.value = value }
    func resolve() -> String? { value }
}

private final class RecordingRunner: ProcessRunner, @unchecked Sendable {
    struct Invocation {
        let executable: String
        let args: [String]
    }

    private let stub: ProcessResult
    private let lock = NSLock()
    private(set) var callCount = 0
    private(set) var lastInvocation: Invocation?

    init(stub: ProcessResult) { self.stub = stub }

    func run(
        _ executable: String,
        args: [String],
        cwd: String?,
        env: [String: String]?
    ) throws -> ProcessResult {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        lastInvocation = Invocation(executable: executable, args: args)
        return stub
    }
}
