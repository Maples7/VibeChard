import SystemPackage

/// Lexical path-joining utilities backed by `swift-system`'s `FilePath`.
///
/// vch represents paths as `String` throughout (`Workspace`, the
/// `FileSystem` protocol, on-disk state JSON, CLI output) because the
/// boundary is overwhelmingly stringly-typed: `git`, `xcodebuild`,
/// `xcrun simctl`, environment variables, command-line arguments, and
/// `Foundation.URL` all consume or produce strings. Migrating those
/// boundaries to a strongly-typed path everywhere would ripple through
/// every callsite for marginal benefit.
///
/// What we *can* avoid is the ad-hoc `"\(base)/\(rel)"` interpolation
/// pattern, which silently does the wrong thing if `base` ends with a
/// slash, `rel` starts with one, or either contains `..`. `PathOps`
/// routes every internal join through `FilePath`, which normalizes
/// slashes lexically (without touching disk).
///
/// Note: `FilePath.appending(_:)` treats an absolute `component` as a
/// replacement for `base` (the same way the shell's `cd /foo /bar`
/// would land in `/bar`). All call sites in this module pass relative
/// components, which is the only sane use here. Empty components are
/// skipped.
enum PathOps {
    /// Join `base` with one or more relative components, returning
    /// the lexically normalized path as a `String`.
    static func join(_ base: String, _ components: String...) -> String {
        var fp = FilePath(base)
        for component in components where !component.isEmpty {
            fp.append(component)
        }
        return fp.string
    }
}
