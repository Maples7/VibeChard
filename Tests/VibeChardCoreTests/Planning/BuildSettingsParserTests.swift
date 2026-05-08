import XCTest
@testable import VibeChardCore

final class BuildSettingsParserTests: XCTestCase {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    func test_buildSettings_picksMatchingTarget_whenMultipleEntries() throws {
        let json = #"""
        [
          {
            "action": "build",
            "target": "AppExtension",
            "buildSettings": {
              "PRODUCT_BUNDLE_IDENTIFIER": "com.example.app.extension",
              "FULL_PRODUCT_NAME": "AppExtension.appex",
              "WRAPPER_NAME": "AppExtension.appex",
              "TARGET_BUILD_DIR": "/tmp/products/Debug-iphonesimulator"
            }
          },
          {
            "action": "build",
            "target": "App",
            "buildSettings": {
              "PRODUCT_BUNDLE_IDENTIFIER": "com.example.app",
              "FULL_PRODUCT_NAME": "App.app",
              "WRAPPER_NAME": "App.app",
              "TARGET_BUILD_DIR": "/tmp/products/Debug-iphonesimulator"
            }
          }
        ]
        """#
        let bs = BuildSettingsParser.buildSettings(
            in: data(json), targetMatching: "App"
        )
        XCTAssertEqual(bs?["PRODUCT_BUNDLE_IDENTIFIER"], "com.example.app")
        XCTAssertEqual(bs?["WRAPPER_NAME"], "App.app")
    }

    func test_buildSettings_fallsBackToFirst_whenNoExactMatch() throws {
        let json = #"""
        [
          {
            "target": "Beanledger",
            "buildSettings": {
              "PRODUCT_BUNDLE_IDENTIFIER": "com.example.bl",
              "FULL_PRODUCT_NAME": "BeanLedger.app"
            }
          }
        ]
        """#
        let bs = BuildSettingsParser.buildSettings(
            in: data(json), targetMatching: "BeanLedger"
        )
        // Falls back to first entry when no target name matches.
        XCTAssertEqual(bs?["PRODUCT_BUNDLE_IDENTIFIER"], "com.example.bl")
    }

    func test_setting_returnsNil_whenJSONIsEmpty() {
        let bs = BuildSettingsParser.setting(
            "PRODUCT_BUNDLE_IDENTIFIER",
            in: data("[]"),
            targetMatching: "anything"
        )
        XCTAssertNil(bs)
    }

    func test_setting_returnsNil_whenJSONShapeIsBroken() {
        let bs = BuildSettingsParser.setting(
            "PRODUCT_BUNDLE_IDENTIFIER",
            in: data("{}"),
            targetMatching: "anything"
        )
        XCTAssertNil(bs)
    }

    func test_setting_returnsNil_whenSettingMissing() {
        let json = #"""
        [
          {
            "target": "App",
            "buildSettings": { "FULL_PRODUCT_NAME": "App.app" }
          }
        ]
        """#
        let bs = BuildSettingsParser.setting(
            "PRODUCT_BUNDLE_IDENTIFIER",
            in: data(json),
            targetMatching: "App"
        )
        XCTAssertNil(bs)
    }
}
