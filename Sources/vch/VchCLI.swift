import ArgumentParser
import Foundation
import VibeChardCore

@main
struct VchCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vch",
        abstract: VibeChard.tagline,
        version: VibeChard.version,
        // Order here drives `vch --help`. Group by user workflow:
        // create → discover → inspect → run → build/test → graduate
        // → maintenance → meta. Most users will encounter the list
        // top-down, so high-frequency commands lead.
        subcommands: [
            // Lifecycle: spawn, list, inspect, locate, open.
            NewCommand.self,
            ListCommand.self,
            StateCommand.self,
            PathCommand.self,
            OpenCommand.self,
            // Run things inside a task worktree.
            ExecCommand.self,
            BuildCommand.self,
            TestCommand.self,
            RunCommand.self,
            LogsCommand.self,
            SimCommand.self,
            // Graduate a task: refresh against base, merge + cleanup,
            // or just remove.
            SyncCommand.self,
            LandCommand.self,
            RemoveCommand.self,
            PruneCommand.self,
            // Maintenance / diagnostics.
            CleanCommand.self,
            RepairCommand.self,
            DoctorCommand.self,
            // Shell integration + meta.
            ShellEnvCommand.self,
            CompletionsCommand.self,
            VersionCommand.self,
        ],
        defaultSubcommand: nil
    )

    /// `@main` entry point. We override the default `parseAsRoot()`
    /// dispatch so that `vch <task-name>` (Q9 entry #5 — sugar for
    /// `vch exec <name> -- $SHELL`) routes correctly, while every
    /// other invocation flows through ArgumentParser unchanged.
    static func main() {
        let argv = Array(CommandLine.arguments.dropFirst())
        let env = ProcessInfo.processInfo.environment

        let effective = TaskShortcutDispatcher.rewriteIfSugar(argv, env: env) ?? argv

        do {
            var command = try parseAsRoot(effective)
            try command.run()
        } catch {
            // #86 / #89: when ArgumentParser rejects a `vch <build|
            // test|run>` invocation with `.validationFailure`, decide
            // whether to append a hint pointing at the right pass-
            // through invocation shape. Two layers, in priority order:
            //
            //   1. Specific (test-only, #86): argv contains a known
            //      xcodebuild flag spelling (`-testPlan`,
            //      `-resultBundlePath`, …) → suggest the canonical
            //      single-dash xcodebuild form (or, for flags vch
            //      has promoted to first-class, the double-dash vch
            //      form).
            //   2. Generic (#89): user wrote an option vch doesn't
            //      know (`--extra`) and AP didn't propose a typo
            //      correction → suggest the pass-through shape with
            //      wording matching the downstream tool (xcodebuild
            //      for build/test, the launched app for run).
            //
            // Gated on `validationFailure` so runtime errors thrown
            // from a subcommand's `run()` (different exit code) don't
            // also drag in the hint.
            if Self.exitCode(for: error) == .validationFailure,
               let commandToken = effective.first,
               let downstream = XcodebuildPassthroughHint
                .downstream(forCommand: commandToken) {
                let argv = Array(effective.dropFirst())
                let errorMessage = Self.fullMessage(for: error)
                let specific: String? = commandToken == "test"
                    ? XcodebuildPassthroughHint.hintForTestArgv(argv)
                    : nil
                let generic: String? = specific != nil ? nil
                    : XcodebuildPassthroughHint.genericUnknownOptionHint(
                        command: commandToken,
                        errorMessage: errorMessage,
                        downstream: downstream
                    )
                if let hint = specific ?? generic {
                    // Print ArgumentParser's own error+usage first
                    // (it's the concrete diagnostic), then our hint
                    // as the actionable trailer.
                    FileHandle.standardError.write(
                        Data((errorMessage + "\n").utf8)
                    )
                    FileHandle.standardError.write(Data((hint + "\n").utf8))
                    Foundation.exit(Self.exitCode(for: error).rawValue)
                }
            }
            exit(withError: error)
        }
    }
}

// MARK: - vch version

struct VersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Print vch and Apple toolchain versions."
    )

    @Flag(name: .long, help: "Emit machine-readable JSON.")
    var json: Bool = false

    func run() throws {
        let info = ToolchainInfo.collect()
        if json {
            try info.printJSON()
        } else {
            info.printHuman()
        }
    }
}

private struct ToolchainInfo: Encodable {
    let vch: String
    let xcodebuild: String
    let swift: String

    static func collect() -> ToolchainInfo {
        ToolchainInfo(
            vch: VibeChard.version,
            xcodebuild: oneLine(["/usr/bin/xcrun", "xcodebuild", "-version"])
                ?? "unavailable",
            swift: oneLine(["/usr/bin/xcrun", "swift", "--version"])
                ?? "unavailable"
        )
    }

    func printHuman() {
        print("vch        \(vch)")
        print("xcodebuild \(xcodebuild)")
        print("swift      \(swift)")
    }

    func printJSON() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        if let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }
}

/// Run an external command and return the first line of its stdout, or nil
/// if the command fails or is unavailable.
private func oneLine(_ argv: [String]) -> String? {
    guard let first = argv.first, !first.isEmpty else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: first)
    process.arguments = Array(argv.dropFirst())
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
    } catch {
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
          let str = String(data: data, encoding: .utf8) else {
        return nil
    }
    return str.split(whereSeparator: \.isNewline).first.map(String.init)
}
