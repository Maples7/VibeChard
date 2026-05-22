import Foundation

/// #18 — `xcodebuild -showBuildSettings -json` shell-out, behind a
/// protocol so `RunService` is fully unit-testable. Used by `vch run`
/// to resolve `PRODUCT_BUNDLE_IDENTIFIER` and the on-disk path of the
/// just-built `.app` bundle.
public protocol BuildSettingsLister: Sendable {
    /// Run `xcodebuild [-project P | -workspace W] -showBuildSettings
    /// -json -scheme S [-configuration C] [-destination D]` in `cwd`.
    /// Returns raw JSON stdout.
    func showBuildSettings(
        cwd: String,
        xcodebuildContainer: XcodebuildContainer?,
        scheme: String,
        configuration: String?,
        destination: String?,
        derivedDataPath: String?
    ) throws -> Data
}

public struct DiskBuildSettingsLister: BuildSettingsLister {
    public let runner: ProcessRunner
    public init(runner: ProcessRunner = DiskProcessRunner()) {
        self.runner = runner
    }

    public func showBuildSettings(
        cwd: String,
        xcodebuildContainer: XcodebuildContainer?,
        scheme: String,
        configuration: String?,
        destination: String?,
        derivedDataPath: String?
    ) throws -> Data {
        var argv: [String] = ["xcodebuild"]
        if let xcodebuildContainer {
            argv += xcodebuildContainer.xcodebuildArguments
        }
        argv += ["-showBuildSettings", "-json", "-scheme", scheme]
        if let configuration {
            argv += ["-configuration", configuration]
        }
        if let destination {
            argv += ["-destination", destination]
        }
        if let derivedDataPath {
            // Match the build's DerivedData so the resolved
            // BUILT_PRODUCTS_DIR / TARGET_BUILD_DIR point at the
            // bundle vch just built, not at the global default.
            argv += ["-derivedDataPath", derivedDataPath]
        }
        // Same `xcrun xcodebuild` indirection SchemeResolver uses, for
        // the same reason: bypass any worktree-local PATH shim so we
        // don't re-enter ourselves.
        let result = try runner.run(
            "/usr/bin/xcrun",
            args: argv,
            cwd: cwd,
            env: nil
        )
        guard result.succeeded else {
            throw VibeChardError.externalCommandFailed(
                cmd: "xcodebuild -showBuildSettings -json -scheme \(scheme)",
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
        return Data(result.stdout.utf8)
    }
}

/// Pure parser for `xcodebuild -showBuildSettings -json` output.
///
/// The JSON shape is:
/// ```json
/// [
///   {
///     "action": "build",
///     "target": "BeanLedger",
///     "buildSettings": {
///       "PRODUCT_BUNDLE_IDENTIFIER": "com.example.beanledger",
///       "FULL_PRODUCT_NAME": "BeanLedger.app",
///       "BUILT_PRODUCTS_DIR": "/path/to/Build/Products/Debug-iphonesimulator",
///       ...
///     }
///   }
/// ]
/// ```
///
/// Multiple targets may appear (an app + its embedded extensions);
/// `buildSettings(targetMatching:)` picks the first one whose target
/// name contains the requested scheme, falling back to the first
/// non-empty entry. That matches what Xcode's "run" button does.
public enum BuildSettingsParser {

    /// Returns the `buildSettings` dict for the first matching entry,
    /// or `nil` if the JSON shape is unrecognized / empty.
    public static func buildSettings(
        in data: Data,
        targetMatching scheme: String
    ) -> [String: String]? {
        guard
            let arr = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return nil }

        var fallback: [String: String]?
        for entry in arr {
            guard let dict = entry as? [String: Any],
                  let bs = dict["buildSettings"] as? [String: String] else {
                continue
            }
            if fallback == nil { fallback = bs }
            // Prefer an entry whose target matches the scheme. Xcode
            // schemes are typically named after their primary target,
            // but apps can have extensions/widgets sharing the scheme.
            if let target = dict["target"] as? String,
               target == scheme {
                return bs
            }
        }
        return fallback
    }

    /// Convenience: extract a single setting (e.g.
    /// `PRODUCT_BUNDLE_IDENTIFIER`) for the matching target.
    public static func setting(
        _ key: String,
        in data: Data,
        targetMatching scheme: String
    ) -> String? {
        buildSettings(in: data, targetMatching: scheme)?[key]
    }

    /// Infer the simulator platform for a scheme from build settings.
    /// `xcodebuild` may expose this as `PLATFORM_NAME`, `SDKROOT`, or
    /// `SUPPORTED_PLATFORMS` depending on project shape and Xcode
    /// version, so we check all three.
    public static func simulatorPlatform(
        in data: Data,
        targetMatching scheme: String
    ) -> SimRuntimeVersion.Platform? {
        guard
            let arr = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return nil }

        var fallbackPlatforms: [SimRuntimeVersion.Platform] = []
        for entry in arr {
            guard let dict = entry as? [String: Any],
                  let settings = dict["buildSettings"] as? [String: String],
                  let platform = simulatorPlatform(in: settings) else {
                continue
            }
            if let target = dict["target"] as? String,
               target == scheme {
                return platform
            }
            if !fallbackPlatforms.contains(platform) {
                fallbackPlatforms.append(platform)
            }
        }

        return fallbackPlatforms.count == 1 ? fallbackPlatforms[0] : nil
    }

    private static func simulatorPlatform(
        in settings: [String: String]
    ) -> SimRuntimeVersion.Platform? {
        let probes = [
            settings["PLATFORM_NAME"],
            settings["SDKROOT"],
            settings["SUPPORTED_PLATFORMS"],
        ].compactMap { $0?.lowercased() }

        for raw in probes {
            if raw.contains("watchsimulator") {
                return .watchOS
            }
            if raw.contains("appletvsimulator") {
                return .tvOS
            }
            if raw.contains("xrsimulator") || raw.contains("visionossimulator") {
                return .visionOS
            }
            if raw.contains("iphonesimulator") {
                return .iOS
            }
        }
        return nil
    }
}
