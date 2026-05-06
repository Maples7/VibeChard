import Foundation

/// `vch completions install` (Q-amend, post-v0.1.1).
///
/// Pure planning layer for the `completions install` subcommand. The
/// CLI shell decides where the script comes from (ArgumentParser's
/// `--generate-completion-script <shell>`) and what to do with the
/// resulting `Plan` — write the file, prompt, etc. This file is
/// IO-free so behavior is exhaustively unit-testable.
public enum CompletionShell: String, CaseIterable, Sendable {
    case zsh
    case bash
    case fish

    /// Detect the user's shell from `$SHELL`. Returns `nil` if the
    /// value is missing or doesn't end in a known shell name.
    public static func detect(shellEnv: String?) -> CompletionShell? {
        guard let raw = shellEnv?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        // `$SHELL` is typically an absolute path like `/bin/zsh` or
        // `/opt/homebrew/bin/fish`. Take the basename.
        let leaf = (raw as NSString).lastPathComponent.lowercased()
        switch leaf {
        case "zsh": return .zsh
        case "bash": return .bash
        case "fish": return .fish
        default: return nil
        }
    }
}

/// Where to install a completion script + a hint to print after
/// success so the user knows what (if anything) to add to their rc.
public struct CompletionsInstallPlan: Equatable, Sendable {
    public let shell: CompletionShell
    /// Absolute target path the caller must write the script to.
    public let targetPath: String
    /// Human-readable instructions for the user's rc (zsh `fpath`,
    /// etc.). May be empty when no further setup is required.
    public let postInstallHint: String

    public init(shell: CompletionShell, targetPath: String, postInstallHint: String) {
        self.shell = shell
        self.targetPath = targetPath
        self.postInstallHint = postInstallHint
    }
}

public enum CompletionsInstaller {

    /// Build an install plan for `shell` rooted at `home`. Pure;
    /// returns the destination path and an after-install hint.
    public static func plan(
        shell: CompletionShell,
        home: String
    ) -> CompletionsInstallPlan {
        let normalizedHome = stripTrailingSlash(home)
        switch shell {
        case .zsh:
            // Convention: `~/.zsh/completions/_vch`. We deliberately
            // do NOT touch the user's `.zshrc` — printing the snippet
            // is enough; auto-edit is invasive and out of scope per
            // AGENTS.md rule #7 ("no config-file writes" spirit).
            let dir = "\(normalizedHome)/.zsh/completions"
            return CompletionsInstallPlan(
                shell: .zsh,
                targetPath: "\(dir)/_vch",
                postInstallHint: """
                Add this once to your ~/.zshrc (if not already present):

                    fpath=(\(dir) $fpath)
                    autoload -Uz compinit && compinit
                """
            )
        case .bash:
            // Standard XDG-ish location used by bash-completion v2.
            let dir = "\(normalizedHome)/.local/share/bash-completion/completions"
            return CompletionsInstallPlan(
                shell: .bash,
                targetPath: "\(dir)/vch",
                postInstallHint: """
                If `vch <Tab>` does not work, ensure bash-completion is
                installed and sourced in your ~/.bashrc:

                    [ -f /opt/homebrew/etc/profile.d/bash_completion.sh ] \\
                        && . /opt/homebrew/etc/profile.d/bash_completion.sh
                """
            )
        case .fish:
            let dir = "\(normalizedHome)/.config/fish/completions"
            return CompletionsInstallPlan(
                shell: .fish,
                targetPath: "\(dir)/vch.fish",
                postInstallHint: ""  // fish auto-loads from this dir.
            )
        }
    }

    private static func stripTrailingSlash(_ s: String) -> String {
        // We always concatenate with a leading `/` afterwards, so for
        // the filesystem-root edge case we must return "" — otherwise
        // we'd emit `//.zsh/...` (still valid POSIX, but ugly and
        // surprises tests).
        if s == "/" { return "" }
        var out = s
        while out.hasSuffix("/") && out.count > 1 {
            out.removeLast()
        }
        return out
    }
}
