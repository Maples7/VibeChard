import XCTest
@testable import VibeChardCore

/// Pure-function tests for `PrunePlanner` (#67). The planner
/// classifies each task as `prunable` or skipped (with a reason); these
/// tests pin every branch in the decision tree.
final class PrunePlannerTests: XCTestCase {
    // MARK: - prunable

    func testPrunableWhenMergedAndCleanAndUnheld() {
        let s = makeSummary(name: "shipped", merged: true, dirty: false)
        let plan = PrunePlanner.plan(inputs: [
            PrunePlanner.Input(summary: s, holders: [])
        ])
        XCTAssertEqual(plan.prunable.count, 1)
        XCTAssertEqual(plan.skipped.count, 0)
        XCTAssertEqual(plan.prunable.first?.summary.name, "shipped")
    }

    // MARK: - merge gate

    func testSkipsWhenMergeStatusUnknown() {
        let s = makeSummary(name: "orphan", merged: nil, dirty: false)
        let plan = PrunePlanner.plan(inputs: [
            PrunePlanner.Input(summary: s, holders: [])
        ])
        XCTAssertEqual(plan.prunable.count, 0)
        XCTAssertEqual(plan.skipped.first?.skip, .mergeStatusUnknown)
    }

    func testSkipsWhenAheadOfBase() {
        let s = makeSummary(name: "wip", merged: false, ahead: 3, dirty: false)
        let plan = PrunePlanner.plan(inputs: [
            PrunePlanner.Input(summary: s, holders: [])
        ])
        XCTAssertEqual(plan.skipped.first?.skip, .notMerged(aheadCount: 3))
    }

    // MARK: - dirty gate

    func testSkipsWhenMergedButDirty() {
        let s = makeSummary(name: "shipped-but-dirty", merged: true, dirty: true)
        let plan = PrunePlanner.plan(inputs: [
            PrunePlanner.Input(summary: s, holders: [])
        ])
        XCTAssertEqual(plan.skipped.first?.skip, .dirty)
    }

    func testAllowDirtyOptInTreatsDirtyMergedAsPrunable() {
        let s = makeSummary(name: "shipped-but-dirty", merged: true, dirty: true)
        let plan = PrunePlanner.plan(
            inputs: [PrunePlanner.Input(summary: s, holders: [])],
            options: PrunePlanner.Options(allowDirty: true, force: false)
        )
        XCTAssertEqual(plan.prunable.count, 1)
        XCTAssertEqual(plan.skipped.count, 0)
    }

    // MARK: - holder gate

    func testSkipsWhenHeldOpen() {
        let s = makeSummary(name: "shipped", merged: true, dirty: false)
        let holder = WorktreeHolder(
            pid: 4242, command: "Code", samplePath: "/Users/me/Repo-shipped/x"
        )
        let plan = PrunePlanner.plan(inputs: [
            PrunePlanner.Input(summary: s, holders: [holder])
        ])
        XCTAssertEqual(plan.skipped.first?.skip, .heldOpen(holders: [holder]))
    }

    func testForceOptInTreatsHeldMergedAsPrunable() {
        let s = makeSummary(name: "shipped", merged: true, dirty: false)
        let holder = WorktreeHolder(
            pid: 4242, command: "Code", samplePath: "/Users/me/Repo-shipped/x"
        )
        let plan = PrunePlanner.plan(
            inputs: [PrunePlanner.Input(summary: s, holders: [holder])],
            options: PrunePlanner.Options(allowDirty: false, force: true)
        )
        XCTAssertEqual(plan.prunable.count, 1)
    }

    // MARK: - gate ordering

    /// Merge gate is evaluated first: a dirty unmerged worktree is
    /// reported as `notMerged`, NOT `dirty`. The user wouldn't be able
    /// to do anything about the dirty state anyway until the branch
    /// merges.
    func testNotMergedTakesPrecedenceOverDirty() {
        let s = makeSummary(name: "wip", merged: false, ahead: 2, dirty: true)
        let plan = PrunePlanner.plan(inputs: [
            PrunePlanner.Input(summary: s, holders: [])
        ])
        XCTAssertEqual(plan.skipped.first?.skip, .notMerged(aheadCount: 2))
    }

    /// Once merged, dirty is reported even when held-open is also
    /// true. The planner reports the FIRST applicable reason so the
    /// CLI's hint nudges the user toward the cheapest fix
    /// (`--allow-dirty` is less aggressive than `--force`).
    func testDirtyTakesPrecedenceOverHeldOpen() {
        let s = makeSummary(name: "shipped", merged: true, dirty: true)
        let holder = WorktreeHolder(
            pid: 4242, command: "Code", samplePath: "/Users/me/Repo-shipped/x"
        )
        let plan = PrunePlanner.plan(inputs: [
            PrunePlanner.Input(summary: s, holders: [holder])
        ])
        XCTAssertEqual(plan.skipped.first?.skip, .dirty)
    }

    // MARK: - ordering

    func testDecisionsPreserveInputOrder() {
        let inputs = [
            PrunePlanner.Input(
                summary: makeSummary(name: "alpha", merged: true, dirty: false),
                holders: []
            ),
            PrunePlanner.Input(
                summary: makeSummary(name: "beta", merged: false, ahead: 1, dirty: false),
                holders: []
            ),
            PrunePlanner.Input(
                summary: makeSummary(name: "gamma", merged: nil, dirty: false),
                holders: []
            ),
        ]
        let plan = PrunePlanner.plan(inputs: inputs)
        XCTAssertEqual(plan.decisions.map { $0.summary.name }, ["alpha", "beta", "gamma"])
    }

    // MARK: - helpers

    /// `merged: nil` → `mergedIntoBase` is nil (unknown). Otherwise we
    /// derive `aheadCount` from the merged flag (0 if true, `ahead`
    /// param if false) so the test names stay readable.
    private func makeSummary(
        name: String,
        merged: Bool?,
        ahead: Int = 0,
        dirty: Bool
    ) -> TaskSummary {
        let git: GitStatus?
        if let merged {
            git = GitStatus(
                aheadCount: merged ? 0 : ahead,
                behindCount: 0,
                isDirty: dirty,
                lastCommitSubject: nil,
                mergedIntoBase: merged
            )
        } else {
            git = GitStatus(
                aheadCount: nil,
                behindCount: nil,
                isDirty: dirty,
                lastCommitSubject: nil,
                mergedIntoBase: nil
            )
        }
        return TaskSummary(
            name: name,
            branch: "agent/\(name)",
            path: "/Users/me/Repo-\(name)",
            createdAt: nil,
            baseRef: "abc123",
            baseBranch: "main",
            simulatorName: nil,
            lastBuildSucceeded: nil,
            lastBuildAt: nil,
            gitStatus: git
        )
    }
}
