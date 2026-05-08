import ArgumentParser
import Foundation
import VibeChardCore

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

    @Flag(
        name: .long,
        help: "Bundle a redacted diagnostics tarball locally (no network). $HOME paths are scrubbed."
    )
    var bugReport: Bool = false

    @Option(
        name: .long,
        help: "Override the default `--bug-report` output path."
    )
    var out: String?

    func run() throws {
        try CLIBridge.run {
            let cwd = FileManager.default.currentDirectoryPath
            let workspace = try WorkspaceLocator.locate(cwd: cwd)

            // --bug-report short-circuits the diagnose+clean path.
            // The bundle should reflect on-disk state as the user
            // experienced it, not the post-clean state.
            if bugReport {
                if clean {
                    CLIBridge.eprintln(
                        "warning: --clean ignored when --bug-report is set"
                    )
                }
                try runBugReport(workspace: workspace, cwd: cwd)
                return
            }

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

    // MARK: - --bug-report

    private func runBugReport(workspace: Workspace, cwd: String) throws {
        let service = BugReportService(
            workspace: workspace,
            git: DiskGitClient()
        )
        let entries = try service.collect()

        // Resolve output path. Relative paths anchor to CWD so
        // `--out reports/foo.tgz` lands inside the worktree, not in
        // some surprising tmp dir.
        let outPath: String
        if let raw = out, !raw.isEmpty {
            outPath = (raw as NSString).isAbsolutePath
                ? raw
                : (cwd as NSString).appendingPathComponent(raw)
        } else {
            outPath = (cwd as NSString)
                .appendingPathComponent(service.defaultOutputName())
        }
        let outURL = URL(fileURLWithPath: outPath)

        let archiver = DiskTarGzArchiver()
        try archiver.write(entries, to: outURL)

        if json {
            struct Out: Encodable {
                let outPath: String
                let entries: [String]
                let totalBytes: Int
            }
            let payload = Out(
                outPath: outURL.path,
                entries: entries.map(\.path),
                totalBytes: entries.reduce(0) { $0 + $1.data.count }
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            if let str = String(data: data, encoding: .utf8) { print(str) }
        } else {
            CLIBridge.eprintln("vch bug report bundled \(entries.count) files:")
            for e in entries {
                CLIBridge.eprintln("  - \(e.path)  (\(e.data.count) bytes)")
            }
            CLIBridge.eprintln("")
            CLIBridge.eprintln("→ \(outURL.path)")
            CLIBridge.eprintln(
                "Privacy: $HOME paths are scrubbed. Inspect before sharing."
            )
        }
    }
}
