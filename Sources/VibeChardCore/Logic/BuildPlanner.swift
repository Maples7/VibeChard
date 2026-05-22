import Foundation

/// Pure xcodebuild argv builder. No I/O, no Process. Centralizes the
/// "what flags does vch inject?" knowledge so it can be unit-tested
/// exhaustively and stays in lock-step with `vch-xcodebuild-shim`'s
/// injection set (M2). Tests deliberately mirror those flag names.
public enum BuildPlanner {

    /// Architecture of the host vch is running on. Pinned into
    /// `-destination` so xcodebuild doesn't print the noisy
    /// "Using the first of multiple matching destinations" warning
    /// when both arm64 and x86_64 entries match the cloned simulator
    /// (#5). v1 ships arm64-only, but a `#elseif` hook is kept so a
    /// future universal binary still does the right thing.
    public static let hostArch: String = {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "arm64"
        #endif
    }()

    /// Subset of xcodebuild's CLI surface vch is opinionated about.
    /// Anything else the user wants flows through `extraArgs`.
    public struct Inputs: Equatable, Sendable {
        public let action: String         // "build" or "test" (or "clean", future)
        public let xcodebuildContainer: XcodebuildContainer?
        public let scheme: String?
        public let configuration: String?
        public let derivedDataPath: String
        public let clonedSourcePackagesDir: String
        public let resultBundlePath: String?
        /// Per-task cloned simulator UDID (M5). When set, takes
        /// precedence over `destinationDevice` and emits
        /// `-destination 'platform=<platform> Simulator,id=<UDID>'`.
        public let destinationUDID: String?
        public let destinationPlatform: SimRuntimeVersion.Platform
        public let destinationDevice: String?
        public let extraArgs: [String]

        public init(
            action: String,
            xcodebuildContainer: XcodebuildContainer? = nil,
            scheme: String?,
            configuration: String?,
            derivedDataPath: String,
            clonedSourcePackagesDir: String,
            resultBundlePath: String?,
            destinationUDID: String? = nil,
            destinationPlatform: SimRuntimeVersion.Platform = .iOS,
            destinationDevice: String?,
            extraArgs: [String]
        ) {
            self.action = action
            self.xcodebuildContainer = xcodebuildContainer
            self.scheme = scheme
            self.configuration = configuration
            self.derivedDataPath = derivedDataPath
            self.clonedSourcePackagesDir = clonedSourcePackagesDir
            self.resultBundlePath = resultBundlePath
            self.destinationUDID = destinationUDID
            self.destinationPlatform = destinationPlatform
            self.destinationDevice = destinationDevice
            self.extraArgs = extraArgs
        }
    }

    /// Build the argv (without the leading `xcodebuild`).
    ///
    /// Order rationale: vch flags first so `extraArgs` can override
    /// (xcodebuild uses last-wins for repeated flags). Action verb at
    /// the very end keeps the visible CLI shape close to a hand-typed
    /// xcodebuild invocation.
    public static func args(_ input: Inputs) -> [String] {
        var argv: [String] = []

        if let container = input.xcodebuildContainer {
            argv += container.xcodebuildArguments
        }
        if let scheme = input.scheme {
            argv += ["-scheme", scheme]
        }
        if let configuration = input.configuration {
            argv += ["-configuration", configuration]
        }
        argv += ["-derivedDataPath", input.derivedDataPath]
        argv += ["-clonedSourcePackagesDirPath", input.clonedSourcePackagesDir]
        if let bundle = input.resultBundlePath {
            argv += ["-resultBundlePath", bundle]
        }
        if let udid = input.destinationUDID {
            // M5 path — bound to a per-task `xcrun simctl clone`.
            // arch is pinned (#5) so xcodebuild stops emitting the
            // multi-match warning when both arm64 and x86_64 entries
            // exist for the same UDID.
            argv += ["-destination", destination(
                platform: input.destinationPlatform,
                selector: "id=\(udid)"
            )]
        } else if let device = input.destinationDevice {
            // Fallback when the user explicitly opts out of the lazy
            // clone via `--no-sim`. xcodebuild picks any matching
            // simulator by name (last-wins runtime).
            argv += ["-destination", destination(
                platform: input.destinationPlatform,
                selector: "name=\(device)"
            )]
        }
        // Pass the user's extras BEFORE the action so flags like
        // `-quiet` apply to the action.
        argv += input.extraArgs
        argv.append(input.action)
        return argv
    }

    private static func destination(
        platform: SimRuntimeVersion.Platform,
        selector: String
    ) -> String {
        "platform=\(platform.xcodebuildDestinationPlatform),arch=\(Self.hostArch),\(selector)"
    }
}
