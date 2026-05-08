import Foundation

/// A simulator template / instance, as reported by
/// `xcrun simctl list devices --json`.
public struct SimDevice: Equatable, Sendable {
    public let udid: String
    public let name: String
    /// Raw runtime identifier, e.g.
    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-4`.
    public let runtime: String
    /// Parsed (major, minor) of the iOS runtime, used for "newest
    /// first" sorting. `nil` for non-iOS or unparseable runtimes.
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

/// Comparable iOS runtime version pulled out of the runtime
/// identifier. Stored as a tuple-like struct so tests and the picker
/// can use plain `<` / `>` comparisons.
public struct SimRuntimeVersion: Equatable, Comparable, Sendable {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public static func < (lhs: SimRuntimeVersion, rhs: SimRuntimeVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        return lhs.minor < rhs.minor
    }

    /// Parse from a runtime identifier like
    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-4` →
    /// `SimRuntimeVersion(major: 26, minor: 4)`. Returns `nil` for
    /// non-iOS runtimes (watchOS / tvOS / xrOS) — vch v1 only manages
    /// iOS sims.
    public static func parse(runtimeIdentifier: String) -> SimRuntimeVersion? {
        // Take the trailing `iOS-<M>-<m>` segment.
        guard let dotRange = runtimeIdentifier.range(of: ".", options: .backwards) else {
            return nil
        }
        let suffix = runtimeIdentifier[dotRange.upperBound...]
        guard suffix.hasPrefix("iOS-") else { return nil }
        let parts = suffix.dropFirst("iOS-".count).split(separator: "-")
        guard let major = parts.first.flatMap({ Int($0) }) else { return nil }
        let minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        return SimRuntimeVersion(major: major, minor: minor)
    }
}

/// Abstracted `xcrun simctl` for unit tests. Production impl is
/// `DiskSimctlClient`; tests pass a fake.
public protocol SimctlClient: Sendable {
    /// Devices in the "available" set (i.e. with a downloaded runtime).
    /// Equivalent to `xcrun simctl list devices available --json`.
    func availableDevices() throws -> [SimDevice]

    /// Every device known to simctl, including ones whose runtime is
    /// no longer available (e.g. an iOS 17 clone after the iOS 17
    /// runtime was uninstalled). `vch doctor` needs this superset to
    /// surface clones that would otherwise be invisible to the picker.
    /// Equivalent to `xcrun simctl list devices --json`.
    func allDevices() throws -> [SimDevice]

    /// Clone an existing device. Returns the new device's UDID.
    /// Equivalent to `xcrun simctl clone <sourceUDID> "<newName>"`.
    func clone(sourceUDID: String, newName: String) throws -> String

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
