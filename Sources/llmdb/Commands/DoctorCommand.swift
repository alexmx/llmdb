import ArgumentParser
import Darwin
import Foundation

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Diagnose the local llmdb environment (lldb-dap, socket dir, daemon reachability)"
    )

    @Option(name: .long, help: "Output format")
    var format: OutputFormat = .default

    func run() async throws {
        let report = await Doctor.runChecks()
        try JSONOutput.print(report)
        if !report.allOK { throw ExitCode.failure }
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
        await Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            proc.arguments = ["--find", "lldb-dap"]
            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = Pipe()
            do {
                try proc.run()
                proc.waitUntilExit()
                let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if proc.terminationStatus == 0, !path.isEmpty {
                    return DoctorCheck(name: "lldb-dap", ok: true, detail: path)
                }
            } catch {
                return DoctorCheck(name: "lldb-dap", ok: false, detail: "xcrun failed: \(error)")
            }
            return DoctorCheck(
                name: "lldb-dap",
                ok: false,
                detail: "not found — install Xcode or the Command Line Tools"
            )
        }.value
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

    // MARK: - Daemon reachability (does NOT auto-spawn)

    private static func checkDaemon() -> DoctorCheck {
        let path = Daemon.defaultSocketPath
        if !FileManager.default.fileExists(atPath: path) {
            // Not a failure — just no daemon yet. The next CLI/MCP call will
            // auto-spawn it. Keeps `doctor` from false-positiving on a fresh
            // install.
            return DoctorCheck(
                name: "daemon",
                ok: true,
                detail: "idle (no socket at \(path)) — auto-spawns on first CLI call"
            )
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            return DoctorCheck(name: "daemon", ok: false, detail: "socket() failed (errno \(errno))")
        }
        defer { Darwin.close(fd) }
        do {
            let rc = try UnixSocketIO.withSockaddr(path: path) { sptr, len in
                Darwin.connect(fd, sptr, len)
            }
            if rc == 0 {
                return DoctorCheck(name: "daemon", ok: true, detail: path)
            }
            return DoctorCheck(
                name: "daemon",
                ok: false,
                detail: "stale socket at \(path) (connect refused; daemon died — rm and retry)"
            )
        } catch {
            return DoctorCheck(name: "daemon", ok: false, detail: "\(error)")
        }
    }
}
