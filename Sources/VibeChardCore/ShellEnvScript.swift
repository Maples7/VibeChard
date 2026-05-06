import Foundation

/// `vch shellenv` output: shell function definitions that callers
/// can install with `eval "$(vch shellenv)"`.
///
/// Why functions and not aliases?
///   • `cd` cannot be done from a child process — must be a shell
///     function in the parent shell.
///   • Functions also let us add small ergonomics (like quoting the
///     resolved path) without exposing implementation details.
///
/// The output is intentionally bash/zsh compatible. Fish gets its
/// own emit later (M7).
public enum ShellEnvScript {

    public static let header = """
    # vch shell helpers — installed by `eval "$(vch shellenv)"`.
    # Safe to source repeatedly.
    """

    public static let zshBash: String = """
    \(header)

    # Resolve and `cd` into a vch-managed worktree:
    #   vch_cd <task-name>
    vch_cd() {
        if [ -z "$1" ]; then
            printf 'usage: vch_cd <task-name>\\n' >&2
            return 2
        fi
        local _vch_path
        _vch_path="$(command vch path "$1")" || return $?
        cd "$_vch_path"
    }

    # Create a new vch worktree and cd into it. Forwards all flags to
    # `vch new`, so `vch_new fix --base main --copy-untracked` works.
    # When --exec is requested, vch execve's into the agent and cd is
    # not meaningful — we delegate transparently in that case.
    #   vch_new <task-name> [--base <ref>] [--copy-untracked] [--exec <cmd>]
    vch_new() {
        local _arg
        for _arg in "$@"; do
            case "$_arg" in
                --exec|--exec=*)
                    command vch new "$@"
                    return $?
                    ;;
            esac
        done
        local _vch_path
        _vch_path="$(command vch new "$@")" || return $?
        cd "$_vch_path"
    }

    # Wipe the current worktree's .agent-build/ scratch dir.
    # Run from inside the worktree.
    vch_clean() {
        if [ ! -d "$PWD/.vch" ]; then
            printf 'vch_clean: not a vch worktree (no .vch/ at %s)\\n' "$PWD" >&2
            return 1
        fi
        rm -rf "$PWD/.agent-build" && printf 'cleaned %s/.agent-build\\n' "$PWD"
    }
    """
}
