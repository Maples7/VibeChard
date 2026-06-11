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
///      the user once. Zero schemes / detection-unavailable falls
///      through to the historical "no -scheme flag → xcodebuild's
///      built-in default" path so we don't change behavior in repos
///      where the user is happy with what they had. Two-or-more
///      shared schemes is ambiguous: `resolve` still returns nil
///      (callers that can tolerate a missing scheme keep working),
///      but `resolveRequired` fails fast with the candidate list so
///      `vch build` / `vch test` / `vch run` never leak xcodebuild's
///      `-scheme` / `-derivedDataPath` flag conflict (#169).
///
/// All shell-outs go through `XcodebuildLister` so the resolver is
/// fully unit-testable with an in-memory fake.
public protocol XcodebuildLister: Sendable {
    /// Run `xcodebuild -list -json` in `cwd`, optionally scoped to a
    /// specific `-project` or `-workspace`. Returns raw JSON stdout.
    /// On non-zero exit / parse error, the caller treats it as "auto
    /// detection unavailable" and falls through, NOT as a hard error.
    func listJSON(cwd: String, xcodebuildContainer: XcodebuildContainer?) throws -> Data
}

public struct DiskXcodebuildLister: XcodebuildLister {
    public let runner: ProcessRunner
    public init(runner: ProcessRunner = DiskProcessRunner()) {
        self.runner = runner
    }

    public func listJSON(
        cwd: String,
        xcodebuildContainer: XcodebuildContainer?
    ) throws -> Data {
        var argv = ["xcodebuild", "-list", "-json"]
        if let xcodebuildContainer {
            argv += xcodebuildContainer.xcodebuildArguments
        }
        // Use `/usr/bin/xcrun xcodebuild` rather than relying on PATH —
        // the worktree's `<wt>/.vch/bin/` shim would otherwise re-enter
        // here and mess with our isolation flags. (xcrun resolves via
        // the active developer dir, exactly what we want.)
        let result = try runner.run(
            "/usr/bin/xcrun",
            args: argv,
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

    /// Richer result of resolution: the picked scheme (if any) plus the
    /// shared schemes `xcodebuild -list -json` reported. The schemes are
    /// captured only when tier 3 was actually reached (no explicit /
    /// persisted scheme); they are `[]` otherwise, or when auto-detection
    /// was unavailable. Used by `resolveRequired` to fail fast with a
    /// candidate list in multi-scheme repos (#169).
    public struct ResolutionOutcome: Sendable, Equatable {
        public let resolved: Resolved?
        public let availableSchemes: [String]
        public init(resolved: Resolved?, availableSchemes: [String]) {
            self.resolved = resolved
            self.availableSchemes = availableSchemes
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

    /// Lenient resolution: the three-tier strategy, returning nil when
    /// no tier produced a scheme. Never throws on ambiguity — a caller
    /// that can tolerate a missing scheme keeps working. The `vch
    /// build` / `vch test` / `vch run` commands use `resolveRequired`
    /// instead, which fails fast in multi-scheme repos (#169).
    public func resolve(
        task: TaskName,
        explicit: String?,
        xcodebuildContainer: XcodebuildContainer? = nil
    ) throws -> Resolved? {
        try resolveWithDiagnostics(
            task: task,
            explicit: explicit,
            xcodebuildContainer: xcodebuildContainer
        ).resolved
    }

    /// Same three-tier resolution as `resolve`, but also reports the
    /// shared schemes seen via `xcodebuild -list -json` so callers can
    /// render an actionable error when resolution comes up empty in a
    /// multi-scheme repo. `availableSchemes` is populated only when
    /// tier 3 was reached and the lister succeeded.
    public func resolveWithDiagnostics(
        task: TaskName,
        explicit: String?,
        xcodebuildContainer: XcodebuildContainer? = nil
    ) throws -> ResolutionOutcome {
        if let explicit, !explicit.isEmpty {
            return ResolutionOutcome(
                resolved: Resolved(scheme: explicit, source: .explicit),
                availableSchemes: []
            )
        }
        // Tier 2: state.json
        let statePath = workspace.statePath(for: task)
        if fs.fileExists(at: statePath),
           let data = try? fs.readFile(at: statePath),
           let state = try? TaskState.parse(data),
           let persisted = state.scheme, !persisted.isEmpty {
            return ResolutionOutcome(
                resolved: Resolved(scheme: persisted, source: .persisted),
                availableSchemes: []
            )
        }
        // Tier 3: single-shared-scheme detection. Best-effort — any
        // failure (no xcodebuild, malformed JSON, network FS hiccup)
        // returns no scheme so we don't break invocations in projects
        // where auto-detection is unavailable.
        guard let lister else {
            return ResolutionOutcome(resolved: nil, availableSchemes: [])
        }
        let wt = workspace.worktreePath(for: task)
        guard let raw = try? lister.listJSON(
            cwd: wt,
            xcodebuildContainer: xcodebuildContainer
        ) else {
            return ResolutionOutcome(resolved: nil, availableSchemes: [])
        }
        let schemes = SchemePickerJSON.parseSchemes(raw)
        if schemes.count == 1 {
            return ResolutionOutcome(
                resolved: Resolved(scheme: schemes[0], source: .autoDetected),
                availableSchemes: schemes
            )
        }
        return ResolutionOutcome(resolved: nil, availableSchemes: schemes)
    }

    /// Resolve a scheme, failing fast with a user-facing error when the
    /// repo is multi-scheme and nothing could be picked (#169).
    ///
    /// vch always injects `-derivedDataPath`, and xcodebuild refuses to
    /// run with `-derivedDataPath` but no `-scheme`. So when resolution
    /// comes up empty in a multi-scheme repo, letting the command
    /// proceed only reaches xcodebuild's cryptic flag-conflict error —
    /// possibly *after* vch has already booted a simulator. Catch it
    /// here so the caller can bail before any such side effect.
    ///
    /// `extraArgs` is the `vch build` / `vch test` escape hatch: those
    /// post-`--` args flow verbatim to xcodebuild, so a user-supplied
    /// `-scheme` there is honored and suppresses the error. `vch run`
    /// passes `[]` because its post-`--` args go to `simctl launch`,
    /// not xcodebuild.
    public func resolveRequired(
        task: TaskName,
        explicit: String?,
        extraArgs: [String] = [],
        xcodebuildContainer: XcodebuildContainer? = nil
    ) throws -> Resolved? {
        let outcome = try resolveWithDiagnostics(
            task: task,
            explicit: explicit,
            xcodebuildContainer: xcodebuildContainer
        )
        if let resolved = outcome.resolved { return resolved }
        // The user passed `-scheme` after `--` (build / test only) —
        // honor it and let xcodebuild consume it.
        if extraArgs.contains("-scheme") { return nil }
        // Multi-scheme repo with nothing to disambiguate: the one case
        // we can name precisely. Fail before xcodebuild leaks its flag
        // conflict (and before a simulator gets booted).
        if outcome.availableSchemes.count >= 2 {
            throw VibeChardError.schemeResolutionAmbiguous(
                available: outcome.availableSchemes
            )
        }
        // Zero schemes / detection unavailable: preserve best-effort
        // fall-through (today's behavior).
        return nil
    }
}
