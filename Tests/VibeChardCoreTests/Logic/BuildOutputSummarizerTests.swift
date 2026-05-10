import XCTest
@testable import VibeChardCore

/// Coverage for the streaming `xcodebuild build` output parser
/// introduced in #48 — `vch build` now mirrors `vch test`'s concise
/// summary path so agents stop having to `| tail -5` the firehose
/// just to recover `** BUILD SUCCEEDED **`.
final class BuildOutputSummarizerTests: XCTestCase {

    private func feed(_ s: BuildOutputSummarizer, _ block: String) {
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            s.feed(String(line))
        }
    }

    // MARK: - Status detection

    func testRecognizesBuildSucceededBanner() {
        let s = BuildOutputSummarizer()
        s.feed("** BUILD SUCCEEDED **")
        XCTAssertEqual(s.status, .succeeded)
    }

    func testRecognizesBuildFailedBanner() {
        let s = BuildOutputSummarizer()
        s.feed("** BUILD FAILED **")
        XCTAssertEqual(s.status, .failed)
    }

    func testStatusUnknownByDefault() {
        let s = BuildOutputSummarizer()
        s.feed("CompileSwift normal arm64 /tmp/Foo.swift")
        XCTAssertEqual(s.status, .unknown)
    }

    // MARK: - Diagnostic parsing

    func testParsesSwiftErrorWithFileLineColumn() {
        let s = BuildOutputSummarizer()
        s.feed("/Users/me/repo/Sources/Foo.swift:42:9: error: cannot find 'foo' in scope")
        XCTAssertEqual(s.diagnostics.count, 1)
        let d = s.diagnostics[0]
        XCTAssertEqual(d.kind, .error)
        XCTAssertEqual(d.file, "/Users/me/repo/Sources/Foo.swift")
        XCTAssertEqual(d.line, 42)
        XCTAssertEqual(d.column, 9)
        XCTAssertTrue(d.message.contains("cannot find 'foo'"))
    }

    func testParsesSwiftWarningWithoutColumn() {
        // Older xcodebuild versions emit `path:line: kind: msg`
        // without a column.
        let s = BuildOutputSummarizer()
        s.feed("/x/Bar.swift:18: warning: variable 'x' was never used")
        XCTAssertEqual(s.diagnostics.count, 1)
        let d = s.diagnostics[0]
        XCTAssertEqual(d.kind, .warning)
        XCTAssertEqual(d.line, 18)
        XCTAssertNil(d.column)
    }

    func testParsesLinkerError() {
        let s = BuildOutputSummarizer()
        s.feed("ld: error: undefined symbol _foo")
        XCTAssertEqual(s.diagnostics.count, 1)
        XCTAssertEqual(s.diagnostics[0].kind, .error)
        XCTAssertNil(s.diagnostics[0].file)
        XCTAssertTrue(s.diagnostics[0].message.contains("ld:"))
    }

    func testParsesClangWarning() {
        let s = BuildOutputSummarizer()
        s.feed("clang: warning: -ObjC is implicitly enabled")
        XCTAssertEqual(s.diagnostics.count, 1)
        XCTAssertEqual(s.diagnostics[0].kind, .warning)
    }

    func testFiltersLdDuplicateLibrariesNoise() {
        // ld emits this on every Apple-platform build by default;
        // including it would double every warning count and bury the
        // user's real warnings.
        let s = BuildOutputSummarizer()
        s.feed("ld: warning: ignoring duplicate libraries: '-lc++'")
        XCTAssertTrue(s.diagnostics.isEmpty,
                      "ld dup-libs noise should be filtered before counting")
    }

    func testDeduplicatesIdenticalDiagnostics() {
        // xcodebuild sometimes repeats the same compile invocation
        // (e.g. partial-rebuild + final), emitting the same diagnostic
        // twice. The summary line should not double-count.
        let s = BuildOutputSummarizer()
        s.feed("/x/Foo.swift:42:9: warning: variable 'x' was never used")
        s.feed("/x/Foo.swift:42:9: warning: variable 'x' was never used")
        XCTAssertEqual(s.diagnostics.count, 1)
        XCTAssertEqual(s.warningCount, 1)
    }

    func testIgnoresUnrelatedLines() {
        // Compile invocations, env exports, etc. — we don't surface
        // them. Still safe to feed; full text is in last-build.log.
        let s = BuildOutputSummarizer()
        feed(s, """
        === BUILD TARGET MyApp OF PROJECT MyProject WITH CONFIGURATION Debug ===
        CompileSwift normal arm64 /Users/me/repo/Sources/Foo.swift
            cd /Users/me/repo
            export DEVELOPER_DIR=...
        ProcessInfoPlistFile build/MyApp.app/Info.plist
        """)
        XCTAssertTrue(s.diagnostics.isEmpty)
        XCTAssertEqual(s.status, .unknown)
    }

    // MARK: - Counts

    func testCountsErrorsAndWarningsSeparately() {
        let s = BuildOutputSummarizer()
        feed(s, """
        /a/Foo.swift:10:1: warning: foo
        /a/Bar.swift:20:1: warning: bar
        /a/Baz.swift:30:1: error: baz
        ld: error: undefined symbol _qux
        """)
        XCTAssertEqual(s.warningCount, 2)
        XCTAssertEqual(s.errorCount, 2)
    }

    // MARK: - Render

    func testRendersSucceededLine() {
        let s = BuildOutputSummarizer()
        feed(s, """
        /a/Foo.swift:10:1: warning: variable 'x' was never used
        ** BUILD SUCCEEDED **
        """)
        let out = s.render(durationSeconds: 12.4, colorize: false)
        XCTAssertTrue(out.contains("✓ build succeeded in 12.40s"))
        XCTAssertTrue(out.contains("(1 warning)"))
        XCTAssertTrue(out.contains("** BUILD SUCCEEDED **"))
    }

    func testRendersSucceededWithoutWarningsHasNoQualifier() {
        let s = BuildOutputSummarizer()
        s.feed("** BUILD SUCCEEDED **")
        let out = s.render(durationSeconds: 1.2, colorize: false)
        XCTAssertFalse(out.contains("warning"),
                       "no `(N warnings)` qualifier when warnings are zero")
        XCTAssertTrue(out.contains("✓ build succeeded in 1.20s"))
    }

    func testRendersFailureWithErrorList() {
        let s = BuildOutputSummarizer()
        feed(s, """
        /Users/me/repo/Sources/Bar.swift:12:5: error: cannot find 'foo' in scope
        /Users/me/repo/Sources/Baz.swift:8: error: missing argument
        ** BUILD FAILED **
        """)
        let out = s.render(durationSeconds: 8.1, colorize: false)
        XCTAssertTrue(out.contains("✗ Bar.swift:12:5: cannot find 'foo' in scope"),
                      "error listing should use leaf filename, not absolute path")
        XCTAssertTrue(out.contains("✗ Baz.swift:8: missing argument"))
        XCTAssertTrue(out.contains("✗ build failed in 8.10s"))
        XCTAssertTrue(out.contains("(2 errors)"))
        XCTAssertTrue(out.contains("** BUILD FAILED **"))
    }

    func testRendersUnknownStatusGuidance() {
        let s = BuildOutputSummarizer()
        let out = s.render(durationSeconds: 2.0, colorize: false)
        XCTAssertTrue(out.contains("? build status unknown"))
    }

    func testUnknownStatusAppendsLogPathHint() {
        // #69: same fix as the test renderer — surface the log path
        // so the "see full log" hint is actionable without scrolling
        // back to the launch banner.
        let s = BuildOutputSummarizer()
        let out = s.render(durationSeconds: 2.0, colorize: false,
                           logPath: "/tmp/x/.vch/last-build.log")
        XCTAssertTrue(out.contains("? build status unknown"))
        XCTAssertTrue(out.contains("→ log: /tmp/x/.vch/last-build.log"),
                      "unknown build branch must surface the log path; got: \(out)")
    }

    func testKnownBuildStatusDoesNotAppendLogPathHint() {
        let s = BuildOutputSummarizer()
        s.feed("** BUILD SUCCEEDED **")
        let out = s.render(durationSeconds: 1.0, colorize: false,
                           logPath: "/tmp/x/.vch/last-build.log")
        XCTAssertFalse(out.contains("→ log:"),
                       "log path must not be appended on succeeded builds")
    }

    func testCapsErrorListAtTwenty() {
        let s = BuildOutputSummarizer()
        for i in 1...25 {
            s.feed("/a/Foo.swift:\(i):1: error: error number \(i)")
        }
        s.feed("** BUILD FAILED **")
        let out = s.render(durationSeconds: 5.0, colorize: false)
        XCTAssertTrue(out.contains("error number 1"),
                      "first 20 errors should be listed")
        XCTAssertTrue(out.contains("error number 20"))
        XCTAssertFalse(out.contains("error number 21"),
                       "errors 21+ are summarized into a tail line")
        XCTAssertTrue(out.contains("(+5 more errors)"))
    }

    func testColorsOffByDefaultProducesNoEscapes() {
        let s = BuildOutputSummarizer()
        s.feed("** BUILD SUCCEEDED **")
        let out = s.render(durationSeconds: 1.0, colorize: false)
        XCTAssertFalse(out.contains("\u{1B}["),
                       "no ANSI escapes when colorize=false")
    }

    func testColorsOnEnabledProducesEscapes() {
        let s = BuildOutputSummarizer()
        s.feed("** BUILD SUCCEEDED **")
        let out = s.render(durationSeconds: 1.0, colorize: true)
        XCTAssertTrue(out.contains("\u{1B}["),
                      "colorize=true should emit ANSI styling")
    }

    func testDurationBucketsAtMinuteBoundary() {
        let s1 = BuildOutputSummarizer()
        s1.feed("** BUILD SUCCEEDED **")
        XCTAssertTrue(s1.render(durationSeconds: 12.4, colorize: false).contains("12.40s"))

        let s2 = BuildOutputSummarizer()
        s2.feed("** BUILD SUCCEEDED **")
        XCTAssertTrue(s2.render(durationSeconds: 75, colorize: false).contains("1m 15s"))

        let s3 = BuildOutputSummarizer()
        s3.feed("** BUILD SUCCEEDED **")
        XCTAssertTrue(s3.render(durationSeconds: 3725, colorize: false).contains("1h 02m"))
    }
}
