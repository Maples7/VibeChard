import Foundation

/// A simulator template / instance, as reported by
/// `xcrun simctl list devices --json`.
public struct SimDevice: Equatable, Sendable {
    public let udid: String
    public let name: String
    /// Raw runtime identifier, e.g.
    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-4` /
    /// `com.apple.CoreSimulator.SimRuntime.watchOS-11-5` /
    /// `com.apple.CoreSimulator.SimRuntime.xrOS-2-5`.
    public let runtime: String
    /// Parsed `(platform, major, minor)` of the runtime, used for
    /// "newest first" sorting and warm-template name composition.
    /// `nil` for unparseable runtimes (an unknown future Apple
    /// platform family, malformed identifiers, etc.).
    public let runtimeVersion: SimRuntimeVersion?
    public let isAvailable: Bool
    /// Live state from `simctl list` — `"Booted"`, `"Shutdown"`,
    /// `"Creating"`, etc. `nil` when not present in the JSON
    /// (`available`-only listings sometimes omit it on older Xcode).
    public let state: String?

    public init(
        udid: String,
        name: String,
        runtime: String,
        runtimeVersion: SimRuntimeVersion?,
        isAvailable: Bool,
        state: String? = nil
    ) {
        self.udid = udid
        self.name = name
        self.runtime = runtime
        self.runtimeVersion = runtimeVersion
        self.isAvailable = isAvailable
        self.state = state
    }
}

/// Comparable simulator runtime version pulled out of the runtime
/// identifier. Stored as a tuple-like struct so tests and the picker
/// can use plain `<` / `>` comparisons.
///
/// Carries the simulator platform (iOS / watchOS / tvOS / visionOS)
/// alongside `major.minor`. The platform tag matters because:
///   * Warm-template names embed the human label
///     (`vch-warm[Apple Watch Series 10 (46mm):watchOS 11.5]`)
///     and round-tripping requires we know which family `11.5` belongs
///     to — `iOS 11.5` and `watchOS 11.5` are different runtimes.
///   * The CoreSimulator identifier slug for visionOS is `xrOS`, not
///     `visionOS` — `Platform` carries both forms so `runtimeIdentifier`
///     emits the slug Apple's tooling expects while `dottedLabel` shows
///     the user-facing name.
public struct SimRuntimeVersion: Equatable, Comparable, Sendable {
    /// Apple simulator platform family. The four values match the
    /// platforms that vibe-chard's warm-template feature supports;
    /// any new platform family Apple ships in the future will fail
    /// `parse(runtimeIdentifier:)` (returns `nil`) until added here.
    public enum Platform: String, Equatable, Sendable, CaseIterable, Codable {
        case iOS
        case watchOS
        case tvOS
        case visionOS

        /// CoreSimulator runtime-identifier slug. visionOS is
        /// `xrOS` in `com.apple.CoreSimulator.SimRuntime.xrOS-2-5`
        /// even though the human-facing name is "visionOS"; the rest
        /// match their human label one-to-one.
        public var coreSimulatorSlug: String {
            switch self {
            case .iOS:      return "iOS"
            case .watchOS:  return "watchOS"
            case .tvOS:     return "tvOS"
            case .visionOS: return "xrOS"
            }
        }

        /// Human-facing platform token used by `xcodebuild
        /// -destination`, e.g. `watchOS Simulator`.
        public var xcodebuildDestinationPlatform: String {
            "\(rawValue) Simulator"
        }

        /// Map a CoreSimulator slug back to the platform. Accepts
        /// `xrOS` (canonical) and `visionOS` (user-typed alias) for
        /// the visionOS case so `--runtime "visionOS-2-5"` works.
        static func fromSlug(_ slug: String) -> Platform? {
            switch slug.lowercased() {
            case "ios":               return .iOS
            case "watchos":           return .watchOS
            case "tvos":              return .tvOS
            case "xros", "visionos":  return .visionOS
            default:                  return nil
            }
        }
    }

    public let platform: Platform
    public let major: Int
    public let minor: Int

    /// Default-iOS initializer kept so existing call-sites
    /// (`SimRuntimeVersion(major: 26, minor: 4)`) compile unchanged.
    /// New non-iOS sites should pass `platform:` explicitly.
    public init(platform: Platform = .iOS, major: Int, minor: Int) {
        self.platform = platform
        self.major = major
        self.minor = minor
    }

    /// Ordering: same-platform comparisons go by `(major, minor)` —
    /// the only ones that matter in practice (the picker only ever
    /// compares devices with identical names, which by definition
    /// share a platform). Cross-platform comparisons fall back to
    /// `Platform.allCases` index for determinism.
    public static func < (lhs: SimRuntimeVersion, rhs: SimRuntimeVersion) -> Bool {
        if lhs.platform != rhs.platform {
            // Stable but arbitrary cross-platform tiebreak; not
            // surfaced anywhere user-visible in v0.4.
            let order = Platform.allCases
            let li = order.firstIndex(of: lhs.platform) ?? 0
            let ri = order.firstIndex(of: rhs.platform) ?? 0
            return li < ri
        }
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        return lhs.minor < rhs.minor
    }

    /// Human-readable form, e.g. `iOS 26.4` / `watchOS 11.5` /
    /// `tvOS 18.0` / `visionOS 2.5`. Matches what `vch test --runtime`
    /// accepts on the CLI and what `vch sim warm-template list` emits
    /// in its name column, so users can copy-paste between commands.
    public var dottedLabel: String { "\(platform.rawValue) \(major).\(minor)" }

    /// Canonical CoreSimulator runtime identifier round-trippable
    /// with `parse(runtimeIdentifier:)`. Used wherever vch needs to
    /// hand a runtime to `xcrun simctl create` / `simctl list -j`.
    /// Emits `xrOS-X-Y` for visionOS (CoreSimulator's internal slug),
    /// not the human-facing `visionOS-X-Y`.
    public var runtimeIdentifier: String {
        "com.apple.CoreSimulator.SimRuntime.\(platform.coreSimulatorSlug)-\(major)-\(minor)"
    }

    /// Parse any user-facing runtime label vch accepts:
    ///   • raw identifier:  `com.apple.CoreSimulator.SimRuntime.iOS-26-4`
    ///   • dashed form:     `iOS-26-4` / `watchOS-11-5` / `xrOS-2-5`
    ///   • dotted form:     `iOS 26.4` / `watchOS 11.5` / `visionOS 2.5`
    public static func parse(runtimeLabel raw: String) -> SimRuntimeVersion? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if let parsed = parse(runtimeIdentifier: trimmed) {
            return parsed
        }

        for platform in Platform.allCases {
            let prefixes: [String] = (platform == .visionOS)
                ? ["visionOS", "xrOS"]
                : [platform.rawValue]
            for prefix in prefixes {
                if let parsed = parseShortRuntimeForm(
                    trimmed: trimmed,
                    platform: platform,
                    prefix: prefix
                ) {
                    return parsed
                }
            }
        }
        return nil
    }

    /// Parse from a runtime identifier like
    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-4` or
    /// `com.apple.CoreSimulator.SimRuntime.xrOS-2-5`. Returns `nil`
    /// for unrecognized platform families — vch's warm-template
    /// feature covers iOS / watchOS / tvOS / visionOS.
    public static func parse(runtimeIdentifier: String) -> SimRuntimeVersion? {
        // Take the trailing `<slug>-<M>-<m>` segment.
        guard let dotRange = runtimeIdentifier.range(of: ".", options: .backwards) else {
            return nil
        }
        let suffix = runtimeIdentifier[dotRange.upperBound...]
        guard let dashIdx = suffix.firstIndex(of: "-") else { return nil }
        let slug = String(suffix[..<dashIdx])
        guard let platform = Platform.fromSlug(slug) else { return nil }
        let rest = suffix[suffix.index(after: dashIdx)...]
        let parts = rest.split(separator: "-")
        guard let major = parts.first.flatMap({ Int($0) }) else { return nil }
        let minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        return SimRuntimeVersion(platform: platform, major: major, minor: minor)
    }

    /// Parse a single platform's short forms — `<prefix>-<M>-<m>` or
    /// `<prefix> <M>.<m>`.
    private static func parseShortRuntimeForm(
        trimmed: String,
        platform: Platform,
        prefix: String
    ) -> SimRuntimeVersion? {
        let lower = trimmed.lowercased()

        let dashed = (prefix + "-").lowercased()
        if lower.hasPrefix(dashed) {
            let body = trimmed.dropFirst(dashed.count)
            let parts = body.split(separator: "-")
            guard let major = parts.first.flatMap({ Int($0) }) else { return nil }
            let minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            return SimRuntimeVersion(platform: platform, major: major, minor: minor)
        }

        let dotted = (prefix + " ").lowercased()
        if lower.hasPrefix(dotted) {
            let body = trimmed.dropFirst(dotted.count)
            let parts = body.split(whereSeparator: { $0 == "." || $0 == "-" })
            guard let major = parts.first.flatMap({ Int($0) }) else { return nil }
            let minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            return SimRuntimeVersion(platform: platform, major: major, minor: minor)
        }
        return nil
    }
}

/// Abstracted `xcrun simctl` for unit tests. Production impl is
/// `DiskSimctlClient`; tests pass a fake.
public protocol SimctlClient: Sendable {
    /// Devices in the "available" set (i.e. with a downloaded runtime).
    /// Equivalent to `xcrun simctl list devices available --json`.
    func availableDevices() throws -> [SimDevice]

    /// Available simulator runtimes, parsed from
    /// `xcrun simctl list runtimes --json`. Used for diagnostics when
    /// a device type exists but no base device has been created yet.
    func availableRuntimes() throws -> [SimRuntimeVersion]

    /// Every device known to simctl, including ones whose runtime is
    /// no longer available (e.g. an iOS 17 clone after the iOS 17
    /// runtime was uninstalled). `vch doctor` needs this superset to
    /// surface clones that would otherwise be invisible to the picker.
    /// Equivalent to `xcrun simctl list devices --json`.
    func allDevices() throws -> [SimDevice]

    /// Clone an existing device. Returns the new device's UDID.
    /// Equivalent to `xcrun simctl clone <sourceUDID> "<newName>"`.
    func clone(sourceUDID: String, newName: String) throws -> String

    /// Create a new device from an Apple device template +
    /// runtime. Returns the new device's UDID. Equivalent to
    /// `xcrun simctl create "<name>" "<deviceTypeID>" "<runtimeID>"`.
    /// Both identifiers accept either the verbose CoreSimulator ID
    /// (`com.apple.CoreSimulator.SimDeviceType.iPhone-16`) or the
    /// human-readable form simctl knows (`"iPhone 16"` /
    /// `"iOS 26.4"`); this client passes them through verbatim.
    /// Used by `vch sim warm-template create` (#47).
    func create(name: String, deviceTypeID: String, runtimeID: String) throws -> String

    /// Boot the device if needed and wait for boot completion. Idempotent.
    /// Equivalent to `xcrun simctl bootstatus <udid> -b`.
    func bootstatusBoot(udid: String) throws

    /// `xcrun simctl shutdown <udid>`. Idempotent at the caller layer
    /// (the production impl swallows "already shut down" stderr).
    func shutdown(udid: String) throws

    /// `xcrun simctl erase <udid>`. Caller is responsible for
    /// shutting the device down first; vch's `SimulatorService.erase`
    /// chains shutdown→erase.
    func erase(udid: String) throws

    /// Delete a device. Best-effort caller behavior is recommended —
    /// e.g. `vch remove` swallows failures so the worktree still goes
    /// away.
    func delete(udid: String) throws

    /// Install an `.app` bundle onto the device. Equivalent to
    /// `xcrun simctl install <udid> <appPath>`. Used by `vch run`
    /// (#18) once the build has produced the bundle.
    func install(udid: String, appPath: String) throws

    /// Launch the installed app by bundle id, forwarding `args`
    /// verbatim after the bundle id. Equivalent to
    /// `xcrun simctl launch <udid> <bundleID> <args...>`. (#18)
    func launch(udid: String, bundleID: String, args: [String]) throws
}

public extension SimctlClient {
    func availableRuntimes() throws -> [SimRuntimeVersion] { [] }
}

/// Production implementation backed by `/usr/bin/xcrun simctl`.
public struct DiskSimctlClient: SimctlClient {
    public let runner: ProcessRunner
    public let xcrunPath: String

    public init(
        runner: ProcessRunner = DiskProcessRunner(),
        xcrunPath: String = "/usr/bin/xcrun"
    ) {
        self.runner = runner
        self.xcrunPath = xcrunPath
    }

    public func availableDevices() throws -> [SimDevice] {
        let result = try runner.run(
            xcrunPath,
            args: ["simctl", "list", "devices", "available", "--json"]
        )
        guard result.succeeded else {
            throw VibeChardError.externalCommandFailed(
                cmd: "xcrun simctl list devices available --json",
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
        return try SimctlListParser.parse(result.stdout)
    }

    public func availableRuntimes() throws -> [SimRuntimeVersion] {
        let result = try runner.run(
            xcrunPath,
            args: ["simctl", "list", "runtimes", "--json"]
        )
        guard result.succeeded else {
            throw VibeChardError.externalCommandFailed(
                cmd: "xcrun simctl list runtimes --json",
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
        return try SimctlRuntimesParser.parse(result.stdout)
    }

    public func allDevices() throws -> [SimDevice] {
        let result = try runner.run(
            xcrunPath,
            args: ["simctl", "list", "devices", "--json"]
        )
        guard result.succeeded else {
            throw VibeChardError.externalCommandFailed(
                cmd: "xcrun simctl list devices --json",
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
        return try SimctlListParser.parse(result.stdout)
    }

    public func clone(sourceUDID: String, newName: String) throws -> String {
        let result = try runner.run(
            xcrunPath,
            args: ["simctl", "clone", sourceUDID, newName]
        )
        guard result.succeeded else {
            throw VibeChardError.externalCommandFailed(
                cmd: "xcrun simctl clone \(sourceUDID) \"\(newName)\"",
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
        // simctl clone prints the new UDID on its own line.
        let udid = result.stdoutTrimmed
        guard !udid.isEmpty else {
            throw VibeChardError.externalCommandFailed(
                cmd: "xcrun simctl clone \(sourceUDID) \"\(newName)\"",
                exitCode: result.exitCode,
                stderr: "simctl clone produced no UDID on stdout"
            )
        }
        return udid
    }

    public func create(
        name: String,
        deviceTypeID: String,
        runtimeID: String
    ) throws -> String {
        let result = try runner.run(
            xcrunPath,
            args: ["simctl", "create", name, deviceTypeID, runtimeID]
        )
        guard result.succeeded else {
            throw VibeChardError.externalCommandFailed(
                cmd: "xcrun simctl create \"\(name)\" \"\(deviceTypeID)\" \"\(runtimeID)\"",
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
        // simctl create prints the new UDID on its own line.
        let udid = result.stdoutTrimmed
        guard !udid.isEmpty else {
            throw VibeChardError.externalCommandFailed(
                cmd: "xcrun simctl create \"\(name)\" \"\(deviceTypeID)\" \"\(runtimeID)\"",
                exitCode: result.exitCode,
                stderr: "simctl create produced no UDID on stdout"
            )
        }
        return udid
    }

    public func bootstatusBoot(udid: String) throws {
        let result = try runner.run(
            xcrunPath,
            args: ["simctl", "bootstatus", udid, "-b"]
        )
        guard result.succeeded else {
            throw VibeChardError.externalCommandFailed(
                cmd: "xcrun simctl bootstatus \(udid) -b",
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
    }

    public func shutdown(udid: String) throws {
        let result = try runner.run(
            xcrunPath,
            args: ["simctl", "shutdown", udid]
        )
        if result.succeeded { return }
        // simctl returns non-zero when the device is already shut down,
        // which is the no-op we want. Swallow only that specific case.
        let blob = result.stderr.lowercased()
        if blob.contains("current state: shutdown")
            || blob.contains("unable to shutdown device in current state")
            || blob.contains("already shut down") {
            return
        }
        throw VibeChardError.externalCommandFailed(
            cmd: "xcrun simctl shutdown \(udid)",
            exitCode: result.exitCode,
            stderr: result.stderr
        )
    }

    public func erase(udid: String) throws {
        let result = try runner.run(
            xcrunPath,
            args: ["simctl", "erase", udid]
        )
        guard result.succeeded else {
            throw VibeChardError.externalCommandFailed(
                cmd: "xcrun simctl erase \(udid)",
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
    }

    public func delete(udid: String) throws {
        let result = try runner.run(
            xcrunPath,
            args: ["simctl", "delete", udid]
        )
        guard result.succeeded else {
            throw VibeChardError.externalCommandFailed(
                cmd: "xcrun simctl delete \(udid)",
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
    }

    public func install(udid: String, appPath: String) throws {
        let result = try runner.run(
            xcrunPath,
            args: ["simctl", "install", udid, appPath]
        )
        guard result.succeeded else {
            throw VibeChardError.externalCommandFailed(
                cmd: "xcrun simctl install \(udid) \(appPath)",
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
    }

    public func launch(udid: String, bundleID: String, args: [String]) throws {
        let result = try runner.run(
            xcrunPath,
            args: ["simctl", "launch", udid, bundleID] + args
        )
        guard result.succeeded else {
            throw VibeChardError.externalCommandFailed(
                cmd: "xcrun simctl launch \(udid) \(bundleID)",
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
    }
}

/// Pure JSON parser for `xcrun simctl list devices --json`.
/// Extracted so tests can validate against fixture payloads without
/// having to actually run simctl.
enum SimctlListParser {
    static func parse(_ stdout: String) throws -> [SimDevice] {
        guard let data = stdout.data(using: .utf8) else {
            throw VibeChardError.externalCommandFailed(
                cmd: "xcrun simctl list devices --json",
                exitCode: -1,
                stderr: "non-UTF8 stdout"
            )
        }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw VibeChardError.externalCommandFailed(
                cmd: "xcrun simctl list devices --json",
                exitCode: -1,
                stderr: "could not parse JSON: \(error)"
            )
        }
        guard let root = json as? [String: Any],
              let devices = root["devices"] as? [String: Any] else {
            throw VibeChardError.externalCommandFailed(
                cmd: "xcrun simctl list devices --json",
                exitCode: -1,
                stderr: "missing top-level `devices` map"
            )
        }
        var out: [SimDevice] = []
        for (runtime, raw) in devices {
            guard let arr = raw as? [[String: Any]] else { continue }
            let version = SimRuntimeVersion.parse(runtimeIdentifier: runtime)
            for d in arr {
                guard
                    let udid = d["udid"] as? String,
                    let name = d["name"] as? String
                else { continue }
                let isAvailable = (d["isAvailable"] as? Bool) ?? true
                let state = d["state"] as? String
                out.append(SimDevice(
                    udid: udid,
                    name: name,
                    runtime: runtime,
                    runtimeVersion: version,
                    isAvailable: isAvailable,
                    state: state
                ))
            }
        }
        return out
    }
}

/// Pure JSON parser for `xcrun simctl list runtimes --json`.
enum SimctlRuntimesParser {
    static func parse(_ stdout: String) throws -> [SimRuntimeVersion] {
        guard let data = stdout.data(using: .utf8) else {
            throw VibeChardError.externalCommandFailed(
                cmd: "xcrun simctl list runtimes --json",
                exitCode: -1,
                stderr: "non-UTF8 stdout"
            )
        }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw VibeChardError.externalCommandFailed(
                cmd: "xcrun simctl list runtimes --json",
                exitCode: -1,
                stderr: "could not parse JSON: \(error)"
            )
        }
        guard let root = json as? [String: Any],
              let runtimes = root["runtimes"] as? [[String: Any]] else {
            throw VibeChardError.externalCommandFailed(
                cmd: "xcrun simctl list runtimes --json",
                exitCode: -1,
                stderr: "missing top-level `runtimes` array"
            )
        }

        var out: [SimRuntimeVersion] = []
        for runtime in runtimes {
            let isAvailable: Bool
            if let value = runtime["isAvailable"] as? Bool {
                isAvailable = value
            } else if let value = runtime["availability"] as? String {
                isAvailable = !value.lowercased().contains("unavailable")
            } else {
                isAvailable = true
            }
            guard isAvailable else { continue }

            let parsed = (runtime["identifier"] as? String)
                .flatMap(SimRuntimeVersion.parse(runtimeIdentifier:))
                ?? (runtime["name"] as? String)
                    .flatMap(SimRuntimeVersion.parse(runtimeLabel:))
            guard let parsed, !out.contains(parsed) else { continue }
            out.append(parsed)
        }
        return out.sorted(by: >)
    }
}
