import ArgumentParser
import Foundation
import VibeChardCore

/// `vch logs <name> --test` — print the firehose log preserved during
/// the most recent `vch test` run (#9). The log lives at
/// `<wt>/.vch/last-test.log` and is overwritten every run.
///
/// Currently only `--test` is supported; `--build` is reserved for a
/// follow-up that tees `xcodebuild build` output the same way.
struct LogsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Print the full xcodebuild log from a task's most recent run."
    )

    @Argument(help: "Task name to inspect.",
              completion: .custom(TaskNameCompletion.candidates))
    var name: String

    @Flag(name: .long,
          help: "Print the last `vch test` log (default).")
    var test: Bool = false

    func run() throws {
        try CLIBridge.run {
            let task = try TaskName(name)
            let cwd = FileManager.default.currentDirectoryPath
            let workspace = try WorkspaceLocator.locate(cwd: cwd)
            // Currently `--test` is the only flavor; if neither flag
            // was passed default to test (matches the issue's CLI
            // sketch). When --build lands we'll require the user to
            // pick exactly one.
            _ = test
            let logPath = workspace.lastTestLogPath(for: task)
            let url = URL(fileURLWithPath: logPath)
            guard FileManager.default.fileExists(atPath: logPath) else {
                throw VibeChardError.logFileMissing(
                    path: logPath,
                    hint: "run `vch test \(task.raw)` first"
                )
            }
            let data = try Data(contentsOf: url)
            FileHandle.standardOutput.write(data)
        }
    }
}
