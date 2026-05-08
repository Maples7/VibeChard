import XCTest
@testable import VibeChardCore

final class OpenServiceTests: XCTestCase {

    // MARK: - detectProjectKind

    func testDetectProjectKindPrefersWorkspaceOverProject() {
        let kind = OpenService.detectProjectKind(
            rootContents: ["BeanLedger.xcodeproj", "BeanLedger.xcworkspace", "Package.swift", "README.md"],
            worktreePath: "/wt"
        )
        XCTAssertEqual(kind, .xcworkspace(absolutePath: "/wt/BeanLedger.xcworkspace"))
    }

    func testDetectProjectKindPicksXcodeproj() {
        let kind = OpenService.detectProjectKind(
            rootContents: ["BeanLedger.xcodeproj", "Package.swift", "Sources"],
            worktreePath: "/wt"
        )
        XCTAssertEqual(kind, .xcodeproj(absolutePath: "/wt/BeanLedger.xcodeproj"))
    }

    func testDetectProjectKindPicksSwiftPackage() {
        let kind = OpenService.detectProjectKind(
            rootContents: ["Package.swift", "Sources", "Tests"],
            worktreePath: "/wt"
        )
        XCTAssertEqual(kind, .swiftPackage(packageFilePath: "/wt/Package.swift"))
    }

    func testDetectProjectKindFallsThroughToBareDirectory() {
        let kind = OpenService.detectProjectKind(
            rootContents: ["README.md", "src", "go.mod"],
            worktreePath: "/wt"
        )
        XCTAssertEqual(kind, .bareDirectory)
    }

    func testDetectProjectKindIsDeterministicWithMultipleMatches() {
        // Same input arrived in different order should yield the same pick.
        let a = OpenService.detectProjectKind(
            rootContents: ["B.xcworkspace", "A.xcworkspace"],
            worktreePath: "/wt"
        )
        let b = OpenService.detectProjectKind(
            rootContents: ["A.xcworkspace", "B.xcworkspace"],
            worktreePath: "/wt"
        )
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, .xcworkspace(absolutePath: "/wt/A.xcworkspace"))
    }

    // MARK: - IDE.parse

    func testIDEParseAliases() {
        XCTAssertEqual(OpenService.IDE.parse("xcode"), .xcode)
        XCTAssertEqual(OpenService.IDE.parse("Xcode"), .xcode)
        XCTAssertEqual(OpenService.IDE.parse("code"), .vscode)
        XCTAssertEqual(OpenService.IDE.parse("vscode"), .vscode)
        XCTAssertEqual(OpenService.IDE.parse("VSCode"), .vscode)
        XCTAssertEqual(OpenService.IDE.parse("cursor"), .cursor)
        XCTAssertEqual(OpenService.IDE.parse("Cursor"), .cursor)
    }

    func testIDEParseUnknownFallsToOther() {
        XCTAssertEqual(OpenService.IDE.parse("Sublime Text"), .other(appName: "Sublime Text"))
        XCTAssertEqual(OpenService.IDE.parse("Zed"), .other(appName: "Zed"))
    }

    // MARK: - resolveIDE

    func testResolveIDEExplicitWins() {
        let kind = OpenService.ProjectKind.xcworkspace(absolutePath: "/wt/X.xcworkspace")
        let ide = OpenService.resolveIDE(
            requested: "code",
            env: ["VCH_OPEN_DEFAULT": "xcode"],
            projectKind: kind
        )
        XCTAssertEqual(ide, .vscode)
    }

    func testResolveIDEEnvWinsWhenNoRequest() {
        let kind = OpenService.ProjectKind.xcworkspace(absolutePath: "/wt/X.xcworkspace")
        let ide = OpenService.resolveIDE(
            requested: nil,
            env: ["VCH_OPEN_DEFAULT": "cursor"],
            projectKind: kind
        )
        XCTAssertEqual(ide, .cursor)
    }

    func testResolveIDEEmptyRequestFallsToEnv() {
        let kind = OpenService.ProjectKind.bareDirectory
        let ide = OpenService.resolveIDE(
            requested: "   ",
            env: ["VCH_OPEN_DEFAULT": "xcode"],
            projectKind: kind
        )
        XCTAssertEqual(ide, .xcode)
    }

    func testResolveIDEAutoXcodeForWorkspace() {
        let kind = OpenService.ProjectKind.xcworkspace(absolutePath: "/wt/X.xcworkspace")
        let ide = OpenService.resolveIDE(requested: nil, env: [:], projectKind: kind)
        XCTAssertEqual(ide, .xcode)
    }

    func testResolveIDEAutoXcodeForXcodeproj() {
        let kind = OpenService.ProjectKind.xcodeproj(absolutePath: "/wt/X.xcodeproj")
        let ide = OpenService.resolveIDE(requested: nil, env: [:], projectKind: kind)
        XCTAssertEqual(ide, .xcode)
    }

    func testResolveIDEAutoVSCodeForSwiftPackage() {
        let kind = OpenService.ProjectKind.swiftPackage(packageFilePath: "/wt/Package.swift")
        let ide = OpenService.resolveIDE(requested: nil, env: [:], projectKind: kind)
        XCTAssertEqual(ide, .vscode)
    }

    func testResolveIDEAutoVSCodeForBareDirectory() {
        let ide = OpenService.resolveIDE(
            requested: nil,
            env: [:],
            projectKind: .bareDirectory
        )
        XCTAssertEqual(ide, .vscode)
    }

    // MARK: - buildArgv

    func testBuildArgvXcodeWorkspaceUsesOpen() {
        let argv = OpenService.buildArgv(
            ide: .xcode,
            projectKind: .xcworkspace(absolutePath: "/wt/X.xcworkspace"),
            worktreePath: "/wt",
            commandExists: { _ in false }
        )
        XCTAssertEqual(argv, ["/usr/bin/open", "/wt/X.xcworkspace"])
    }

    func testBuildArgvXcodeProjectUsesOpen() {
        let argv = OpenService.buildArgv(
            ide: .xcode,
            projectKind: .xcodeproj(absolutePath: "/wt/X.xcodeproj"),
            worktreePath: "/wt",
            commandExists: { _ in false }
        )
        XCTAssertEqual(argv, ["/usr/bin/open", "/wt/X.xcodeproj"])
    }

    func testBuildArgvXcodeSwiftPackageRoutesToXcodeApp() {
        let argv = OpenService.buildArgv(
            ide: .xcode,
            projectKind: .swiftPackage(packageFilePath: "/wt/Package.swift"),
            worktreePath: "/wt",
            commandExists: { _ in false }
        )
        XCTAssertEqual(argv, ["/usr/bin/open", "-a", "Xcode", "/wt/Package.swift"])
    }

    func testBuildArgvXcodeBareDirRoutesToXcodeApp() {
        let argv = OpenService.buildArgv(
            ide: .xcode,
            projectKind: .bareDirectory,
            worktreePath: "/wt",
            commandExists: { _ in false }
        )
        XCTAssertEqual(argv, ["/usr/bin/open", "-a", "Xcode", "/wt"])
    }

    func testBuildArgvVSCodePrefersCLIWhenOnPath() {
        let argv = OpenService.buildArgv(
            ide: .vscode,
            projectKind: .swiftPackage(packageFilePath: "/wt/Package.swift"),
            worktreePath: "/wt",
            commandExists: { $0 == "code" }
        )
        XCTAssertEqual(argv, ["code", "/wt"])
    }

    func testBuildArgvVSCodeFallsBackToOpenWhenNoCLI() {
        let argv = OpenService.buildArgv(
            ide: .vscode,
            projectKind: .bareDirectory,
            worktreePath: "/wt",
            commandExists: { _ in false }
        )
        XCTAssertEqual(argv, ["/usr/bin/open", "-a", "Visual Studio Code", "/wt"])
    }

    func testBuildArgvCursorPrefersCLIWhenOnPath() {
        let argv = OpenService.buildArgv(
            ide: .cursor,
            projectKind: .bareDirectory,
            worktreePath: "/wt",
            commandExists: { $0 == "cursor" }
        )
        XCTAssertEqual(argv, ["cursor", "/wt"])
    }

    func testBuildArgvCursorFallsBackToOpen() {
        let argv = OpenService.buildArgv(
            ide: .cursor,
            projectKind: .bareDirectory,
            worktreePath: "/wt",
            commandExists: { _ in false }
        )
        XCTAssertEqual(argv, ["/usr/bin/open", "-a", "Cursor", "/wt"])
    }

    func testBuildArgvOtherUsesOpenDashA() {
        let argv = OpenService.buildArgv(
            ide: .other(appName: "Sublime Text"),
            projectKind: .bareDirectory,
            worktreePath: "/wt",
            commandExists: { _ in true }
        )
        XCTAssertEqual(argv, ["/usr/bin/open", "-a", "Sublime Text", "/wt"])
    }
}
