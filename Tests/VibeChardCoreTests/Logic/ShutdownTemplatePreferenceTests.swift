import XCTest
@testable import VibeChardCore

/// Unit coverage for the `VCH_SHUTDOWN_TEMPLATE_ON_CLONE` opt-in
/// precedence rule. (#164)
final class ShutdownTemplatePreferenceTests: XCTestCase {

    // MARK: - explicit flag wins

    func testExplicitFlagWinsRegardlessOfEnv() {
        // `--shutdown-template` is an unconditional yes — even if the
        // opt-in env var is absent or explicitly disabled.
        XCTAssertTrue(ShutdownTemplatePreference.resolve(flag: true, env: [:]))
        XCTAssertTrue(ShutdownTemplatePreference.resolve(
            flag: true,
            env: ["VCH_SHUTDOWN_TEMPLATE_ON_CLONE": "0"]
        ))
    }

    // MARK: - conservative default

    func testDefaultsToFalseWithoutFlagOrEnv() {
        // Hard rule #9: vch never auto-touches a shared template unless
        // the user opted in somehow.
        XCTAssertFalse(ShutdownTemplatePreference.resolve(flag: false, env: [:]))
    }

    func testUnrelatedEnvDoesNotOptIn() {
        XCTAssertFalse(ShutdownTemplatePreference.resolve(
            flag: false,
            env: ["VCH_OPEN_DEFAULT": "xcode", "PATH": "/usr/bin"]
        ))
    }

    // MARK: - env opt-in (truthy)

    func testEnvOptInAcceptsTruthyValues() {
        for value in ["1", "true", "TRUE", "yes", "Yes", "on", "ON", "  true  "] {
            XCTAssertTrue(
                ShutdownTemplatePreference.resolve(
                    flag: false,
                    env: ["VCH_SHUTDOWN_TEMPLATE_ON_CLONE": value]
                ),
                "expected opt-in for VCH_SHUTDOWN_TEMPLATE_ON_CLONE=\(value)"
            )
        }
    }

    // MARK: - env opt-in (falsy / malformed leave default in place)

    func testEnvOptInRejectsFalsyAndUnknownValues() {
        for value in ["0", "false", "no", "off", "", "   ", "2", "enabled", "y"] {
            XCTAssertFalse(
                ShutdownTemplatePreference.resolve(
                    flag: false,
                    env: ["VCH_SHUTDOWN_TEMPLATE_ON_CLONE": value]
                ),
                "expected conservative default for VCH_SHUTDOWN_TEMPLATE_ON_CLONE=\(value)"
            )
        }
    }

    // MARK: - isOptedIn helper

    func testIsOptedInHandlesNil() {
        XCTAssertFalse(ShutdownTemplatePreference.isOptedIn(nil))
    }
}
