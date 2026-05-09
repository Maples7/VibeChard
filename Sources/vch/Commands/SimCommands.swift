import ArgumentParser
import Foundation
import VibeChardCore

// MARK: - vch sim (parent)

/// `vch sim` is a parent command grouping the four explicit simulator
/// verbs from Q9, plus the warm-template management subgroup added
/// for #47. None of the per-task verbs are needed for the day-to-day
/// "build + test" flow (M5's lazy clone covers that); they exist for
/// setup scripts and recovery. The `warm-template` subgroup manages
/// shared, lifetime-decoupled simulator templates whose first-boot
/// caches are pre-primed.
struct SimCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sim",
        abstract: "Manage the per-task simulator clone.",
        subcommands: [
            SimCloneCommand.self,
            SimEraseCommand.self,
            SimShutdownCommand.self,
            SimInfoCommand.self,
            SimWarmTemplateCommand.self,
        ]
    )
}

// MARK: - vch sim clone

struct SimCloneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clone",
        abstract: "Force-create the per-task simulator clone now (idempotent)."
    )

    @Argument(help: "Task name.",
              completion: .custom(TaskNameCompletion.candidates))
    var name: String

    @Option(name: .long, help: "Simulator device template (e.g. \"iPhone 16\"). Required when no clone is bound yet.")
    var device: String?

    func run() throws {
        try CLIBridge.run {
            let task = try TaskName(name)
            let cwd = FileManager.default.currentDirectoryPath
            let workspace = try WorkspaceLocator.locate(cwd: cwd)
            let sim = SimulatorService(
                workspace: workspace, simctl: DiskSimctlClient()
            )

            // If a clone exists, --device is optional; if it's set we
            // delegate to ensureClone so the simulatorAlreadyBound
            // mismatch rule applies uniformly.
            if let bound = try sim.lookupBound(task: task), device == nil {
                print("\(bound.name)\t\(bound.cloneUDID)")
                CLIBridge.eprintln("→ already cloned (no-op)")
                return
            }

            guard let device, !device.isEmpty else {
                throw VibeChardError.missingArgument(
                    "--device (no clone is bound to '\(task.raw)' yet)"
                )
            }
            guard let resolved = try sim.ensureClone(task: task, requestedDevice: device) else {
                // Should never happen: we always pass a device above.
                throw VibeChardError.missingArgument("--device")
            }
            print("\(resolved.name)\t\(resolved.udid)")
            if resolved.createdNow {
                CLIBridge.eprintln("→ cloned simulator '\(resolved.name)' (\(resolved.udid.prefix(8))…)")
            } else {
                CLIBridge.eprintln("→ already cloned (no-op)")
            }
        }
    }
}

// MARK: - vch sim erase

struct SimEraseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "erase",
        abstract: "Shut down and erase the bound clone (state binding is preserved)."
    )

    @Argument(help: "Task name.",
              completion: .custom(TaskNameCompletion.candidates))
    var name: String

    func run() throws {
        try CLIBridge.run {
            let task = try TaskName(name)
            let cwd = FileManager.default.currentDirectoryPath
            let workspace = try WorkspaceLocator.locate(cwd: cwd)
            let sim = SimulatorService(
                workspace: workspace, simctl: DiskSimctlClient()
            )
            guard let bound = try sim.lookupBound(task: task) else {
                throw VibeChardError.missingArgument(
                    "task '\(task.raw)' has no simulator clone (run `vch build` or `vch sim clone`)"
                )
            }
            CLIBridge.eprintln("→ shutting down '\(bound.name)' …")
            try sim.eraseClone(udid: bound.cloneUDID)
            CLIBridge.eprintln("→ erased '\(bound.name)'")
        }
    }
}

// MARK: - vch sim shutdown

struct SimShutdownCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shutdown",
        abstract: "Shut down the bound clone (idempotent)."
    )

    @Argument(help: "Task name.",
              completion: .custom(TaskNameCompletion.candidates))
    var name: String

    func run() throws {
        try CLIBridge.run {
            let task = try TaskName(name)
            let cwd = FileManager.default.currentDirectoryPath
            let workspace = try WorkspaceLocator.locate(cwd: cwd)
            let sim = SimulatorService(
                workspace: workspace, simctl: DiskSimctlClient()
            )
            guard let bound = try sim.lookupBound(task: task) else {
                throw VibeChardError.missingArgument(
                    "task '\(task.raw)' has no simulator clone"
                )
            }
            try sim.shutdown(udid: bound.cloneUDID)
            CLIBridge.eprintln("→ shutdown '\(bound.name)'")
        }
    }
}

// MARK: - vch sim info

struct SimInfoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Print the bound clone's record + live simctl state."
    )

    @Argument(help: "Task name.",
              completion: .custom(TaskNameCompletion.candidates))
    var name: String

    @Flag(name: .long, help: "Emit machine-readable JSON.")
    var json: Bool = false

    func run() throws {
        try CLIBridge.run {
            let task = try TaskName(name)
            let cwd = FileManager.default.currentDirectoryPath
            let workspace = try WorkspaceLocator.locate(cwd: cwd)
            let sim = SimulatorService(
                workspace: workspace, simctl: DiskSimctlClient()
            )

            guard let bound = try sim.lookupBound(task: task) else {
                if json {
                    let payload: [String: String?] = [
                        "task": task.raw,
                        "bound": nil
                    ]
                    try printJSON(payload)
                } else {
                    print("task:        \(task.raw)")
                    print("bound clone: (none)")
                }
                return
            }
            let live = try sim.info(udid: bound.cloneUDID)
            let liveState = live?.state ?? (live == nil ? "(missing — run `vch doctor`)" : "(unknown)")

            if json {
                struct InfoJSON: Encodable {
                    let task: String
                    let cloneUDID: String
                    let sourceUDID: String
                    let name: String
                    let state: String
                    let presentInSimctl: Bool
                }
                let payload = InfoJSON(
                    task: task.raw,
                    cloneUDID: bound.cloneUDID,
                    sourceUDID: bound.sourceUDID,
                    name: bound.name,
                    state: liveState,
                    presentInSimctl: live != nil
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(payload)
                if let str = String(data: data, encoding: .utf8) { print(str) }
            } else {
                print("task:        \(task.raw)")
                print("clone UDID:  \(bound.cloneUDID)")
                print("source UDID: \(bound.sourceUDID)")
                print("name:        \(bound.name)")
                print("state:       \(liveState)")
            }
        }
    }
}

// MARK: - helpers

private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    if let str = String(data: data, encoding: .utf8) { print(str) }
}
