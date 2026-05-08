import ArgumentParser
import Foundation
import VibeChardCore

// `VibeChardCore.CompletionShell` collides by name with
// `ArgumentParser.CompletionShell`. The local typealias gives us
// short, unambiguous names inside this file.
private typealias VCHShell = VibeChardCore.CompletionShell
private typealias APShell = ArgumentParser.CompletionShell

// MARK: - vch completions

struct CompletionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "completions",
        abstract: "Manage shell completion scripts.",
        subcommands: [CompletionsInstallCommand.self],
        defaultSubcommand: CompletionsInstallCommand.self
    )
}

struct CompletionsInstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install the shell completion script for the current shell."
    )

    @Option(
        name: .shortAndLong,
        help: ArgumentHelp(
            "Target shell. Auto-detected from $SHELL when omitted.",
            discussion: "One of: zsh, bash, fish."
        )
    )
    var shell: String?

    @Flag(name: .long, help: "Print the resolved install path and script to stdout instead of writing.")
    var print: Bool = false

    @Flag(name: .long, help: "Overwrite an existing completion script if present.")
    var force: Bool = false

    func run() throws {
        try CLIBridge.run {
            let resolvedShell = try resolveShell()
            let home = NSHomeDirectory()
            let plan = CompletionsInstaller.plan(shell: resolvedShell, home: home)
            let script = VchCLI.completionScript(for: apShell(for: resolvedShell))

            if self.print {
                Swift.print("# install path: \(plan.targetPath)")
                Swift.print(script)
                if !plan.postInstallHint.isEmpty {
                    Swift.print("\n# post-install hint:")
                    for line in plan.postInstallHint.split(separator: "\n") {
                        Swift.print("# \(line)")
                    }
                }
                return
            }

            let fm = FileManager.default
            let dir = (plan.targetPath as NSString).deletingLastPathComponent
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

            if fm.fileExists(atPath: plan.targetPath) && !force {
                CLIBridge.eprintln("vch: completion script already exists at \(plan.targetPath)")
                CLIBridge.eprintln("    pass --force to overwrite")
                throw ArgumentParser.ExitCode(ExitCode.business)
            }

            try Data(script.utf8).write(
                to: URL(fileURLWithPath: plan.targetPath),
                options: .atomic
            )
            Swift.print("installed \(resolvedShell.rawValue) completion → \(plan.targetPath)")
            if !plan.postInstallHint.isEmpty {
                Swift.print("")
                Swift.print(plan.postInstallHint)
            }
        }
    }

    private func resolveShell() throws -> VCHShell {
        if let raw = shell?.lowercased() {
            guard let s = VCHShell(rawValue: raw) else {
                throw VibeChardError.invalidTaskName(
                    raw,
                    reason: "unsupported shell '\(raw)' (expected: zsh, bash, fish)"
                )
            }
            return s
        }
        let env = ProcessInfo.processInfo.environment
        guard let detected = VCHShell.detect(shellEnv: env["SHELL"]) else {
            throw VibeChardError.missingArgument(
                "could not detect shell from $SHELL; pass --shell zsh|bash|fish"
            )
        }
        return detected
    }

    private func apShell(for s: VCHShell) -> APShell {
        switch s {
        case .zsh: return .zsh
        case .bash: return .bash
        case .fish: return .fish
        }
    }
}
