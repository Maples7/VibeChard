import ArgumentParser
import Foundation
import VibeChardCore

/// `vch clean <name>` — wipe per-task scratch caches without touching
/// git-tracked files or simulator clones. See `CleanService` for the
/// hard rules.
struct CleanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean",
        abstract: "Wipe a task's DerivedData / ModuleCache (and optionally SwiftPM, logs)."
    )

    @Argument(help: "Task name whose scratch caches to clean.",
              completion: .custom(TaskNameCompletion.candidates))
    var name: String

    @Flag(name: .long,
          help: "Also delete the per-task SwiftPM clone cache (`.agent-build/SwiftPM`).")
    var swiftpm: Bool = false

    @Flag(name: .long,
          help: "Also delete `<wt>/.vch/last-test.log` (vch test firehose).")
    var logs: Bool = false

    @Flag(name: .long,
          help: "Equivalent to `--swiftpm --logs`.")
    var all: Bool = false

    @Flag(name: .long,
          help: "Print what would be deleted, but don't delete anything. Skips the busy-process check.")
    var dryRun: Bool = false

    @Flag(name: .long,
          help: "Send SIGTERM to task-scoped stuck `vch test`, `xcodebuild` (build or test), and XCTestDevices host processes before cleaning. Covers `build.db is locked` recovery after an interrupted `vch build`.")
    var killStuckTests: Bool = false

    @Flag(name: .long,
          help: "Emit machine-readable JSON instead of a human-friendly summary.")
    var json: Bool = false

    func run() throws {
        try CLIBridge.run {
            let task = try TaskName(name)
            let cwd = FileManager.default.currentDirectoryPath
            let workspace = try WorkspaceLocator.locate(cwd: cwd)

            let service = CleanService(
                workspace: workspace,
                holderScanner: DiskWorktreeHolderScanner(),
                testProcessScanner: DiskTestSessionProcessScanner(),
                processTerminator: DiskProcessTerminator()
            )
            let options = CleanService.Options(
                includeSwiftPM: swiftpm || all,
                includeLogs:    logs    || all,
                dryRun:         dryRun,
                killStuckTests: killStuckTests
            )
            let result = try service.clean(task: task, options: options)

            if json {
                printJSON(result)
            } else {
                printHuman(result)
            }
        }
    }

    private func printHuman(_ result: CleanService.Result) {
        let prefix = result.dryRun ? "would remove" : "removed"
        let removed = result.removed
        let skipped = result.skipped
        if removed.isEmpty && skipped.isEmpty {
            // Shouldn't happen — targets() always returns at least 2
            // entries — but be safe.
            print("nothing to clean for '\(result.task.raw)'")
            return
        }
        for process in result.terminatedTestProcesses {
            CLIBridge.eprintln("terminated stuck test process: \(process.pid) \(process.kind.rawValue)")
        }
        if removed.isEmpty {
            print("nothing to clean for '\(result.task.raw)' (already empty)")
        } else {
            for path in removed {
                print("\(prefix): \(path)")
            }
        }
        // Always show skipped in dry-run so users can predict the
        // exact effect; in non-dry-run, skipped means "already empty"
        // which the human summary already implies.
        if result.dryRun {
            for path in skipped {
                CLIBridge.eprintln("skip (does not exist): \(path)")
            }
        }
    }

    private func printJSON(_ result: CleanService.Result) {
        struct Payload: Encodable {
            let task: String
            let dryRun: Bool
            let removed: [String]
            let skipped: [String]
            let terminatedStuckTestProcesses: [ProcessJSON]
        }
        struct ProcessJSON: Encodable {
            let pid: Int32
            let kind: String
            let command: String
        }
        let payload = Payload(
            task: result.task.raw,
            dryRun: result.dryRun,
            removed: result.removed,
            skipped: result.skipped,
            terminatedStuckTestProcesses: result.terminatedTestProcesses.map {
                ProcessJSON(pid: $0.pid, kind: $0.kind.rawValue, command: $0.command)
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(payload),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }
}
