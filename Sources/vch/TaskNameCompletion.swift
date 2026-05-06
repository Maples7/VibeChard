import ArgumentParser
import Foundation
import VibeChardCore

/// Backs the `.custom` shell-completion handler for every `@Argument`
/// that takes a task name. ArgumentParser invokes a hidden
/// subcommand of vch when the user hits TAB, which means this code
/// runs *inside* the same `vch` binary the user installed — full
/// access to Core, no subprocesses required.
enum TaskNameCompletion {
    /// Hand back every known task name in the workspace, sorted.
    /// Best-effort: any failure (cwd not in a git repo, simctl
    /// flakiness, etc.) just returns an empty list so shell
    /// completion falls back to its default behavior instead of
    /// crashing the user's TAB cycle.
    ///
    /// Signature matches argument-parser 1.5's three-parameter
    /// `.custom` shape: `(argv, index, partialToken) -> candidates`.
    /// We don't currently use any of those — completing a task name
    /// is context-free — so the parameters are ignored.
    static let candidates: @Sendable ([String], Int, String) -> [String] = { _, _, _ in
        do {
            let cwd = FileManager.default.currentDirectoryPath
            let workspace = try WorkspaceLocator.locate(cwd: cwd)
            let service = TaskService(workspace: workspace, git: DiskGitClient())
            let summaries = try service.listTasks()
            return summaries.map(\.name).sorted()
        } catch {
            return []
        }
    }
}
