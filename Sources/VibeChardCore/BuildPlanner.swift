import Foundation

/// Pure xcodebuild argv builder. No I/O, no Process. Centralizes the
/// "what flags does vch inject?" knowledge so it can be unit-tested
/// exhaustively and stays in lock-step with `vch-xcodebuild-shim`'s
/// injection set (M2). Tests deliberately mirror those flag names.
public enum BuildPlanner {

    /// Subset of xcodebuild's CLI surface vch is opinionated about.
    /// Anything else the user wants flows through `extraArgs`.
    public struct Inputs: Equatable, Sendable {
        public let action: String         // "build" or "test" (or "clean", future)
        public let scheme: String?
        public let configuration: String?
        public let derivedDataPath: String
        public let clonedSourcePackagesDir: String
        public let resultBundlePath: String?
        /// Per-task cloned simulator UDID (M5). When set, takes
        /// precedence over `destinationDevice` and emits
        /// `-destination 'platform=iOS Simulator,id=<UDID>'`.
        public let destinationUDID: String?
        public let destinationDevice: String?
        public let extraArgs: [String]

        public init(
            action: String,
            scheme: String?,
            configuration: String?,
            derivedDataPath: String,
            clonedSourcePackagesDir: String,
            resultBundlePath: String?,
            destinationUDID: String? = nil,
            destinationDevice: String?,
            extraArgs: [String]
        ) {
            self.action = action
            self.scheme = scheme
            self.configuration = configuration
            self.derivedDataPath = derivedDataPath
            self.clonedSourcePackagesDir = clonedSourcePackagesDir
            self.resultBundlePath = resultBundlePath
            self.destinationUDID = destinationUDID
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
            argv += ["-destination", "platform=iOS Simulator,id=\(udid)"]
        } else if let device = input.destinationDevice {
            // Fallback when the user explicitly opts out of the lazy
            // clone via `--no-sim`. xcodebuild picks any matching
            // simulator by name (last-wins runtime).
            argv += ["-destination", "platform=iOS Simulator,name=\(device)"]
        }
        // Pass the user's extras BEFORE the action so flags like
        // `-quiet` apply to the action.
        argv += input.extraArgs
        argv.append(input.action)
        return argv
    }
}
