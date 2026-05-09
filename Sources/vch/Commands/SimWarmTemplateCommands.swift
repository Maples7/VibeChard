import ArgumentParser
import Foundation
import VibeChardCore

// MARK: - vch sim warm-template (parent)

/// `vch sim warm-template` — user-managed simulator templates whose
/// first-boot caches have been primed (#47). Cloning per-task sims
/// from a warm template skips ~21 s of first-boot work versus
/// `simctl create` from an Apple template (measured: 30.75 s → 9.41 s
/// median for iPhone 16 + iOS 26.4, N=5; see PR #47 SPIKE).
///
/// Three verbs only in v1: `create`, `list`, `remove`. No `--all`,
/// no `recreate`; the user opts in explicitly per `(device, runtime)`
/// pair. Lifetime is decoupled from any task — `vch remove` and
/// `vch doctor --clean` never touch warm templates. See AGENTS.md
/// hard rule #9.
struct SimWarmTemplateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "warm-template",
        abstract: "Manage shared, pre-primed simulator templates (#47).",
        subcommands: [
            SimWarmTemplateCreateCommand.self,
            SimWarmTemplateListCommand.self,
            SimWarmTemplateRemoveCommand.self,
        ]
    )
}

// MARK: - vch sim warm-template create

struct SimWarmTemplateCreateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a warm template for <device> + --runtime."
    )

    @Argument(help: "Simulator device template (e.g. \"iPhone 16\", \"Apple Watch Series 10 (46mm)\", \"Apple TV 4K (3rd generation)\", \"Apple Vision Pro\").")
    var device: String

    @Option(name: .long,
            help: "Runtime label (e.g. \"iOS 26.4\", \"watchOS 11.5\", \"tvOS 18.0\", \"visionOS 2.5\"). Required.")
    var runtime: String

    @Flag(name: .long, help: "Suppress the progress notes on stderr.")
    var quiet: Bool = false

    func run() throws {
        try CLIBridge.run {
            let cwd = FileManager.default.currentDirectoryPath
            let workspace = try WorkspaceLocator.locate(cwd: cwd)
            let sim = SimulatorService(
                workspace: workspace, simctl: DiskSimctlClient()
            )
            if !quiet {
                CLIBridge.eprintln("→ creating warm template '\(device)' / \(runtime) …")
                CLIBridge.eprintln("  (this boots once + shuts down to prime first-boot caches)")
            }
            let record = try sim.createWarmTemplate(
                deviceName: device,
                runtimeLabel: runtime
            )
            print("\(record.name)\t\(record.udid)")
            if !quiet {
                CLIBridge.eprintln("→ ready: \(record.name) (\(record.udid.prefix(8))…)")
            }
        }
    }
}

// MARK: - vch sim warm-template list

struct SimWarmTemplateListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List vch-managed warm templates."
    )

    @Flag(name: .long, help: "Emit machine-readable JSON.")
    var json: Bool = false

    func run() throws {
        try CLIBridge.run {
            let cwd = FileManager.default.currentDirectoryPath
            let workspace = try WorkspaceLocator.locate(cwd: cwd)
            let sim = SimulatorService(
                workspace: workspace, simctl: DiskSimctlClient()
            )
            let rows = try sim.listWarmTemplates()
            if json {
                try Self.emitJSON(rows: rows)
            } else {
                Self.emitHuman(rows: rows)
            }
        }
    }

    static func emitHuman(rows: [WarmTemplateRecord]) {
        if rows.isEmpty {
            print("(no warm templates)")
            print("hint: vch sim warm-template create \"iPhone 16\" --runtime \"iOS 26.4\"")
            return
        }
        // Compute column widths for a stable layout.
        var deviceW = "DEVICE".count
        var runtimeW = "RUNTIME".count
        var stateW = "STATE".count
        for r in rows {
            deviceW = max(deviceW, r.deviceName.count)
            runtimeW = max(runtimeW, r.runtimeLabel.count)
            stateW = max(stateW, r.humanHealthLabel.count)
        }
        let header = "\("DEVICE".padding(toLength: deviceW, withPad: " ", startingAt: 0))  "
                   + "\("RUNTIME".padding(toLength: runtimeW, withPad: " ", startingAt: 0))  "
                   + "\("STATE".padding(toLength: stateW, withPad: " ", startingAt: 0))  "
                   + "UDID"
        print(header)
        for r in rows {
            let line = "\(r.deviceName.padding(toLength: deviceW, withPad: " ", startingAt: 0))  "
                     + "\(r.runtimeLabel.padding(toLength: runtimeW, withPad: " ", startingAt: 0))  "
                     + "\(r.humanHealthLabel.padding(toLength: stateW, withPad: " ", startingAt: 0))  "
                     + r.udid
            print(line)
        }
    }

    static func emitJSON(rows: [WarmTemplateRecord]) throws {
        // Schema lives on `WarmTemplateRecord` itself so this output
        // stays byte-identical with `vch doctor --json` and the
        // bug-report tarball's `warm-templates.json`.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(rows)
        if let str = String(data: data, encoding: .utf8) { print(str) }
    }
}

// MARK: - vch sim warm-template remove

struct SimWarmTemplateRemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Shut down and delete a warm template."
    )

    @Argument(help: "Simulator device template name (e.g. \"iPhone 16\", \"Apple Watch Series 10 (46mm)\").")
    var device: String

    @Option(name: .long,
            help: "Runtime label (e.g. \"iOS 26.4\", \"watchOS 11.5\", \"visionOS 2.5\"). Required.")
    var runtime: String

    func run() throws {
        try CLIBridge.run {
            let cwd = FileManager.default.currentDirectoryPath
            let workspace = try WorkspaceLocator.locate(cwd: cwd)
            let sim = SimulatorService(
                workspace: workspace, simctl: DiskSimctlClient()
            )
            try sim.removeWarmTemplate(
                deviceName: device,
                runtimeLabel: runtime
            )
            CLIBridge.eprintln("→ removed warm template '\(device)' / \(runtime)")
        }
    }
}
