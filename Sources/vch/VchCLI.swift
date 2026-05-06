import ArgumentParser
import Foundation
import VibeChardCore

@main
struct VchCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vch",
        abstract: VibeChard.tagline,
        version: VibeChard.version,
        subcommands: [
            VersionCommand.self,
            NewCommand.self,
            ListCommand.self,
            PathCommand.self,
            RemoveCommand.self,
            RepairCommand.self,
            ExecCommand.self,
            ShellEnvCommand.self,
            BuildCommand.self,
            TestCommand.self,
            // M6 commands:
            SimCommand.self,
            DoctorCommand.self,
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
