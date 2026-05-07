import XCTest
@testable import VibeChardCore

/// Pure-logic tests for `LandPlanner` — no git, no filesystem. Every
/// branch of the decision tree gets exercised here so the integration
/// tests can focus on real-git interactions. (#7)
final class LandPlannerTests: XCTestCase {

    private func makeInputs(
        intoOption: String? = nil,
        recordedBaseBranch: String? = "main",
        currentMainBranch: String? = "main",
        strategy: LandPlan.Strategy = .noFF,
        userMessage: String? = nil,
        allowDirty: Bool = false,
        dryRun: Bool = false,
        removeAfter: Bool = true,
        dirtyPathsOnMain: [String] = [],
        taskDiffPaths: [String] = ["Sources/Foo.swift"],
        taskAheadCount: Int = 2,
        taskHeadSubject: String? = "fix: tighten Foo handling"
    ) -> LandPlan.Inputs {
        LandPlan.Inputs(
            task: try! TaskName("alpha"),
            intoOption: intoOption,
            recordedBaseBranch: recordedBaseBranch,
            currentMainBranch: currentMainBranch,
            strategy: strategy,
            userMessage: userMessage,
            allowDirty: allowDirty,
            dryRun: dryRun,
            removeAfter: removeAfter,
            dirtyPathsOnMain: dirtyPathsOnMain,
            taskDiffPaths: taskDiffPaths,
            taskAheadCount: taskAheadCount,
            taskHeadSubject: taskHeadSubject
        )
    }

    // MARK: - happy path

    func testProceedDefaultMessageFromTaskSubject() {
        let decision = LandPlanner.plan(makeInputs())
        guard case let .proceed(resolved) = decision else {
            return XCTFail("expected proceed, got \(decision)")
        }
        XCTAssertEqual(resolved.into, "main")
        XCTAssertEqual(resolved.strategy, .noFF)
        XCTAssertEqual(resolved.message, "Merge agent/alpha: fix: tighten Foo handling")
        XCTAssertTrue(resolved.removeAfter)
        XCTAssertFalse(resolved.dryRun)
    }

    func testProceedUserMessageWinsOverDefault() {
        let decision = LandPlanner.plan(makeInputs(userMessage: "Merge alpha refactor"))
        guard case let .proceed(resolved) = decision else {
            return XCTFail("expected proceed, got \(decision)")
        }
        XCTAssertEqual(resolved.message, "Merge alpha refactor")
    }

    func testProceedFallsBackToBareSubjectWhenNoCommitSubject() {
        let decision = LandPlanner.plan(makeInputs(taskHeadSubject: nil))
        guard case let .proceed(resolved) = decision else {
            return XCTFail("expected proceed, got \(decision)")
        }
        XCTAssertEqual(resolved.message, "Merge agent/alpha")
    }

    func testProceedHonorsExplicitInto() {
        let decision = LandPlanner.plan(makeInputs(
            intoOption: "develop",
            recordedBaseBranch: "main",
            currentMainBranch: "develop"
        ))
        guard case let .proceed(resolved) = decision else {
            return XCTFail("expected proceed, got \(decision)")
        }
        XCTAssertEqual(resolved.into, "develop")
    }

    func testProceedFallsBackToCurrentBranchWhenNothingRecorded() {
        let decision = LandPlanner.plan(makeInputs(
            recordedBaseBranch: nil,
            currentMainBranch: "develop"
        ))
        guard case let .proceed(resolved) = decision else {
            return XCTFail("expected proceed, got \(decision)")
        }
        XCTAssertEqual(resolved.into, "develop")
    }

    func testProceedSquashStrategyPropagated() {
        let decision = LandPlanner.plan(makeInputs(strategy: .squash))
        guard case let .proceed(resolved) = decision else {
            return XCTFail("expected proceed, got \(decision)")
        }
        XCTAssertEqual(resolved.strategy, .squash)
    }

    // MARK: - aborts

    func testAbortWhenMainOnDifferentBranch() {
        let decision = LandPlanner.plan(makeInputs(
            recordedBaseBranch: "main",
            currentMainBranch: "develop"
        ))
        XCTAssertEqual(decision, .abort(.mainNotOnInto(currentBranch: "develop", want: "main")))
    }

    func testAbortWhenMainOnDetachedHead() {
        let decision = LandPlanner.plan(makeInputs(
            recordedBaseBranch: "main",
            currentMainBranch: nil
        ))
        XCTAssertEqual(decision, .abort(.mainNotOnInto(currentBranch: nil, want: "main")))
    }

    func testAbortWhenNoIntoInferable() {
        // No --into, no recorded base, detached HEAD on main.
        let decision = LandPlanner.plan(makeInputs(
            recordedBaseBranch: nil,
            currentMainBranch: nil
        ))
        XCTAssertEqual(decision, .abort(.noIntoInferred))
    }

    func testAbortWhenTaskBranchNotAhead() {
        let decision = LandPlanner.plan(makeInputs(taskAheadCount: 0))
        XCTAssertEqual(decision, .abort(.noOp(taskBranch: "agent/alpha", into: "main")))
    }

    func testAbortWhenDirtyPathsOverlapTaskDiff() {
        let decision = LandPlanner.plan(makeInputs(
            dirtyPathsOnMain: ["Sources/Foo.swift", "untouched.txt"],
            taskDiffPaths: ["Sources/Foo.swift", "Sources/Bar.swift"]
        ))
        XCTAssertEqual(decision, .abort(.mergeOverlap(paths: ["Sources/Foo.swift"])))
    }

    func testAllowsDirtyOverlapWithFlag() {
        let decision = LandPlanner.plan(makeInputs(
            allowDirty: true,
            dirtyPathsOnMain: ["Sources/Foo.swift"],
            taskDiffPaths: ["Sources/Foo.swift", "Sources/Bar.swift"]
        ))
        guard case .proceed = decision else {
            return XCTFail("expected proceed, got \(decision)")
        }
    }

    func testAllowsNonOverlappingDirtyPaths() {
        let decision = LandPlanner.plan(makeInputs(
            dirtyPathsOnMain: ["docs/Notes.md"],
            taskDiffPaths: ["Sources/Foo.swift"]
        ))
        guard case .proceed = decision else {
            return XCTFail("expected proceed, got \(decision)")
        }
    }

    // MARK: - dry-run + flag plumbing

    func testDryRunPropagated() {
        let decision = LandPlanner.plan(makeInputs(dryRun: true))
        guard case let .proceed(resolved) = decision else {
            return XCTFail("expected proceed, got \(decision)")
        }
        XCTAssertTrue(resolved.dryRun)
    }

    func testRemoveAfterFalseHonored() {
        let decision = LandPlanner.plan(makeInputs(removeAfter: false))
        guard case let .proceed(resolved) = decision else {
            return XCTFail("expected proceed, got \(decision)")
        }
        XCTAssertFalse(resolved.removeAfter)
    }

    func testOverlapPathsAreSorted() {
        let decision = LandPlanner.plan(makeInputs(
            dirtyPathsOnMain: ["c.swift", "a.swift", "b.swift"],
            taskDiffPaths: ["b.swift", "a.swift", "c.swift"]
        ))
        guard case let .abort(.mergeOverlap(paths)) = decision else {
            return XCTFail("expected mergeOverlap, got \(decision)")
        }
        XCTAssertEqual(paths, ["a.swift", "b.swift", "c.swift"])
    }
}
