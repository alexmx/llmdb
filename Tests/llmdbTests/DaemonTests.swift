import Darwin
import Foundation
@testable import llmdb
import Testing

/// Drives the built `llmdb` binary and its daemon as subprocesses: an
/// in-process Daemon would install SIGTERM handlers that `exit(0)` the test
/// runner, and DaemonClient's auto-spawn would re-exec the runner itself.
@Suite("Daemon protocol and version handshake")
struct DaemonTests {
    @Test
    func daemonAnswersVersionAndProtocolErrors() async throws {
        let llmdb = try llmdbBinary()
        let socket = Self.makeSocketPath()
        let daemon = try Self.start(llmdb, ["daemon", "--socket", socket])
        defer { Self.cleanUp(daemon, socket: socket) }
        try await Self.waitUntilListening(socket)

        let version = try Self.send(#"{"id":1,"method":"version"}"#, to: socket)
        let info = try #require(version["result"] as? [String: Any])
        #expect(info["version"] as? String == llmdbVersion)
        #expect(info["build"] as? String == Self.expectedBuild(of: llmdb))

        let unknown = try Self.send(#"{"id":2,"method":"nope"}"#, to: socket)
        #expect(unknown["error"] as? String == "unknown method: nope")
        #expect(unknown["id"] as? Int == 2)
        let noMethod = try Self.send(#"{"id":3}"#, to: socket)
        #expect(noMethod["error"] as? String == "missing `method`")
        let garbage = try Self.send("garbage", to: socket)
        #expect(garbage["error"] as? String == "expected JSON object")
    }

    @Test
    func cliReplacesADaemonFromAnOlderVersion() async throws {
        let llmdb = try llmdbBinary()
        let socket = Self.makeSocketPath()
        let fake = try Self.startFakeOldDaemon(socket)
        defer { Self.cleanUp(fake, socket: socket) }
        try await Self.waitUntilListening(socket)

        let run = try await Self.run(llmdb, ["sessions"], socket: socket)
        defer { Self.stopDaemon(at: socket) }
        #expect(run.status == 0)
        #expect(run.stderr.contains("restarting llmdbd"))
        #expect(run.stderr.contains("an older llmdb (no version handshake)"))
        #expect(!fake.isRunning)

        let version = try Self.send(#"{"id":1,"method":"version"}"#, to: socket)
        let info = try #require(version["result"] as? [String: Any])
        #expect(info["build"] as? String == Self.expectedBuild(of: llmdb))
    }

    @Test
    func doctorFlagsAnOlderDaemonWithoutRestartingIt() async throws {
        let llmdb = try llmdbBinary()
        let socket = Self.makeSocketPath()
        let fake = try Self.startFakeOldDaemon(socket)
        defer { Self.cleanUp(fake, socket: socket) }
        try await Self.waitUntilListening(socket)

        let run = try await Self.run(llmdb, ["doctor"], socket: socket)
        #expect(run.status == 1)
        let report = try JSONDecoder().decode(DoctorReport.self, from: Data(run.stdout.utf8))
        let check = try #require(report.checks.first { $0.name == "daemon" })
        #expect(!check.ok)
        #expect(check.detail?.contains("an older llmdb") == true)
        #expect(fake.isRunning)
    }

    @Test
    func staleSocketIsReportedThenReplaced() async throws {
        let llmdb = try llmdbBinary()
        let socket = Self.makeSocketPath()
        defer { _ = unlink(socket) }
        // A socket file nobody listens on — what a daemon that died without
        // unlinking leaves behind. connect() gets ECONNREFUSED.
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        _ = try UnixSocketIO.withSockaddr(path: socket) { bind(fd, $0, $1) }
        close(fd)

        let doctor = try await Self.run(llmdb, ["doctor"], socket: socket)
        let report = try JSONDecoder().decode(DoctorReport.self, from: Data(doctor.stdout.utf8))
        let check = try #require(report.checks.first { $0.name == "daemon" })
        #expect(!check.ok)
        #expect(check.detail?.hasPrefix("stale socket") == true)

        let run = try await Self.run(llmdb, ["sessions"], socket: socket)
        defer { Self.stopDaemon(at: socket) }
        #expect(run.status == 0)
        let version = try Self.send(#"{"id":1,"method":"version"}"#, to: socket)
        #expect(version["result"] != nil)
    }

    // MARK: - Helpers

    private struct SetupError: Error, CustomStringConvertible {
        let description: String
    }

    private func llmdbBinary() throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                let binary = dir.appendingPathComponent(".build/debug/llmdb").path
                guard FileManager.default.fileExists(atPath: binary) else {
                    throw SetupError(description: "llmdb not built — run `swift build` before testing")
                }
                return binary
            }
            dir = dir.deletingLastPathComponent()
        }
        throw SetupError(description: "could not locate Package.swift")
    }

    /// Short and unique: `sun_path` caps socket paths at 104 bytes.
    private static func makeSocketPath() -> String {
        "/tmp/llmdb-test-\(UUID().uuidString.prefix(8)).sock"
    }

    /// The build ID a daemon running `binary` reports (see `DaemonBuild`).
    private static func expectedBuild(of binary: String) -> String {
        guard llmdbVersion == "dev" else {
            return llmdbVersion
        }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: binary)[.modificationDate]) as? Date
        return "dev+\(Int(mtime?.timeIntervalSince1970 ?? 0))"
    }

    private static func start(_ executable: String, _ arguments: [String]) throws -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        return proc
    }

    /// Stands in for a daemon from before the `version` handshake: it answers
    /// every request, `version` included, with "unknown method".
    private static func startFakeOldDaemon(_ socket: String) throws -> Process {
        let script = """
        import json, os, socket, sys
        path = sys.argv[1]
        if os.path.exists(path):
            os.unlink(path)
        server = socket.socket(socket.AF_UNIX)
        server.bind(path)
        server.listen(4)
        while True:
            conn, _ = server.accept()
            stream = conn.makefile("rwb")
            for line in stream:
                req = json.loads(line)
                reply = {"id": req.get("id", 0), "error": "unknown method: " + req.get("method", "")}
                stream.write((json.dumps(reply) + "\\n").encode())
                stream.flush()
            conn.close()
        """
        return try start("/usr/bin/python3", ["-c", script, socket])
    }

    private static func cleanUp(_ proc: Process, socket: String) {
        if proc.isRunning {
            proc.terminate()
        }
        _ = unlink(socket)
    }

    /// SIGTERM whichever process is listening on `socket` (a daemon the CLI
    /// spawned, so not our child).
    private static func stopDaemon(at socket: String) {
        guard let fd = try? connect(socket) else { return }
        defer { close(fd) }
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        if getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0, pid > 0 {
            kill(pid, SIGTERM)
        }
    }

    private static func waitUntilListening(_ socket: String) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let fd = try? connect(socket) {
                close(fd)
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw SetupError(description: "nothing listening on \(socket) after 5s")
    }

    private static func connect(_ socket: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        let rc = try UnixSocketIO.withSockaddr(path: socket) { Darwin.connect(fd, $0, $1) }
        guard rc == 0 else {
            close(fd)
            throw SetupError(description: "connect(\(socket)) failed (errno \(errno))")
        }
        return fd
    }

    /// Send one request line and return the decoded response object.
    private static func send(_ line: String, to socket: String) throws -> [String: Any] {
        let fd = try connect(socket)
        defer { close(fd) }
        try UnixSocketIO.writeAll(fd: fd, data: Data((line + "\n").utf8))
        var response = Data()
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1, byte != 0x0A {
            response.append(byte)
        }
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw SetupError(description: "response is not a JSON object")
        }
        return object
    }

    /// Run the CLI against `socket` and collect its exit status and output.
    private static func run(
        _ llmdb: String,
        _ arguments: [String],
        socket: String
    ) async throws -> (status: Int32, stdout: String, stderr: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: llmdb)
        proc.arguments = arguments
        proc.environment = ProcessInfo.processInfo.environment.merging(["LLMDB_SOCKET_PATH": socket]) { $1 }
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        // Buffered, so an exit before we start iterating isn't missed.
        let exited = AsyncStream<Void> { continuation in
            proc.terminationHandler = { _ in continuation.finish() }
        }
        try proc.run()
        for await _ in exited {}
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (proc.terminationStatus, stdout, stderr)
    }
}
