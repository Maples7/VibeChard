import XCTest
@testable import VibeChardCore

final class HolderClassifierTests: XCTestCase {

    // MARK: - background allowlist

    func testVSCodeRendererClassifiesAsBackground() {
        XCTAssertEqual(HolderClassifier.classify(command: "Code Helper (Renderer)"),
                       .background)
    }

    func testVSCodePluginHostClassifiesAsBackground() {
        XCTAssertEqual(HolderClassifier.classify(command: "Code Helper (Plugin)"),
                       .background)
    }

    func testSourceKitLSPClassifiesAsBackground() {
        XCTAssertEqual(HolderClassifier.classify(command: "sourcekit-lsp"),
                       .background)
    }

    func testMdworkerSharedClassifiesAsBackground() {
        XCTAssertEqual(HolderClassifier.classify(command: "mdworker_shared"),
                       .background)
    }

    func testCursorRendererClassifiesAsBackground() {
        XCTAssertEqual(HolderClassifier.classify(command: "Cursor Helper (Renderer)"),
                       .background)
    }

    /// lsof's `c` field is limited to 15 chars by default; some
    /// command strings end up truncated. The classifier matches by
    /// substring on the *registered* token, so a longer real
    /// `command` (e.g. with PID-suffixed variants) still classifies
    /// correctly.
    func testSubstringMatchAllowsTrailingSuffix() {
        XCTAssertEqual(HolderClassifier.classify(command: "sourcekit-lsp -1"),
                       .background)
    }

    // MARK: - interactive holdouts

    /// `Code Helper` (without a parenthesised role) is ambiguous —
    /// could be the foreground renderer holding an unsaved buffer.
    /// Stay conservative.
    func testBareCodeHelperStaysInteractive() {
        XCTAssertEqual(HolderClassifier.classify(command: "Code Helper"),
                       .interactive)
    }

    func testRawCodeStaysInteractive() {
        XCTAssertEqual(HolderClassifier.classify(command: "Code"),
                       .interactive)
    }

    func testXcodeStaysInteractive() {
        XCTAssertEqual(HolderClassifier.classify(command: "Xcode"),
                       .interactive)
    }

    func testNvimStaysInteractive() {
        XCTAssertEqual(HolderClassifier.classify(command: "nvim"),
                       .interactive)
    }

    func testZshStaysInteractive() {
        XCTAssertEqual(HolderClassifier.classify(command: "zsh"),
                       .interactive)
    }

    func testUnknownCommandStaysInteractive() {
        XCTAssertEqual(HolderClassifier.classify(command: "MyWeirdEditor"),
                       .interactive)
    }

    // MARK: - bulk classify preserves order

    func testBulkClassifyPreservesInputOrder() {
        let holders = [
            WorktreeHolder(pid: 1, command: "zsh", samplePath: "/wt"),
            WorktreeHolder(pid: 2, command: "sourcekit-lsp", samplePath: "/wt/Sources/A.swift"),
            WorktreeHolder(pid: 3, command: "Code Helper (Plugin)", samplePath: "/wt/Sources/B.swift"),
            WorktreeHolder(pid: 4, command: "nvim", samplePath: "/wt/Sources/C.swift"),
        ]
        let classified = HolderClassifier.classify(holders)
        XCTAssertEqual(classified.map(\.0.pid), [1, 2, 3, 4])
        XCTAssertEqual(classified.map(\.1),
                       [.interactive, .background, .background, .interactive])
    }
}
