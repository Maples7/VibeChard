import XCTest
@testable import VibeChardCore

final class XcodebuildContainerTests: XCTestCase {
    func testResolveProject() throws {
        let container = try XcodebuildContainer.resolve(
            project: " Apps/App/App.xcodeproj ",
            workspace: nil
        )
        XCTAssertEqual(container, .project("Apps/App/App.xcodeproj"))
        XCTAssertEqual(container?.xcodebuildArguments, [
            "-project", "Apps/App/App.xcodeproj",
        ])
    }

    func testResolveWorkspace() throws {
        let container = try XcodebuildContainer.resolve(
            project: nil,
            workspace: "App.xcworkspace"
        )
        XCTAssertEqual(container, .workspace("App.xcworkspace"))
        XCTAssertEqual(container?.xcodebuildArguments, [
            "-workspace", "App.xcworkspace",
        ])
    }

    func testRejectsProjectAndWorkspaceTogether() throws {
        XCTAssertThrowsError(try XcodebuildContainer.resolve(
            project: "App.xcodeproj",
            workspace: "App.xcworkspace"
        )) { error in
            guard case VibeChardError.xcodebuildContainerConflict = error else {
                return XCTFail("expected xcodebuildContainerConflict, got \(error)")
            }
        }
    }
}