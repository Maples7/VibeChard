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
}

// MARK: - test double

private final class FakeLister: XcodebuildLister, @unchecked Sendable {
    let schemes: [String]
    let throwOnList: Bool
    init(schemes: [String] = [], throwOnList: Bool = false) {
        self.schemes = schemes
        self.throwOnList = throwOnList
    }
    func listJSON(cwd: String) throws -> Data {
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
