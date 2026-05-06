// vch-xcodebuild-shim — pure injection logic.
//
// This file is intentionally free of `Process`, `execv`, and Foundation
// I/O so we can unit-test it from a separate target without the shim
// binary being involved. It is *also* compiled into the shim binary
// itself: see `Package.swift` (`ShimTests` target uses `sources:` to
// include this file directly).
//
// Hard rule (AGENTS.md #6): this file must NOT import VibeChardCore or
// any third-party module. Foundation is OK only for `String` ergonomics.

import Foundation

/// Names of the three xcodebuild flags vch may inject. Kept centrally so
/// the "user already passed it" check stays in lock-step with the
/// "what flag would we add" code path.
public enum ShimFlag {
    public static let derivedDataPath = "-derivedDataPath"
    public static let clonedSourcePackagesDirPath = "-clonedSourcePackagesDirPath"
    public static let resultBundlePath = "-resultBundlePath"
}

/// Names of the env vars vch reads. These match what the validated bash
/// PoC at `scripts/poc/m0_5-shim/shim/xcodebuild` reads, so M2 is a
/// drop-in replacement.
public enum ShimEnv {
    public static let derivedDataPath = "VCH_DERIVED_DATA_PATH"
    public static let spmCloneDir = "VCH_SPM_CLONE_DIR"
    public static let resultBundlePath = "VCH_RESULT_BUNDLE_PATH"
    public static let debug = "VCH_SHIM_DEBUG"
    /// Set by the shim itself before `execv` so a subsequent xcodebuild
    /// invocation under the same PATH doesn't double-inject (defense in
    /// depth — the user-args scan already prevents it, but this guards
    /// against very-corner cases like a user-provided wrapper that drops
    /// our flags then re-invokes xcodebuild).
    public static let alreadyInjected = "VCH_SHIM_INJECTED"
    /// Diagnostic / test override: when set, the shim hands argv to this
    /// path directly instead of resolving via `/usr/bin/xcrun -f`.
    /// Looked up per tool, e.g. `VCH_SHIM_REAL_XCODEBUILD`. Documented
    /// only in `vch doctor --bug-report`.
    public static func realOverrideKey(for tool: InvokedTool) -> String {
        "VCH_SHIM_REAL_\(tool.rawValue.uppercased())"
    }
}

/// One isolation flag the shim wants to add to xcodebuild's argv.
public struct ShimInjectedFlag: Equatable, Sendable {
    public let flag: String
    public let value: String

    public init(flag: String, value: String) {
        self.flag = flag
        self.value = value
    }
}

/// The decision the shim makes for one invocation: which flags to add,
/// which directories to ensure exist before exec, and whether to skip
/// injection entirely (e.g. invoked as a non-xcodebuild tool).
public struct ShimPlan: Equatable, Sendable {
    public let injected: [ShimInjectedFlag]
    /// Directories to create before exec. For `-derivedDataPath` and
    /// `-clonedSourcePackagesDirPath` this is the value itself; for
    /// `-resultBundlePath` it's the parent (xcodebuild needs the file
    /// itself to NOT yet exist).
    public let directoriesToEnsure: [String]
    public let skipReason: String?

    public init(injected: [ShimInjectedFlag], directoriesToEnsure: [String], skipReason: String? = nil) {
        self.injected = injected
        self.directoriesToEnsure = directoriesToEnsure
        self.skipReason = skipReason
    }

    public static let noop = ShimPlan(injected: [], directoriesToEnsure: [])
}

/// What tool was the shim invoked as, decided from `argv[0]`. Only
/// `xcodebuild` triggers flag injection; `xcrun`/`swift` are pure
/// pass-throughs because they don't accept `-derivedDataPath` etc.
public enum InvokedTool: String, Equatable, Sendable {
    case xcodebuild
    case xcrun
    case swift

    /// Strip the path component to get the leaf name, then map to a
    /// known tool. Unknown names are treated as xcodebuild for safety
    /// (the most common shim target).
    public static func from(argv0: String) -> InvokedTool {
        let leaf = (argv0 as NSString).lastPathComponent
        return InvokedTool(rawValue: leaf) ?? .xcodebuild
    }
}

public enum ShimPlanner {

    /// Compute the injection plan for an xcodebuild invocation given
    /// the user-provided `args` (everything after `argv[0]`) and the
    /// process environment. Pure function: no IO, no env mutation.
    public static func plan(
        invokedAs tool: InvokedTool,
        userArgs: [String],
        env: [String: String]
    ) -> ShimPlan {
        // Non-xcodebuild tools never get flag injection.
        guard tool == .xcodebuild else {
            return ShimPlan(injected: [], directoriesToEnsure: [], skipReason: "tool=\(tool.rawValue)")
        }

        // Defense in depth: if a parent vch process already ran us in
        // this argv chain, skip.
        if env[ShimEnv.alreadyInjected] == "1" {
            return ShimPlan(injected: [], directoriesToEnsure: [], skipReason: "already-injected")
        }

        let userFlags = Set(userArgs.filter { $0.hasPrefix("-") })

        var injected: [ShimInjectedFlag] = []
        var dirs: [String] = []

        if !userFlags.contains(ShimFlag.derivedDataPath),
           let v = env[ShimEnv.derivedDataPath]?.nonEmpty {
            injected.append(ShimInjectedFlag(flag: ShimFlag.derivedDataPath, value: v))
            dirs.append(v)
        }

        if !userFlags.contains(ShimFlag.clonedSourcePackagesDirPath),
           let v = env[ShimEnv.spmCloneDir]?.nonEmpty {
            injected.append(ShimInjectedFlag(flag: ShimFlag.clonedSourcePackagesDirPath, value: v))
            dirs.append(v)
        }

        if !userFlags.contains(ShimFlag.resultBundlePath),
           let v = env[ShimEnv.resultBundlePath]?.nonEmpty {
            injected.append(ShimInjectedFlag(flag: ShimFlag.resultBundlePath, value: v))
            // -resultBundlePath wants the file to NOT exist; create the parent only.
            dirs.append((v as NSString).deletingLastPathComponent)
        }

        return ShimPlan(injected: injected, directoriesToEnsure: dirs)
    }

    /// Build the argv that should be passed to `execv` for the real
    /// xcodebuild: injected flags first, then user args verbatim.
    public static func argv(forReal real: String, plan: ShimPlan, userArgs: [String]) -> [String] {
        var out: [String] = [real]
        for f in plan.injected {
            out.append(f.flag)
            out.append(f.value)
        }
        out.append(contentsOf: userArgs)
        return out
    }

    /// Format a one-line debug summary for stderr when VCH_SHIM_DEBUG is set.
    public static func debugLine(invokedAs tool: InvokedTool, real: String, plan: ShimPlan, userArgs: [String]) -> String {
        let injectedStr: String
        if let reason = plan.skipReason {
            injectedStr = "<skipped: \(reason)>"
        } else if plan.injected.isEmpty {
            injectedStr = "<none>"
        } else {
            injectedStr = plan.injected
                .map { "\($0.flag) \($0.value)" }
                .joined(separator: " ")
        }
        return "vch-shim[\(tool.rawValue)]: real=\(real) injected=\(injectedStr) user-args=\(userArgs.joined(separator: " "))"
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
