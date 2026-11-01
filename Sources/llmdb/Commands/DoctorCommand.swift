import ArgumentParser
import Foundation

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Diagnose the local llmdb environment (lldb-dap, socket dir, daemon reachability)"
    )

    func run() async throws {
        let report = await Doctor.runChecks()
        try JSONOutput.print(report)
        if !report.allOK {
            throw ExitCode.failure
        }
    }
}

/// The set of environment checks doctor runs. Each check is independent and
/// always runs — we'd rather report three failures than stop at the first.
enum Doctor {
    static func runChecks() async -> DoctorReport {
        async let dap = checkLldbDap()
        let socketDir = checkSocketDir()
        let daemon = checkDaemon()
        return await DoctorReport(checks: [dap, socketDir, daemon])
    }

    // MARK: - lldb-dap

    private static func checkLldbDap() async -> DoctorCheck {
        if let path = await DAPClient.findLldbDap() {
            return DoctorCheck(name: "lldb-dap", ok: true, detail: path)
        }
        return DoctorCheck(name: "lldb-dap", ok: false, detail: "not found — install Xcode or the Command Line Tools")
    }

    // MARK: - Socket directory

    private static func checkSocketDir() -> DoctorCheck {
        let path = Daemon.defaultSocketPath
        let dir = (path as NSString).deletingLastPathComponent
        // Try to create the directory. If it already exists this is a no-op;
        // if we can't, we have a permission problem the daemon would hit too.
        do {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true
            )
        } catch {
            return DoctorCheck(name: "socket-dir", ok: false, detail: "\(dir): \(error)")
        }
        guard FileManager.default.isWritableFile(atPath: dir) else {
            return DoctorCheck(name: "socket-dir", ok: false, detail: "\(dir) is not writable")
        }
        return DoctorCheck(name: "socket-dir", ok: true, detail: dir)
    }

    // MARK: - Daemon reachability + version (does NOT auto-spawn or restart)

    private static func checkDaemon() -> DoctorCheck {
        let path = Daemon.defaultSocketPath
        let status: DaemonClient.Status
        do {
            status = try DaemonClient.status()
        } catch {
            return DoctorCheck(name: "daemon", ok: false, detail: "\(error)")
        }
        switch status {
        case .idle:
            // Not a failure — just no daemon yet. The next CLI/MCP call will
            // auto-spawn it. Keeps `doctor` from false-positiving on a fresh
            // install.
            return DoctorCheck(
                name: "daemon",
                ok: true,
                detail: "idle (no socket at \(path)) — auto-spawns on first CLI call"
            )
        case .staleSocket:
            return DoctorCheck(
                name: "daemon",
                ok: false,
                detail: "stale socket at \(path) (connect refused; daemon died — rm and retry)"
            )
        case .running(let pid, let info):
            let pidText = pid.map { "pid \($0)" } ?? "pid ?"
            if let info, info.build == DaemonBuild.current {
                return DoctorCheck(name: "daemon", ok: true, detail: "\(path) (\(pidText), version \(info.version))")
            }
            return DoctorCheck(
                name: "daemon",
                ok: false,
                detail: "\(pidText) is \(DaemonClient.describe(info)), this CLI is \(llmdbVersion) — the next llmdb call restarts it (its sessions are lost)"
            )
        }
    }
}
