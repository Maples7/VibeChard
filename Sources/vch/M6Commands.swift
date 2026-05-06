import ArgumentParser
import Foundation
import VibeChardCore

// MARK: - vch sim (parent)

/// `vch sim` is a parent command grouping the four explicit simulator
/// verbs from Q9. None of them are needed for the day-to-day "build
/// + test" flow (M5's lazy clone covers that); these exist for setup
/// scripts and recovery.
struct SimCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sim",
        abstract: "Manage the per-task simulator clone.",
        subcommands: [
            SimCloneCommand.self,
            SimEraseCommand.self,
            SimShutdownCommand.self,
            SimInfoCommand.self,
        ]
    )
}

// MARK: - vch sim clone

struct SimCloneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clone",
        abstract: "Force-create the per-task simulator clone now (idempotent)."
    )

    @Argument(help: "Task name.")
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

    @Argument(help: "Task name.")
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

    @Argument(help: "Task name.")
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

    @Argument(help: "Task name.")
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

// MARK: - vch doctor

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Sweep for orphan simulator clones and stale state."
    )

    @Flag(name: .long, help: "Delete orphan vch[*] simulator clones (never auto).")
    var clean: Bool = false

    @Flag(name: .long, help: "Emit machine-readable JSON.")
    var json: Bool = false

    func run() throws {
        try CLIBridge.run {
            let cwd = FileManager.default.currentDirectoryPath
            let workspace = try WorkspaceLocator.locate(cwd: cwd)
            let doctor = DoctorService(
                workspace: workspace,
                git: DiskGitClient(),
                simctl: DiskSimctlClient()
            )
            let report = try doctor.diagnose()

            var cleanReport: DoctorService.CleanReport?
            if clean && !report.orphanClones.isEmpty {
                cleanReport = doctor.clean(report)
            }

            if json {
                try emitJSON(report: report, clean: cleanReport)
            } else {
                emitHuman(report: report, clean: cleanReport, didClean: clean)
            }

            // Non-zero only when there are findings and we did NOT
            // resolve them. After --clean, an orphan that was deleted
            // successfully is no longer a finding; stale bindings and
            // state problems still are.
            if shouldExitNonZero(report: report, clean: cleanReport, didClean: clean) {
                throw ArgumentParser.ExitCode(ExitCode.business)
            }
        }
    }

    private func emitHuman(
        report: DoctorService.Report,
        clean: DoctorService.CleanReport?,
        didClean: Bool
    ) {
        if report.prunedStaleEntries {
            print("pruned stale worktree entries")
        }
        let checked = report.checkedTasks.isEmpty
            ? "(none)" : report.checkedTasks.joined(separator: ", ")
        print("checked tasks: \(checked)")

        if !report.stateProblems.isEmpty {
            CLIBridge.eprintln("state problems:")
            for p in report.stateProblems {
                CLIBridge.eprintln("  - \(p)")
            }
        }

        if !report.orphanClones.isEmpty {
            CLIBridge.eprintln("orphan vch[*] simulator clones:")
            for d in report.orphanClones {
                CLIBridge.eprintln("  - \(d.name)  (\(d.udid))")
            }
            if !didClean {
                CLIBridge.eprintln("  (re-run with --clean to delete)")
            }
        }

        if !report.staleBindings.isEmpty {
            CLIBridge.eprintln("stale simulator bindings (clone gone from simctl):")
            for s in report.staleBindings {
                CLIBridge.eprintln("  - \(s.taskName) → \(s.cloneName) (\(s.cloneUDID))")
            }
            CLIBridge.eprintln("  (run `vch sim clone <task> --device …` or `vch repair`)")
        }

        if let clean {
            for name in clean.deletedClones {
                CLIBridge.eprintln("→ deleted '\(name)'")
            }
            for fail in clean.failedDeletes {
                CLIBridge.eprintln("warning: could not delete '\(fail.name)': \(fail.error)")
            }
        }

        if !report.hasFindings {
            print("no problems found")
        }
    }

    private func emitJSON(
        report: DoctorService.Report,
        clean: DoctorService.CleanReport?
    ) throws {
        struct OrphanJSON: Encodable {
            let name: String; let udid: String
            let runtime: String; let isAvailable: Bool
        }
        struct StaleJSON: Encodable {
            let taskName: String; let cloneUDID: String; let cloneName: String
        }
        struct CleanJSON: Encodable {
            let deletedClones: [String]
            let failedDeletes: [String]
        }
        struct Out: Encodable {
            let prunedStaleEntries: Bool
            let checkedTasks: [String]
            let stateProblems: [String]
            let orphanClones: [OrphanJSON]
            let staleBindings: [StaleJSON]
            let cleaned: CleanJSON?
        }
        let out = Out(
            prunedStaleEntries: report.prunedStaleEntries,
            checkedTasks: report.checkedTasks,
            stateProblems: report.stateProblems,
            orphanClones: report.orphanClones.map {
                OrphanJSON(name: $0.name, udid: $0.udid,
                          runtime: $0.runtime, isAvailable: $0.isAvailable)
            },
            staleBindings: report.staleBindings.map {
                StaleJSON(taskName: $0.taskName, cloneUDID: $0.cloneUDID,
                          cloneName: $0.cloneName)
            },
            cleaned: clean.map { c in
                CleanJSON(
                    deletedClones: c.deletedClones,
                    failedDeletes: c.failedDeletes.map { "\($0.name): \($0.error)" }
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(out)
        if let str = String(data: data, encoding: .utf8) { print(str) }
    }

    private func shouldExitNonZero(
        report: DoctorService.Report,
        clean: DoctorService.CleanReport?,
        didClean: Bool
    ) -> Bool {
        if !report.stateProblems.isEmpty { return true }
        if !report.staleBindings.isEmpty { return true }
        if didClean {
            // Every orphan was either deleted or failed.
            if let c = clean, !c.failedDeletes.isEmpty { return true }
            return false
        } else {
            return !report.orphanClones.isEmpty
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
