import Foundation

/// Pre-computed launch description for the child process that
/// `vch exec <name> -- <cmd...>` (and its sugar `vch <name>`) wants to
/// spawn. Pure value type — produced by `ExecService`, consumed by the
/// CLI layer which actually `Process.run()`s it.
///
/// Keeping launch logic out of `VibeChardCore` lets us unit-test the
/// "what env does the child see / what symlinks land in `.vch/bin`"
/// decisions without touching the OS.
public struct ExecPlan: Equatable, Sendable {
    public let cwd: String
    public let argv: [String]
    public let env: [String: String]
    public let installedShimSymlinks: [String]

    public init(
        cwd: String,
        argv: [String],
        env: [String: String],
        installedShimSymlinks: [String]
    ) {
        self.cwd = cwd
        self.argv = argv
        self.env = env
        self.installedShimSymlinks = installedShimSymlinks
    }
}
