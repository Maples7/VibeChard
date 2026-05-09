import Foundation

/// One file destined for the bug-report tarball.
public struct BugReportEntry: Equatable, Sendable {
    /// Path inside the archive, with `/` separators. No leading slash.
    public let path: String
    public let data: Data

    public init(path: String, data: Data) {
        self.path = path
        self.data = data
    }
}

/// `vch doctor --bug-report` collector (Plan Q10).
///
/// Bundles enough context for an offline triage of a vch problem.
/// Runs entirely locally — no network, no telemetry (AGENTS.md rule
/// #3). The user is the only one who decides whether to share the
/// resulting tarball.
///
/// Inclusions per Plan Q10:
///   • Per-task `.vch/state.json`             (ground truth)
///   • Per-task `.vch/last-test.log`           (capped at 256 KiB)
///   • Per-task `.vch/last-build.log`          (capped at 256 KiB)
///   • `git worktree list --porcelain`         (vch's view of the world)
///   • `sw_vers`, `xcode-select -p`,           (host toolchain)
///     `xcrun -f xcodebuild`, `swift --version`
///   • `vch-version.txt`                       (bug.report writer's identity)
///   • `MANIFEST.txt`                          (table-of-contents)
///
/// Path scrubbing: the user's home directory string is replaced with
/// the literal `$HOME` in every textual entry. State files often
/// contain absolute paths; this avoids leaking the local username
/// into pasted-into-issue logs.
public struct BugReportService: Sendable {
    public let workspace: Workspace
    public let fs: FileSystem
    public let git: GitClient
    public let runner: ProcessRunner
    /// Source for the warm-templates.json entry (#47). Optional only
    /// because the existing tests construct `BugReportService` without
    /// caring about simulator state — production callers always pass
    /// `DiskSimctlClient()`. When `nil`, the warm-templates entry is
    /// silently skipped.
    public let simctl: SimctlClient?
    /// Injected so tests can pin generated timestamps.
    public let now: @Sendable () -> Date
    /// Injected so tests can pretend to run as a different user
    /// (e.g. `/Users/test`) without the real `NSHomeDirectory()`.
    public let homeDir: @Sendable () -> String
    /// Hard cap on `last-test.log` size to keep the bundle shareable.
    /// Anything beyond this is dropped from the *front* of the file
    /// (we keep the most recent output, which is what the user cares
    /// about for diagnosing a failure).
    public let lastTestLogTailBytes: Int

    public init(
        workspace: Workspace,
        git: GitClient,
        fs: FileSystem = DiskFileSystem(),
        runner: ProcessRunner = DiskProcessRunner(),
        simctl: SimctlClient? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        homeDir: @escaping @Sendable () -> String = { NSHomeDirectory() },
        lastTestLogTailBytes: Int = 256 * 1024
    ) {
        self.workspace = workspace
        self.fs = fs
        self.git = git
        self.runner = runner
        self.simctl = simctl
        self.now = now
        self.homeDir = homeDir
        self.lastTestLogTailBytes = lastTestLogTailBytes
    }

    public func collect() throws -> [BugReportEntry] {
        let homeMap = scrubMap()
        var entries: [BugReportEntry] = []

        // -- vch identity --
        entries.append(BugReportEntry(
            path: "vch-version.txt",
            data: Data("\(VibeChard.version)\n".utf8)
        ))

        // -- per-task state + last-test.log --
        // Best-effort. A flaky `git` (corrupt index, etc.) shouldn't
        // be the thing that prevents us from producing a bug report.
        let porcelain = (try? git.worktreeList(repoCwd: workspace.mainWorktreePath)) ?? []
        var perTaskNotes: [String] = []
        for entry in porcelain {
            if entry.path == workspace.mainWorktreePath { continue }
            guard let raw = workspace.taskNameRaw(forWorktreePath: entry.path) else { continue }

            let statePath = PathOps.join(entry.path, Workspace.stateJsonRelativePath)
            if fs.fileExists(at: statePath), let data = try? fs.readFile(at: statePath) {
                entries.append(BugReportEntry(
                    path: "tasks/\(raw)/state.json",
                    data: scrub(data, map: homeMap)
                ))
            } else {
                perTaskNotes.append("\(raw): no state.json on disk")
            }

            let logPath = PathOps.join(entry.path, Workspace.lastTestLogRelativePath)
            if fs.fileExists(at: logPath), let data = try? fs.readFile(at: logPath) {
                let capped: Data
                if data.count > lastTestLogTailBytes {
                    capped = data.suffix(lastTestLogTailBytes)
                } else {
                    capped = data
                }
                entries.append(BugReportEntry(
                    path: "tasks/\(raw)/last-test.log",
                    data: scrub(capped, map: homeMap)
                ))
            }

            // #48: include last-build.log on the same terms as
            // last-test.log — same cap, same scrub, best-effort.
            let buildLogPath = PathOps.join(entry.path, Workspace.lastBuildLogRelativePath)
            if fs.fileExists(at: buildLogPath), let data = try? fs.readFile(at: buildLogPath) {
                let capped: Data
                if data.count > lastTestLogTailBytes {
                    capped = data.suffix(lastTestLogTailBytes)
                } else {
                    capped = data
                }
                entries.append(BugReportEntry(
                    path: "tasks/\(raw)/last-build.log",
                    data: scrub(capped, map: homeMap)
                ))
            }
        }

        // -- worktree-list snapshot (raw porcelain text) --
        let worktreeListText = porcelain.map { e in
            // Re-render in porcelain form for human inspection;
            // `entry.branch` may be nil for detached HEAD entries.
            let lines = [
                "worktree \(e.path)",
                e.branch.map { "branch \($0)" } ?? "detached",
            ]
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n") + "\n"
        entries.append(BugReportEntry(
            path: "git/worktree-list.txt",
            data: scrub(worktreeListText, map: homeMap)
        ))

        // -- system probes --
        entries.append(probe(
            path: "system/sw_vers.txt",
            exec: "/usr/bin/sw_vers",
            args: [],
            scrub: homeMap
        ))
        entries.append(probe(
            path: "system/xcode-select-p.txt",
            exec: "/usr/bin/xcode-select",
            args: ["-p"],
            scrub: homeMap
        ))
        entries.append(probe(
            path: "system/xcrun-f-xcodebuild.txt",
            exec: "/usr/bin/xcrun",
            args: ["-f", "xcodebuild"],
            scrub: homeMap
        ))
        entries.append(probe(
            path: "system/swift-version.txt",
            exec: "/usr/bin/swift",
            args: ["--version"],
            scrub: homeMap
        ))

        // -- warm-templates inventory (#47) --
        // Listed as a JSON file so an offline reviewer can see whether
        // any warm templates exist and what state they're in. Does
        // NOT include the underlying simctl device data dirs (those
        // live under ~/Library/Developer/CoreSimulator/Devices/<UDID>/
        // and may contain provisioning profiles or other PII).
        if let simctl = self.simctl {
            let sim = SimulatorService(workspace: workspace, simctl: simctl, fs: fs)
            do {
                let rows = try sim.listWarmTemplates()
                let json = try renderWarmTemplatesJSON(rows: rows)
                entries.append(BugReportEntry(
                    path: "warm-templates.json",
                    data: scrub(json, map: homeMap)
                ))
            } catch {
                perTaskNotes.append("warm-templates listing failed: \(error)")
            }
        }

        // -- MANIFEST.txt at top of archive --
        let manifest = manifestText(entries: entries, notes: perTaskNotes)
        entries.insert(
            BugReportEntry(path: "MANIFEST.txt", data: Data(manifest.utf8)),
            at: 0
        )
        return entries
    }

    /// Deterministic default file name. CLI uses this when the user
    /// doesn't pass `--out`. Format:
    ///
    ///     vch-bug-report-YYYYMMDDTHHMMSSZ.tgz
    public func defaultOutputName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return "vch-bug-report-\(f.string(from: now())).tgz"
    }

    // MARK: - private

    private func scrubMap() -> [(String, String)] {
        let home = homeDir()
        guard !home.isEmpty else { return [] }
        // Order matters: `/Users/x/Library` must be replaced before
        // anything that mentions `/Users/x`. We only have one entry
        // today but keep the array shape so we can extend safely.
        return [(home, "$HOME")]
    }

    private func scrub(_ text: String, map: [(String, String)]) -> Data {
        var s = text
        for (old, new) in map {
            s = s.replacingOccurrences(of: old, with: new)
        }
        return Data(s.utf8)
    }

    /// Same scrub but for binary-ish payloads. If the bytes don't
    /// look like UTF-8 (e.g. the user has a binary blob), pass them
    /// through unmodified rather than corrupting them.
    private func scrub(_ data: Data, map: [(String, String)]) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        return scrub(text, map: map)
    }

    /// Run a system probe. Captures stdout, stderr, and exit code so
    /// the bug-report consumer can see why a probe failed (e.g.
    /// `xcrun -f xcodebuild` returning 72 because Command Line Tools
    /// are unselected).
    private func probe(
        path: String,
        exec: String,
        args: [String],
        scrub map: [(String, String)]
    ) -> BugReportEntry {
        var body = ""
        do {
            let r = try runner.run(exec, args: args, cwd: nil, env: nil)
            body += "$ \(exec) \(args.joined(separator: " "))\n"
            if !r.stdout.isEmpty { body += r.stdout }
            if !r.stdout.hasSuffix("\n") { body += "\n" }
            if !r.stderr.isEmpty {
                body += "--- stderr ---\n\(r.stderr)"
                if !r.stderr.hasSuffix("\n") { body += "\n" }
            }
            body += "--- exit \(r.exitCode) ---\n"
        } catch {
            body = "$ \(exec) \(args.joined(separator: " "))\n"
            body += "error: \(error)\n"
        }
        return BugReportEntry(path: path, data: scrub(body, map: map))
    }

    /// Render `warm-templates.json` body for the bug-report tarball
    /// (#47). The JSON shape is owned by `WarmTemplateRecord`'s
    /// Encodable conformance, so this output stays byte-identical
    /// with `vch sim warm-template list --json` and `vch doctor
    /// --json`'s `warmTemplates[]` field.
    private func renderWarmTemplatesJSON(rows: [WarmTemplateRecord]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(rows)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func manifestText(
        entries: [BugReportEntry],
        notes: [String]
    ) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        var lines = [
            "vch bug report",
            "generated: \(f.string(from: now()))",
            "vch version: \(VibeChard.version)",
            "",
            "Files in this bundle:",
        ]
        for e in entries {
            lines.append("  \(e.path)  (\(e.data.count) bytes)")
        }
        if !notes.isEmpty {
            lines.append("")
            lines.append("Notes:")
            for n in notes { lines.append("  - \(n)") }
        }
        lines.append("")
        lines.append(
            "Privacy: $HOME has been replaced with the literal '$HOME' in"
        )
        lines.append(
            "every textual file. Inspect before sharing publicly."
        )
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
