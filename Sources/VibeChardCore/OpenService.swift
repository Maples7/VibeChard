import Foundation

/// Pure decision logic for `vch open`. Given the worktree's root file
/// listing plus the user's request (`--with`, env), produces the argv
/// that the CLI shell will spawn via `Process()`.
///
/// Hermetic by design: takes pre-collected directory contents and a
/// `commandExists` probe as inputs, so unit tests don't touch disk
/// or PATH.
public enum OpenService {

    // MARK: - Project detection

    /// What kind of Apple project lives at the root of a worktree.
    /// Used to pick a sensible default IDE and the right argument to
    /// hand to `open`/`xed`.
    public enum ProjectKind: Equatable, Sendable {
        /// `<wt>/<Name>.xcworkspace` exists. Highest priority because
        /// it's typically the right thing to open in Xcode (CocoaPods,
        /// Tuist, multi-project repos).
        case xcworkspace(absolutePath: String)
        /// `<wt>/<Name>.xcodeproj` exists (and no .xcworkspace).
        case xcodeproj(absolutePath: String)
        /// `Package.swift` exists at the root and there's no .xcodeproj
        /// or .xcworkspace. Pure SwiftPM repo.
        case swiftPackage(packageFilePath: String)
        /// None of the above — the worktree is a plain folder. Still
        /// openable in editors, just no Apple-IDE-native target.
        case bareDirectory
    }

    /// Detect the project kind from a directory listing of the worktree
    /// root. Caller passes the leaf names (no trailing slash, no
    /// recursion) — typically from `FileManager.contentsOfDirectory`.
    public static func detectProjectKind(
        rootContents: [String],
        worktreePath: String
    ) -> ProjectKind {
        // Sort for deterministic picks when there are multiple matches
        // (rare, but possible in weirdly-structured repos).
        let sorted = rootContents.sorted()

        if let ws = sorted.first(where: { $0.hasSuffix(".xcworkspace") }) {
            return .xcworkspace(absolutePath: "\(worktreePath)/\(ws)")
        }
        if let proj = sorted.first(where: { $0.hasSuffix(".xcodeproj") }) {
            return .xcodeproj(absolutePath: "\(worktreePath)/\(proj)")
        }
        if sorted.contains("Package.swift") {
            return .swiftPackage(packageFilePath: "\(worktreePath)/Package.swift")
        }
        return .bareDirectory
    }

    // MARK: - IDE selection

    /// IDE that `vch open` will spawn. The white-listed values get
    /// purpose-built command lines; anything else falls through to
    /// `open -a "<appName>"` so users can pick Sublime, Zed, Nova, etc.
    /// without us having to bless each one.
    public enum IDE: Equatable, Sendable {
        /// Open the project in Xcode via `open` (or `open -a Xcode`
        /// for SwiftPM). Always uses Apple-native `LaunchServices`.
        case xcode
        /// VS Code: prefer the `code` CLI (proper window-reuse), fall
        /// back to `open -a "Visual Studio Code"`.
        case vscode
        /// Cursor: prefer the `cursor` CLI, fall back to `open -a Cursor`.
        case cursor
        /// Anything else, e.g. `--with Sublime\ Text`. Spawned as
        /// `open -a "<appName>" <target>`. The string is passed
        /// verbatim to LaunchServices.
        case other(appName: String)

        /// Map a `--with <value>` string to an `IDE`. Aliases are
        /// case-insensitive; unknown values become `.other(value)`.
        public static func parse(_ requested: String) -> IDE {
            switch requested.lowercased() {
            case "xcode":         return .xcode
            case "code", "vscode": return .vscode
            case "cursor":        return .cursor
            default:              return .other(appName: requested)
            }
        }
    }

    /// Pick an `IDE` given the user's choice (if any), the environment
    /// (for `VCH_OPEN_DEFAULT`), and what we detected at the worktree
    /// root.
    ///
    /// Priority:
    ///   1. Explicit `--with <ide>` from the CLI.
    ///   2. `$VCH_OPEN_DEFAULT` env var.
    ///   3. Auto-detect: .xcworkspace/.xcodeproj → Xcode; else VS Code.
    public static func resolveIDE(
        requested: String?,
        env: [String: String],
        projectKind: ProjectKind
    ) -> IDE {
        if let r = requested?.trimmingCharacters(in: .whitespaces),
           !r.isEmpty {
            return IDE.parse(r)
        }
        if let envDefault = env["VCH_OPEN_DEFAULT"]?
            .trimmingCharacters(in: .whitespaces),
           !envDefault.isEmpty {
            return IDE.parse(envDefault)
        }

        // Auto-detect.
        switch projectKind {
        case .xcworkspace, .xcodeproj:
            return .xcode
        case .swiftPackage, .bareDirectory:
            // SwiftPM repos are typically driven from VS Code/Cursor
            // these days; users wanting Xcode can pass `--with xcode`.
            return .vscode
        }
    }

    // MARK: - argv assembly

    /// Build the argv to spawn. The caller passes a `commandExists`
    /// probe so we can prefer first-party CLIs (`code`, `cursor`) when
    /// they're on PATH and fall back to `open -a` otherwise.
    public static func buildArgv(
        ide: IDE,
        projectKind: ProjectKind,
        worktreePath: String,
        commandExists: (String) -> Bool
    ) -> [String] {
        switch ide {
        case .xcode:
            // For workspaces/projects, `open <file>` uses LaunchServices
            // to pick Xcode (correct app for those UTIs). For SwiftPM
            // and bare dirs, we explicitly route to Xcode.
            switch projectKind {
            case .xcworkspace(let p), .xcodeproj(let p):
                return ["/usr/bin/open", p]
            case .swiftPackage(let p):
                return ["/usr/bin/open", "-a", "Xcode", p]
            case .bareDirectory:
                return ["/usr/bin/open", "-a", "Xcode", worktreePath]
            }

        case .vscode:
            if commandExists("code") {
                return ["code", worktreePath]
            }
            return ["/usr/bin/open", "-a", "Visual Studio Code", worktreePath]

        case .cursor:
            if commandExists("cursor") {
                return ["cursor", worktreePath]
            }
            return ["/usr/bin/open", "-a", "Cursor", worktreePath]

        case .other(let appName):
            return ["/usr/bin/open", "-a", appName, worktreePath]
        }
    }
}
