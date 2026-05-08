import Foundation

/// #6 reduced — single-scheme auto-pick.
///
/// `vch build` / `vch test` historically required `--scheme`. In
/// projects with exactly one shared scheme (the common single-app
/// case), forcing the user to type it every time is friction. This
/// resolver implements a three-tier strategy:
///
///   1. **CLI `--scheme`** wins, always. Highest priority because it
///      represents the user's explicit intent for *this* invocation.
///   2. **`state.json.scheme`** — once you've successfully built or
///      tested with `--scheme MyApp`, vch records it and reuses it on
///      subsequent calls. This makes "do exactly what I did last time"
///      the default UX without a config file (AGENTS.md §7 forbids
///      `vch.toml` in v1).
///   3. **`xcodebuild -list -json` single-shared-scheme** — if the
///      worktree exposes exactly one shared scheme, use it and tell
///      the user once. Anything ambiguous (zero or 2+ schemes) falls
///      through to the historical "no -scheme flag → xcodebuild's
///      built-in default" path so we don't change behavior in repos
///      where the user is happy with what they had.
///
/// All shell-outs go through `XcodebuildLister` so the resolver is
/// fully unit-testable with an in-memory fake.
public protocol XcodebuildLister: Sendable {
    /// Run `xcodebuild -list -json` in `cwd`. Returns raw JSON stdout.
    /// On non-zero exit / parse error, the caller treats it as "auto
    /// detection unavailable" and falls through, NOT as a hard error.
    func listJSON(cwd: String) throws -> Data
}

public struct DiskXcodebuildLister: XcodebuildLister {
    public let runner: ProcessRunner
    public init(runner: ProcessRunner = DiskProcessRunner()) {
        self.runner = runner
    }

    public func listJSON(cwd: String) throws -> Data {
        // Use `/usr/bin/xcrun xcodebuild` rather than relying on PATH —
        // the worktree's `<wt>/.vch/bin/` shim would otherwise re-enter
        // here and mess with our isolation flags. (xcrun resolves via
        // the active developer dir, exactly what we want.)
        let result = try runner.run(
            "/usr/bin/xcrun",
            args: ["xcodebuild", "-list", "-json"],
            cwd: cwd,
            env: nil
        )
        guard result.succeeded else {
            throw VibeChardError.externalCommandFailed(
                cmd: "xcodebuild -list -json",
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
        return Data(result.stdout.utf8)
    }
}

/// Pure parser for `xcodebuild -list -json`. Public so tests can
/// exercise it directly with hand-written fixtures.
public enum SchemePickerJSON {

    /// Extract the `schemes` array from xcodebuild's JSON output.
    /// Handles both shapes:
    ///
    /// ```json
    /// { "project":   { "schemes": [...] } }
    /// { "workspace": { "schemes": [...] } }
    /// ```
    ///
    /// Returns `[]` on anything we don't recognize — the caller treats
    /// "couldn't auto-detect" as a fall-through, not an error.
    public static func parseSchemes(_ data: Data) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return [] }
        for key in ["project", "workspace"] {
            if let inner = dict[key] as? [String: Any],
               let schemes = inner["schemes"] as? [String] {
                return schemes
            }
        }
        return []
    }
}

public struct SchemeResolver: Sendable {

    public enum Source: String, Sendable, Equatable {
        case explicit       // CLI --scheme
        case persisted      // state.json scheme
        case autoDetected   // xcodebuild -list -json single shared
    }

    public struct Resolved: Sendable, Equatable {
        public let scheme: String
        public let source: Source
        public init(scheme: String, source: Source) {
            self.scheme = scheme
            self.source = source
        }
    }

    public let workspace: Workspace
    public let fs: FileSystem
    public let lister: XcodebuildLister?

    public init(workspace: Workspace,
                lister: XcodebuildLister?,
                fs: FileSystem = DiskFileSystem()) {
        self.workspace = workspace
        self.lister = lister
        self.fs = fs
    }

    /// Resolve scheme using the three-tier strategy. Returns nil when
    /// no strategy produced one — caller should let xcodebuild fall
    /// back to its built-in default (today's behavior).
    public func resolve(task: TaskName, explicit: String?) throws -> Resolved? {
        if let explicit, !explicit.isEmpty {
            return Resolved(scheme: explicit, source: .explicit)
        }
        // Tier 2: state.json
        let statePath = workspace.statePath(for: task)
        if fs.fileExists(at: statePath),
           let data = try? fs.readFile(at: statePath),
           let state = try? TaskState.parse(data),
           let persisted = state.scheme, !persisted.isEmpty {
            return Resolved(scheme: persisted, source: .persisted)
        }
        // Tier 3: single-shared-scheme detection. Best-effort — any
        // failure (no xcodebuild, malformed JSON, network FS hiccup)
        // returns nil so we don't break invocations in projects where
        // auto-detection is unavailable.
        guard let lister else { return nil }
        let wt = workspace.worktreePath(for: task)
        guard let raw = try? lister.listJSON(cwd: wt) else { return nil }
        let schemes = SchemePickerJSON.parseSchemes(raw)
        if schemes.count == 1 {
            return Resolved(scheme: schemes[0], source: .autoDetected)
        }
        return nil
    }
}
