import XCTest
@testable import VibeChardCore

/// Pure-logic tests for `SyncPlanner` — no git, no filesystem. The
/// planner only owns the post-IO branch (proceed vs noop), so the
/// surface here is small but every path is covered. (#25)
final class SyncPlannerTests: XCTestCase {

    private func makeInputs(
        strategy: SyncPlan.Strategy = .rebase,
        baseLabel: String = "origin/main",
        baseSHA: String = "abc1234567890abcdef1234567890abcdef12345",
        aheadCount: Int = 2,
        behindCount: Int = 3,
        dryRun: Bool = false
    ) -> SyncPlan.Inputs {
        SyncPlan.Inputs(
            strategy: strategy,
            baseLabel: baseLabel,
            baseSHA: baseSHA,
            aheadCount: aheadCount,
            behindCount: behindCount,
            dryRun: dryRun
        )
    }

    func testProceedWhenBehind() {
        let decision = SyncPlanner.plan(makeInputs())
        guard case let .proceed(resolved) = decision else {
            return XCTFail("expected proceed, got \(decision)")
        }
        XCTAssertEqual(resolved.strategy, .rebase)
        XCTAssertEqual(resolved.baseLabel, "origin/main")
        XCTAssertEqual(resolved.baseSHA, "abc1234567890abcdef1234567890abcdef12345")
        XCTAssertEqual(resolved.aheadCount, 2)
        XCTAssertEqual(resolved.behindCount, 3)
        XCTAssertFalse(resolved.dryRun)
    }

    func testProceedWithMergeStrategy() {
        let decision = SyncPlanner.plan(makeInputs(strategy: .merge))
        guard case let .proceed(resolved) = decision else {
            return XCTFail("expected proceed, got \(decision)")
        }
        XCTAssertEqual(resolved.strategy, .merge)
    }

    func testProceedPreservesDryRunFlag() {
        let decision = SyncPlanner.plan(makeInputs(dryRun: true))
        guard case let .proceed(resolved) = decision else {
            return XCTFail("expected proceed, got \(decision)")
        }
        XCTAssertTrue(resolved.dryRun)
    }

    func testNoopWhenNotBehind() {
        let decision = SyncPlanner.plan(makeInputs(behindCount: 0))
        guard case let .noop(resolved) = decision else {
            return XCTFail("expected noop, got \(decision)")
        }
        XCTAssertEqual(resolved.behindCount, 0)
        // The planner still echoes the input ahead count so `lastSync`
        // can record an accurate snapshot even on a no-op run.
        XCTAssertEqual(resolved.aheadCount, 2)
    }

    func testNoopWhenAlsoNotAhead() {
        // ahead = 0, behind = 0 → no-op (branches identical).
        let decision = SyncPlanner.plan(makeInputs(aheadCount: 0, behindCount: 0))
        guard case .noop = decision else {
            return XCTFail("expected noop, got \(decision)")
        }
    }

    func testNoopPreservesDryRunFlag() {
        let decision = SyncPlanner.plan(makeInputs(behindCount: 0, dryRun: true))
        guard case let .noop(resolved) = decision else {
            return XCTFail("expected noop, got \(decision)")
        }
        XCTAssertTrue(resolved.dryRun)
    }
}
