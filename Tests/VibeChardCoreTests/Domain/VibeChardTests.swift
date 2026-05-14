import XCTest
@testable import VibeChardCore

final class VibeChardTests: XCTestCase {
    func testVersionIsNonEmpty() {
        XCTAssertFalse(VibeChard.version.isEmpty)
    }

    func testVersionIsSemverLike() {
        let parts = VibeChard.version.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "version must have three dot-segments")
        for part in parts {
            XCTAssertNotNil(Int(part), "every segment must be an integer; got \(part)")
        }
    }

    func testTaglineMentionsApple() {
        XCTAssertTrue(
            VibeChard.tagline.lowercased().contains("apple"),
            "tagline must remind users this is Apple-only: \(VibeChard.tagline)"
        )
    }

    func testAgentRunbookURLIsVersionPinned() {
        XCTAssertEqual(VibeChard.agentRunbookPath, "docs/agent-runbook.md")
        XCTAssertEqual(
            VibeChard.agentRunbookURL,
            "\(VibeChard.repositoryURL)/blob/v\(VibeChard.version)/docs/agent-runbook.md"
        )
    }

    func testHomebrewRunbookPathHintPointsUnderVchDocs() {
        XCTAssertEqual(
            VibeChard.homebrewAgentRunbookPath,
            "$(brew --prefix vch)/share/doc/vch/agent-runbook.md"
        )
    }
}
