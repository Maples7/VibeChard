import Foundation

/// Schema v1 of the per-worktree state file `.vch/state.json`.
///
/// Per Q5 of the v1 plan, this file is the *only* persistence VibeChard
/// uses. It lives inside each worktree, never inside the user's home
/// directory, and is intentionally small. Fields that depend on the
/// runtime (e.g. agent process PID) are deliberately absent.
///
/// `schemaVersion` is decoupled from `VibeChard.version` (Q10): we plan
/// to keep schema 1 stable through every v0.x and v1.0 release. If we
/// ever bump it, that's a deliberate migration in a major version.
public struct TaskState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let name: String
    public let branch: String
    public let createdAt: Date
    public let baseRef: String

    /// Branch the main worktree was on at `vch new` time, recorded so
    /// `vch land` can default `--into` to the right place even after
    /// the user moves around. Optional for backward compatibility with
    /// state.json files written by vch ≤ v0.1.x. When `nil` (or when
    /// the recorded branch no longer exists), `vch land` falls back
    /// to the main worktree's current branch. (#7)
    public var baseBranch: String?

    /// Default scheme guess — captured at `vch new` from the project, may
    /// be `nil` if VibeChard cannot infer one. Used as the default for
    /// `vch build` / `vch test` (M4).
    public var scheme: String?

    /// Set on first `vch build`/`vch test` that needs a simulator (M5).
    public var simulator: SimulatorRecord?

    /// Last successful `vch build`. M4.
    public var lastBuild: BuildRecord?

    /// Last `vch test` run. M4.
    public var lastTest: TestRecord?

    /// Most recent `vch exec`/`vch new --exec` invocation. M3.
    public var lastExec: ExecRecord?

    public init(
        schemaVersion: Int = TaskState.currentSchemaVersion,
        name: String,
        branch: String,
        createdAt: Date,
        baseRef: String,
        baseBranch: String? = nil,
        scheme: String? = nil,
        simulator: SimulatorRecord? = nil,
        lastBuild: BuildRecord? = nil,
        lastTest: TestRecord? = nil,
        lastExec: ExecRecord? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.branch = branch
        self.createdAt = createdAt
        self.baseRef = baseRef
        self.baseBranch = baseBranch
        self.scheme = scheme
        self.simulator = simulator
        self.lastBuild = lastBuild
        self.lastTest = lastTest
        self.lastExec = lastExec
    }

    public struct SimulatorRecord: Codable, Equatable, Sendable {
        public let cloneUDID: String
        public let sourceUDID: String
        public let name: String
        /// Original device-template name passed to `--device` (e.g.
        /// `"iPhone 16"`). Distinct from `name`, which is the clone's
        /// display name (`<original> · vch[<task>]`). Used by
        /// `SimulatorService.ensureClone` to compare a re-invocation's
        /// `--device` against what we previously bound, so the second
        /// `vch test foo --device 'iPhone 16'` reuses the clone instead
        /// of throwing `simulatorAlreadyBound` (#4). Optional for
        /// backward compatibility with state.json written by vch ≤
        /// v0.1.x — the picker falls back to a suffix-strip on
        /// `name` when this is nil.
        public let templateName: String?
        /// Raw runtime identifier the template was cloned from (e.g.
        /// `com.apple.CoreSimulator.SimRuntime.iOS-26-4`). Persisted
        /// so `vch state` (#8) and the `vch build` / `vch test` log
        /// can surface the iOS version without having to round-trip
        /// through `simctl list` (#11). Optional for backward
        /// compatibility with state.json written by vch ≤ v0.1.x.
        public let runtimeIdentifier: String?

        public init(cloneUDID: String, sourceUDID: String, name: String,
                    templateName: String? = nil,
                    runtimeIdentifier: String? = nil) {
            self.cloneUDID = cloneUDID
            self.sourceUDID = sourceUDID
            self.name = name
            self.templateName = templateName
            self.runtimeIdentifier = runtimeIdentifier
        }
    }

    public struct BuildRecord: Codable, Equatable, Sendable {
        public let finishedAt: Date
        public let durationSeconds: Double
        public let success: Bool

        public init(finishedAt: Date, durationSeconds: Double, success: Bool) {
            self.finishedAt = finishedAt
            self.durationSeconds = durationSeconds
            self.success = success
        }
    }

    public struct TestRecord: Codable, Equatable, Sendable {
        public let finishedAt: Date
        public let durationSeconds: Double
        public let success: Bool
        public let resultBundlePath: String?

        public init(finishedAt: Date, durationSeconds: Double, success: Bool, resultBundlePath: String?) {
            self.finishedAt = finishedAt
            self.durationSeconds = durationSeconds
            self.success = success
            self.resultBundlePath = resultBundlePath
        }
    }

    public struct ExecRecord: Codable, Equatable, Sendable {
        public let command: String
        public let startedAt: Date
        public let exitedAt: Date?
        public let exitCode: Int32?

        public init(command: String, startedAt: Date, exitedAt: Date?, exitCode: Int32?) {
            self.command = command
            self.startedAt = startedAt
            self.exitedAt = exitedAt
            self.exitCode = exitCode
        }
    }

    // MARK: - JSON I/O

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func jsonData() throws -> Data {
        try Self.encoder().encode(self)
    }

    public static func parse(_ data: Data) throws -> TaskState {
        do {
            let state = try Self.decoder().decode(TaskState.self, from: data)
            if state.schemaVersion != Self.currentSchemaVersion {
                throw VibeChardError.stateSchemaMismatch(
                    found: state.schemaVersion,
                    expected: Self.currentSchemaVersion
                )
            }
            return state
        } catch let err as VibeChardError {
            throw err
        } catch {
            throw VibeChardError.stateFileCorrupt(
                path: "<in-memory>",
                underlying: String(describing: error)
            )
        }
    }
}
