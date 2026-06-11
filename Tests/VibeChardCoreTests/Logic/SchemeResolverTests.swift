import XCTest
@testable import VibeChardCore

final class SchemeResolverTests: XCTestCase {

    private let mainRepo = "/repos/Demo"

    private func setup(taskName: String,
                       state: TaskState? = nil,
                       lister: XcodebuildLister? = nil)
    -> (SchemeResolver, TaskName, InMemoryFileSystem) {
        let fs = InMemoryFileSystem()
        let workspace = Workspace(mainWorktreePath: mainRepo)
        let task = try! TaskName(taskName)
        fs.seedDirectory(mainRepo)
        fs.seedDirectory(workspace.worktreePath(for: task))
        fs.seedDirectory(workspace.vchDir(for: task))
        if let state {
            fs.seedFile(workspace.statePath(for: task), data: try! state.jsonData())
        }
        let resolver = SchemeResolver(workspace: workspace, lister: lister, fs: fs)
        return (resolver, task, fs)
    }

    private func emptyState(_ name: String, scheme: String? = nil) -> TaskState {
        TaskState(name: name, branch: "agent/\(name)",
                  createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                  baseRef: "deadbee", scheme: scheme)
    }

    // MARK: - parser

    func testParseProjectShape() {
        let json = #"""
        { "project": { "name": "Foo", "schemes": ["FooApp", "FooTests"] } }
        """#
        XCTAssertEqual(SchemePickerJSON.parseSchemes(Data(json.utf8)),
                       ["FooApp", "FooTests"])
    }

    func testParseWorkspaceShape() {
        let json = #"""
        { "workspace": { "name": "Foo", "schemes": ["OnlyOne"] } }
        """#
        XCTAssertEqual(SchemePickerJSON.parseSchemes(Data(json.utf8)),
                       ["OnlyOne"])
    }

    func testParseUnrecognizedReturnsEmpty() {
        XCTAssertEqual(SchemePickerJSON.parseSchemes(Data("not json".utf8)), [])
        XCTAssertEqual(SchemePickerJSON.parseSchemes(Data("{}".utf8)), [])
    }

    // MARK: - resolver tiering

    func testExplicitSchemeWinsOverEverything() throws {
        let (resolver, task, _) = setup(
            taskName: "alpha",
            state: emptyState("alpha", scheme: "Persisted"),
            lister: FakeLister(schemes: ["Auto"])
        )
        let r = try resolver.resolve(task: task, explicit: "CLI")
        XCTAssertEqual(r, .init(scheme: "CLI", source: .explicit))
    }

    func testFallsBackToPersistedScheme() throws {
        let (resolver, task, _) = setup(
            taskName: "alpha",
            state: emptyState("alpha", scheme: "Persisted"),
            lister: FakeLister(schemes: ["Auto"])
        )
        let r = try resolver.resolve(task: task, explicit: nil)
        XCTAssertEqual(r, .init(scheme: "Persisted", source: .persisted))
    }

    func testAutoDetectsSingleSharedScheme() throws {
        let (resolver, task, _) = setup(
            taskName: "alpha",
            state: emptyState("alpha"),                    // no persisted
            lister: FakeLister(schemes: ["OnlyOne"])
        )
        let r = try resolver.resolve(task: task, explicit: nil)
        XCTAssertEqual(r, .init(scheme: "OnlyOne", source: .autoDetected))
    }

    func testAutoDetectionPassesProjectContextToLister() throws {
        let lister = FakeLister(schemes: ["OnlyOne"])
        let (resolver, task, _) = setup(
            taskName: "alpha",
            state: emptyState("alpha"),
            lister: lister
        )

        let r = try resolver.resolve(
            task: task,
            explicit: nil,
            xcodebuildContainer: .project("Apps/App/App.xcodeproj")
        )

        XCTAssertEqual(r, .init(scheme: "OnlyOne", source: .autoDetected))
        XCTAssertEqual(lister.lastXcodebuildContainer, .project("Apps/App/App.xcodeproj"))
    }

    func testReturnsNilWhenAmbiguous() throws {
        let (resolver, task, _) = setup(
            taskName: "alpha",
            state: emptyState("alpha"),
            lister: FakeLister(schemes: ["A", "B"])
        )
        XCTAssertNil(try resolver.resolve(task: task, explicit: nil))
    }

    func testReturnsNilWhenNoSchemes() throws {
        let (resolver, task, _) = setup(
            taskName: "alpha",
            state: emptyState("alpha"),
            lister: FakeLister(schemes: [])
        )
        XCTAssertNil(try resolver.resolve(task: task, explicit: nil))
    }

    func testListerErrorIsBestEffort() throws {
        let (resolver, task, _) = setup(
            taskName: "alpha",
            state: emptyState("alpha"),
            lister: FakeLister(throwOnList: true)
        )
        XCTAssertNil(try resolver.resolve(task: task, explicit: nil),
                     "should swallow lister failure, not propagate")
    }

    func testNoListerSkipsAutoDetection() throws {
        let (resolver, task, _) = setup(
            taskName: "alpha",
            state: emptyState("alpha"),
            lister: nil
        )
        XCTAssertNil(try resolver.resolve(task: task, explicit: nil))
    }

    func testEmptyExplicitFallsThroughToPersisted() throws {
        let (resolver, task, _) = setup(
            taskName: "alpha",
            state: emptyState("alpha", scheme: "Persisted"),
            lister: nil
        )
        let r = try resolver.resolve(task: task, explicit: "")
        XCTAssertEqual(r, .init(scheme: "Persisted", source: .persisted))
    }

    // MARK: - diagnostics (#169)

    func testDiagnosticsReportAvailableSchemesWhenAmbiguous() throws {
        let (resolver, task, _) = setup(
            taskName: "alpha",
            state: emptyState("alpha"),
            lister: FakeLister(schemes: ["A", "B", "C"])
        )
        let outcome = try resolver.resolveWithDiagnostics(task: task, explicit: nil)
        XCTAssertNil(outcome.resolved)
        XCTAssertEqual(outcome.availableSchemes, ["A", "B", "C"])
    }

    func testDiagnosticsOmitSchemesWhenPersistedWins() throws {
        let (resolver, task, _) = setup(
            taskName: "alpha",
            state: emptyState("alpha", scheme: "Persisted"),
            lister: FakeLister(schemes: ["A", "B"])
        )
        let outcome = try resolver.resolveWithDiagnostics(task: task, explicit: nil)
        XCTAssertEqual(outcome.resolved, .init(scheme: "Persisted", source: .persisted))
        // Tier 3 never reached, so the lister is never consulted.
        XCTAssertEqual(outcome.availableSchemes, [])
    }

    // MARK: - resolveRequired (#169)

    func testResolveRequiredThrowsWhenMultipleSchemes() throws {
        let (resolver, task, _) = setup(
            taskName: "alpha",
            state: emptyState("alpha"),
            lister: FakeLister(schemes: ["BeanLedger", "WidgetsExtension", "WatchApp"])
        )
        XCTAssertThrowsError(try resolver.resolveRequired(task: task, explicit: nil)) { error in
            guard case let VibeChardError.schemeResolutionAmbiguous(available) = error else {
                return XCTFail("expected .schemeResolutionAmbiguous, got \(error)")
            }
            XCTAssertEqual(available, ["BeanLedger", "WidgetsExtension", "WatchApp"])
            // Exit code groups with the other "ambiguous, pass a flag" errors.
            XCTAssertEqual((error as! VibeChardError).exitCode, ExitCode.business)
            // Message lists candidates and suggests --scheme.
            let message = String(describing: error)
            XCTAssertTrue(message.contains("--scheme BeanLedger"), message)
            XCTAssertTrue(message.contains("WidgetsExtension"), message)
        }
    }

    func testResolveRequiredEscapeHatchWhenExtraArgsHaveScheme() throws {
        let (resolver, task, _) = setup(
            taskName: "alpha",
            state: emptyState("alpha"),
            lister: FakeLister(schemes: ["A", "B"])
        )
        // `vch build -- -scheme Foo` flows `-scheme` straight to
        // xcodebuild, so vch must not pre-empt it with an error.
        let r = try resolver.resolveRequired(
            task: task, explicit: nil, extraArgs: ["-scheme", "Foo"]
        )
        XCTAssertNil(r)
    }

    func testResolveRequiredFallsThroughWhenNoSchemes() throws {
        let (resolver, task, _) = setup(
            taskName: "alpha",
            state: emptyState("alpha"),
            lister: FakeLister(schemes: [])
        )
        XCTAssertNil(try resolver.resolveRequired(task: task, explicit: nil),
                     "zero schemes preserves best-effort fall-through, no throw")
    }

    func testResolveRequiredFallsThroughWhenListerUnavailable() throws {
        let (resolver, task, _) = setup(
            taskName: "alpha",
            state: emptyState("alpha"),
            lister: FakeLister(throwOnList: true)
        )
        XCTAssertNil(try resolver.resolveRequired(task: task, explicit: nil),
                     "detection-unavailable preserves best-effort fall-through, no throw")
    }

    func testResolveRequiredReturnsAutoDetectedSingleScheme() throws {
        let (resolver, task, _) = setup(
            taskName: "alpha",
            state: emptyState("alpha"),
            lister: FakeLister(schemes: ["OnlyOne"])
        )
        let r = try resolver.resolveRequired(task: task, explicit: nil)
        XCTAssertEqual(r, .init(scheme: "OnlyOne", source: .autoDetected))
    }

    func testResolveRequiredPrefersExplicitOverAmbiguity() throws {
        let (resolver, task, _) = setup(
            taskName: "alpha",
            state: emptyState("alpha"),
            lister: FakeLister(schemes: ["A", "B"])
        )
        let r = try resolver.resolveRequired(task: task, explicit: "CLI")
        XCTAssertEqual(r, .init(scheme: "CLI", source: .explicit))
    }
}

// MARK: - test double

private final class FakeLister: XcodebuildLister, @unchecked Sendable {
    let schemes: [String]
    let throwOnList: Bool
    var lastCwd: String?
    var lastXcodebuildContainer: XcodebuildContainer?
    init(schemes: [String] = [], throwOnList: Bool = false) {
        self.schemes = schemes
        self.throwOnList = throwOnList
    }
    func listJSON(
        cwd: String,
        xcodebuildContainer: XcodebuildContainer?
    ) throws -> Data {
        lastCwd = cwd
        lastXcodebuildContainer = xcodebuildContainer
        if throwOnList {
            throw VibeChardError.externalCommandFailed(
                cmd: "xcodebuild -list -json",
                exitCode: 1, stderr: "no project here"
            )
        }
        let payload: [String: Any] = [
            "project": ["name": "Demo", "schemes": schemes]
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }
}
