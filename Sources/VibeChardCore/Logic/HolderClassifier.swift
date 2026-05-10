import Foundation

/// Classifier for `lsof`-derived process holders inside a vch
/// worktree. (#75)
///
/// The point: when `vch rm` (or `vch prune`) reports "N processes are
/// holding files inside this worktree", a meaningful chunk of those
/// processes are *background* helpers that release their file handles
/// asynchronously after the user has already closed the editor:
/// VS Code's helper farm, `sourcekit-lsp`, the Spotlight indexer,
/// etc. The user has nothing to act on for those entries — they will
/// simply go away on their own.
///
/// We split holders into two buckets:
///
/// - `.background` — known read-only/background helpers. Telling the
///   user "close the editor" doesn't apply; the right hint is
///   "wait a few seconds, or `--force` (safe if `git status` is clean)".
/// - `.interactive` — anything else, conservatively. An open editor
///   PID may still own an unsaved buffer, so we keep the strong
///   "review before forcing" framing for these.
///
/// We deliberately do NOT auto-bypass background holders. That would
/// be a behaviour change disguised as a UX polish, and an
/// allowlist-miss could cost the user data. Classification only
/// changes how the diagnostic is *rendered*; the gate itself still
/// requires the user to type `--force`.
public enum HolderKind: Sendable, Equatable {
    case background
    case interactive
}

public enum HolderClassifier {

    /// Conservative allowlist of process names that are known to
    /// hold worktree files only as part of background indexing /
    /// IPC plumbing. These never own user-edited buffers, so
    /// telling the user "close the editor" makes no sense for them.
    ///
    /// Matching is **substring**, case-sensitive, against the raw
    /// `command` lsof reports. Using substring (rather than equality)
    /// lets a single entry like `"Code Helper (Plugin)"` match the
    /// truncated forms lsof emits on macOS (lsof's `c` field is
    /// limited to 15 chars by default — see `lsof -c +c0` to widen).
    ///
    /// Notable omissions, kept interactive on purpose:
    ///   • `"Code"`, `"Code Helper"` (without a parenthesised role)
    ///     — could be the renderer process for an *open* window;
    ///     unsaved buffers ride here.
    ///   • `"Cursor"`, `"Cursor Helper"` — same reasoning as VS Code.
    ///   • `"Xcode"`, `"vim"`, `"nvim"`, `"subl"`, `"emacs"` — always
    ///     interactive.
    ///   • shells (`"zsh"`, `"bash"`, `"fish"`) — a `cd`'d shell is
    ///     a low-risk holder, but the user *can* act on it
    ///     (close the tab) so the interactive framing still applies.
    public static let backgroundCommandTokens: [String] = [
        // VS Code helper farm — these are renderers/plugin hosts
        // that don't own the foreground editor's buffer state.
        "Code Helper (Plugin)",
        "Code Helper (Renderer)",
        "Code Helper (GPU)",

        // Cursor uses the same Electron helper architecture as VS Code.
        "Cursor Helper (Plugin)",
        "Cursor Helper (Renderer)",
        "Cursor Helper (GPU)",

        // Apple language services. SourceKit holds files open while
        // indexing a SwiftPM workspace; closing the editor doesn't
        // shut these down immediately.
        "sourcekit-lsp",
        "SourceKitService",

        // Spotlight + iCloud + FSEvents background plumbing.
        "mdworker_shared",
        "mdworker",
        "mds_stores",
        "mds",
        "fseventsd",
        "bird",
        "cloudd",

        // Cross-language LSPs. If any of these is the only thing
        // pinning the worktree, the user can't act on it any more
        // than they can act on sourcekit-lsp.
        "clangd",
        "rust-analyzer",
        "gopls",
        "pyright-langserver",
        "typescript-language-server",
        "tsserver",
    ]

    /// Classify a single holder by its `command` string.
    public static func classify(command: String) -> HolderKind {
        for token in backgroundCommandTokens where command.contains(token) {
            return .background
        }
        return .interactive
    }

    /// Classify every holder in `holders`, preserving input order.
    /// Returned tuples carry the original `WorktreeHolder` so the
    /// caller can render PID / sample path without a second lookup.
    public static func classify(_ holders: [WorktreeHolder]) -> [(WorktreeHolder, HolderKind)] {
        holders.map { ($0, classify(command: $0.command)) }
    }
}
