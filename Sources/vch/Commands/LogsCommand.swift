import ArgumentParser
import Foundation
import VibeChardCore

/// `vch logs <name>` — print the firehose log preserved during the
/// most recent `vch test` (#9) or `vch build` (#48) run. Logs live at
/// `<wt>/.vch/last-test.log` and `<wt>/.vch/last-build.log`
/// respectively and are overwritten every run.
struct LogsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Print the full xcodebuild log from a task's most recent run."
    )

    @Argument(help: "Task name to inspect.",
              completion: .custom(TaskNameCompletion.candidates))
    var name: String

    @Flag(name: .long,
          help: "Print the last `vch test` log (default when neither --test nor --build is passed).")
    var test: Bool = false

    @Flag(name: .long,
          help: "Print the last `vch build` log.")
    var build: Bool = false

    func run() throws {
        try CLIBridge.run {
            if test && build {
                throw VibeChardError.missingArgument(
                    "--test and --build are mutually exclusive"
                )
            }
            let task = try TaskName(name)
            let cwd = FileManager.default.currentDirectoryPath
            let workspace = try WorkspaceLocator.locate(cwd: cwd)
            let logPath = build
                ? workspace.lastBuildLogPath(for: task)
                : workspace.lastTestLogPath(for: task)
            let url = URL(fileURLWithPath: logPath)
            guard FileManager.default.fileExists(atPath: logPath) else {
                let cmd = build ? "vch build" : "vch test"
                throw VibeChardError.logFileMissing(
                    path: logPath,
                    hint: "run `\(cmd) \(task.raw)` first"
                )
            }
            let data = try Data(contentsOf: url)
            FileHandle.standardOutput.write(data)
        }
    }
}
