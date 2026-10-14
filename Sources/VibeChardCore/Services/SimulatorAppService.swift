import Foundation

/// Opens the simulator UI bundled with the active Xcode. A missing UI
/// or window server must not prevent building, installing, or launching.
public struct SimulatorAppService: Sendable {
    private let fs: FileSystem
    private let runner: ProcessRunner
    private let developerDir: DeveloperDirResolver

    public init(
        fs: FileSystem = DiskFileSystem(),
        runner: ProcessRunner = DiskProcessRunner(),
        developerDir: DeveloperDirResolver = XcodeSelectDeveloperDirResolver()
    ) {
        self.fs = fs
        self.runner = runner
        self.developerDir = developerDir
    }

    public enum Outcome: Equatable, Sendable {
        case opened(appPath: String)
        case unavailable
        case failed(appPath: String, reason: String)

        public var note: String? {
            switch self {
            case .opened:
                return nil
            case .unavailable:
                return "note: simulator UI unavailable in the selected Xcode; continuing without a window."
            case .failed:
                return "note: could not open the simulator UI (a graphical session may be unavailable); continuing without a window."
            }
        }
    }

    /// Captures `open` output and converts all UI failures to a non-fatal
    /// outcome. Explicit DEVELOPER_DIR overrides never fall back to a
    /// different Xcode registered with LaunchServices.
    public func open(baseEnv: [String: String]) -> Outcome {
        var env = baseEnv
        DeveloperDirInjection.apply(to: &env, resolver: developerDir)
        guard let dir = env["DEVELOPER_DIR"], !dir.isEmpty,
              let appPath = resolveApp(developerDir: dir) else {
            return .unavailable
        }

        do {
            let result = try runner.run(
                "/usr/bin/open",
                args: ["-g", "-a", appPath],
                cwd: nil,
                env: env
            )
            guard result.succeeded else {
                return .failed(
                    appPath: appPath,
                    reason: "open exited with status \(result.exitCode): \(result.stderr)"
                )
            }
            return .opened(appPath: appPath)
        } catch {
            return .failed(appPath: appPath, reason: String(describing: error))
        }
    }

    private func resolveApp(developerDir: String) -> String? {
        // xcode-select accepts both the Xcode.app root and its
        // Contents/Developer directory as DEVELOPER_DIR.
        let dir = URL(fileURLWithPath: developerDir).standardizedFileURL
        let applications: URL
        if dir.pathExtension == "app" {
            applications = dir.appendingPathComponent("Contents/Applications")
        } else if dir.lastPathComponent == "Developer",
                  dir.deletingLastPathComponent().lastPathComponent == "Contents" {
            applications = dir.deletingLastPathComponent()
                .appendingPathComponent("Applications")
        } else {
            return nil
        }

        for name in ["Simulator.app", "DeviceHub.app"] {
            let path = applications.appendingPathComponent(name).path
            if fs.directoryExists(at: path) { return path }
        }
        return nil
    }
}
