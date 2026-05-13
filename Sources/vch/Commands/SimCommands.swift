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
        abstract: "Force-create a per-task simulator clone now (idempotent)."
    )

    @Argument(help: "Task name.",
              completion: .custom(TaskNameCompletion.candidates))
    var name: String

    @Option(name: .long, help: "Simulator device template (e.g. \"iPhone 16\"). Required when the task has no clone yet, or when adding a second platform binding.")
    var device: String?

    @Option(name: .long, help: "Pin the runtime version when cloning (e.g. \"18.0\"). Optional, but combined with --device it lets a task bind the same device across multiple OS versions.")
    var runtime: String?

    func run() throws {
        try CLIBridge.run {
            let task = try TaskName(name)
            let cwd = FileManager.default.currentDirectoryPath
            let workspace = try WorkspaceLocator.locate(cwd: cwd)
            let sim = SimulatorService(
                workspace: workspace, simctl: DiskSimctlClient()
            )

            // Multi-binding aware path (#99). When --device is
            // omitted: 0 bindings → require --device; 1 binding →
            // idempotent reuse; ≥2 bindings → ambiguous error from
            // ensureClone forces the user to pass --device.
            //
            // When --device is set: ensureClone reuses an exact
            // device+runtime match, or appends a new binding when
            // none matches. The previous "task is already bound"
            // error mode is gone — that was the bug #99 reported.
            let existing = try sim.lookupAllBindings(task: task)
            let deviceMissing = (device ?? "").isEmpty
            if deviceMissing, existing.isEmpty {
                throw VibeChardError.missingArgument(
                    "--device (no clone is bound to '\(task.raw)' yet)"
                )
            }
            guard let resolved = try sim.ensureClone(
                task: task,
                requestedDevice: device,
                requestedRuntime: runtime
            ) else {
                // Unreachable: ensureClone only returns nil when
                // both --device is unset AND there are zero bindings,
                // which we already guarded above.
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
        abstract: "Shut down and erase a bound clone (state binding is preserved)."
    )

    @Argument(help: "Task name.",
              completion: .custom(TaskNameCompletion.candidates))
    var name: String

    @Option(name: .long, help: "Select which binding to erase when the task has multiple platform clones. Optional with a single binding.")
    var device: String?

    @Option(name: .long, help: "Disambiguate when two bindings share a device but pin different runtimes.")
    var runtime: String?

    func run() throws {
        try CLIBridge.run {
            let task = try TaskName(name)
            let cwd = FileManager.default.currentDirectoryPath
            let workspace = try WorkspaceLocator.locate(cwd: cwd)
            let sim = SimulatorService(
                workspace: workspace, simctl: DiskSimctlClient()
            )
            guard let bound = try sim.resolveBindingForCLI(
                task: task, device: device, runtime: runtime
            ) else {
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
        abstract: "Shut down a bound clone (idempotent)."
    )

    @Argument(help: "Task name.",
              completion: .custom(TaskNameCompletion.candidates))
    var name: String

    @Option(name: .long, help: "Select which binding to shut down when the task has multiple platform clones. Optional with a single binding.")
    var device: String?

    @Option(name: .long, help: "Disambiguate when two bindings share a device but pin different runtimes.")
    var runtime: String?

    func run() throws {
        try CLIBridge.run {
            let task = try TaskName(name)
            let cwd = FileManager.default.currentDirectoryPath
            let workspace = try WorkspaceLocator.locate(cwd: cwd)
            let sim = SimulatorService(
                workspace: workspace, simctl: DiskSimctlClient()
            )
            guard let bound = try sim.resolveBindingForCLI(
                task: task, device: device, runtime: runtime
            ) else {
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
        abstract: "Print bound clone records + live simctl state."
    )

    @Argument(help: "Task name.",
              completion: .custom(TaskNameCompletion.candidates))
    var name: String

    @Option(name: .long, help: "Select which binding to inspect when the task has multiple platform clones. Omit to print every binding.")
    var device: String?

    @Option(name: .long, help: "Disambiguate when two bindings share a device but pin different runtimes.")
    var runtime: String?

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

            // Multi-binding (#99): default behaviour prints every
            // clone the task owns. Passing `--device` (and
            // optionally `--runtime`) narrows to one. Empty state
            // continues to print the "bound clone: (none)" line.
            let bindings: [TaskState.SimulatorRecord]
            if device != nil || runtime != nil {
                if let one = try sim.resolveBindingForCLI(
                    task: task, device: device, runtime: runtime
                ) {
                    bindings = [one]
                } else {
                    bindings = []
                }
            } else {
                bindings = try sim.lookupAllBindings(task: task)
            }

            guard !bindings.isEmpty else {
                if json {
                    try printJSON(SimInfoRenderer.Payload(task: task.raw, bindings: []))
                } else {
                    print("task:        \(task.raw)")
                    print("bound clone: (none)")
                }
                return
            }

            // Build rows once; both branches consume them. Each row
            // costs one simctl `info` call so we don't want to do
            // them twice.
            var rows: [SimInfoRenderer.BindingRow] = []
            rows.reserveCapacity(bindings.count)
            for bound in bindings {
                let live = try sim.info(udid: bound.cloneUDID)
                rows.append(SimInfoRenderer.makeRow(record: bound, live: live))
            }

            if json {
                try printJSON(SimInfoRenderer.Payload(task: task.raw, bindings: rows))
            } else {
                print("task:        \(task.raw)")
                for (idx, row) in rows.enumerated() {
                    if rows.count > 1 {
                        print("--- binding \(idx + 1) of \(rows.count) ---")
                    }
                    print("clone UDID:  \(row.cloneUDID)")
                    print("source UDID: \(row.sourceUDID)")
                    print("name:        \(row.name)")
                    if let tmpl = row.templateName {
                        print("template:    \(tmpl)")
                    }
                    if let rt = row.runtimeIdentifier {
                        print("runtime:     \(rt)")
                    }
                    print("state:       \(row.state)")
                }
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
