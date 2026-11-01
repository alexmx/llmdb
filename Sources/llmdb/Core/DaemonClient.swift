import Darwin
import Foundation
import Synchronization

/// CLI-side client for `llmdbd`. Connects to the Unix socket, sends
/// newline-delimited JSON-RPC requests, returns decoded responses.
/// Auto-spawns `llmdb daemon` if the socket is absent.
enum DaemonClient {
    /// Re-reads `Daemon.defaultSocketPath` per call so it honors
    /// `LLMDB_SOCKET_PATH` even when the env var is set after import.
    static var socketPath: String {
        Daemon.defaultSocketPath
    }

    /// Call a method on the daemon. Auto-spawns the daemon on first use.
    static func call<Params, Result>(
        _ method: RPCMethod<Params, Result>,
        _ params: Params
    ) async throws -> Result {
        let fd = try await connectOrSpawn()
        defer { Darwin.close(fd) }

        let id = Int.random(in: 1...1_000_000)
        let request = RPCRequest(id: id, method: method.name, params: params)
        var requestData = try JSONEncoder().encode(request)
        requestData.append(0x0A)
        try UnixSocketIO.writeAll(fd: fd, data: requestData)

        let responseLine = try readLine(fd: fd)
        let envelope: RPCResponse<Result>
        do {
            envelope = try JSONDecoder().decode(RPCResponse<Result>.self, from: responseLine)
        } catch is DecodingError {
            // Usually a daemon from another llmdb version that slipped past the
            // version check (e.g. a long-running MCP server outlived an upgrade).
            throw LlmdbError.daemonMismatch(
                "unexpected `\(method.name)` response from llmdbd — it may be a different llmdb version; run `llmdb doctor`"
            )
        }
        if let error = envelope.error {
            // Daemon-originated error — pass through without our own prefix.
            throw LlmdbError.remote(error)
        }
        guard let result = envelope.result else {
            throw LlmdbError.daemonUnreachable("daemon returned no result and no error")
        }
        return result
    }

    static func call<Result>(_ method: RPCMethod<EmptyParams, Result>) async throws -> Result {
        try await call(method, EmptyParams())
    }

    // MARK: - Connect / auto-spawn

    /// Set once this process has confirmed the daemon matches its build (or
    /// spawned it). Checked once per process, not per call: a long-running MCP
    /// server and a freshly upgraded CLI would otherwise keep restarting the
    /// daemon to match themselves, killing sessions each time.
    private static let verified = Mutex(false)

    private static func connectOrSpawn() async throws -> Int32 {
        // Try to connect to an existing daemon. If the socket file is missing
        // OR it's stale (ECONNREFUSED = no listener bound) — spawn a fresh
        // daemon and poll until the socket is up. A daemon from a different
        // build (e.g. still running from before an upgrade) is replaced.
        if FileManager.default.fileExists(atPath: socketPath) {
            do {
                let fd = try connect()
                if verified.withLock({ $0 }) {
                    return fd
                }
                let matches: Bool
                do {
                    matches = try await checkBuild(fd: fd)
                } catch {
                    Darwin.close(fd)
                    throw error
                }
                if matches {
                    verified.withLock { $0 = true }
                    return fd
                }
                Darwin.close(fd)
            } catch is ConnectionRefused {
                // Stale socket from a dead daemon; unlink and respawn.
                _ = Darwin.unlink(socketPath)
            }
        }
        try spawnDaemon()
        let deadline = Date().addingTimeInterval(3)
        var lastError: Error?
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            if FileManager.default.fileExists(atPath: socketPath) {
                do {
                    let fd = try connect()
                    verified.withLock { $0 = true }
                    return fd
                } catch {
                    lastError = error
                }
            }
        }
        throw lastError ?? LlmdbError.daemonUnreachable("daemon spawned but socket did not appear")
    }

    /// True if the daemon on `fd` is this build. Otherwise stops it (its
    /// sessions go with it) so the caller can spawn a matching one.
    private static func checkBuild(fd: Int32) async throws -> Bool {
        let info = try fetchInfo(fd: fd)
        if info?.build == DaemonBuild.current {
            return true
        }
        let pid = peerPID(fd: fd)
        FileHandle.standardError.write(Data(
            "llmdb: restarting llmdbd (pid \(pid.map(String.init) ?? "?")) — it is \(describe(info)), this CLI is \(llmdbVersion). Its sessions are lost.\n"
                .utf8
        ))
        if let pid {
            await terminate(pid: pid)
        }
        return false
    }

    /// Ask the daemon on `fd` for its build. nil → it predates the `version`
    /// method (any pre-handshake llmdb), which is always a mismatch.
    private static func fetchInfo(fd: Int32) throws -> DaemonInfo? {
        var request = try JSONEncoder().encode(RPCRequest(id: 0, method: RPC.version.name, params: EmptyParams()))
        request.append(0x0A)
        try UnixSocketIO.writeAll(fd: fd, data: request)
        let line = try readLine(fd: fd)
        return (try? JSONDecoder().decode(RPCResponse<DaemonInfo>.self, from: line))?.result
    }

    static func describe(_ info: DaemonInfo?) -> String {
        guard let info else {
            return "an older llmdb (no version handshake)"
        }
        return info.version == llmdbVersion ? "a different build of \(info.version)" : "version \(info.version)"
    }

    /// PID of the process listening on the other end of `fd`. Works for any
    /// daemon version, unlike asking the daemon itself.
    private static func peerPID(fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard Darwin.getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0, pid > 0, pid != getpid() else {
            return nil
        }
        return pid
    }

    /// SIGTERM (the daemon unlinks its socket and exits), then SIGKILL if it
    /// hasn't gone within 2s. Its lldb-dap children exit with it, which
    /// releases their targets.
    private static func terminate(pid: pid_t) async {
        func waitForExit(_ seconds: Double) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if Darwin.kill(pid, 0) != 0, errno == ESRCH {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
        Darwin.kill(pid, SIGTERM)
        if await waitForExit(2) {
            return
        }
        Darwin.kill(pid, SIGKILL)
        _ = await waitForExit(1)
        _ = Darwin.unlink(socketPath)
    }

    // MARK: - Status (no spawn, no restart) — for `doctor`

    enum Status {
        /// No socket file; the next call spawns a daemon.
        case idle
        /// Socket file exists but nothing is listening.
        case staleSocket
        /// `info` nil → daemon predates the version handshake.
        case running(pid: pid_t?, info: DaemonInfo?)
    }

    static func status() throws -> Status {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return .idle
        }
        let fd: Int32
        do {
            fd = try connect()
        } catch is ConnectionRefused {
            return .staleSocket
        }
        defer { Darwin.close(fd) }
        return try .running(pid: peerPID(fd: fd), info: fetchInfo(fd: fd))
    }

    private static func connect() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw LlmdbError.daemonUnreachable("socket() failed (errno \(errno))")
        }
        let rc = try UnixSocketIO.withSockaddr(path: socketPath) { sptr, len in
            Darwin.connect(fd, sptr, len)
        }
        if rc != 0 {
            let savedErrno = errno
            Darwin.close(fd)
            if savedErrno == ECONNREFUSED {
                throw ConnectionRefused()
            }
            throw LlmdbError.daemonUnreachable("connect failed (errno \(savedErrno))")
        }
        return fd
    }

    /// The socket file exists but nothing is listening: a daemon died without
    /// unlinking it. Callers catch this by type to recover.
    private struct ConnectionRefused: Error, CustomStringConvertible {
        var description: String {
            LlmdbError.daemonUnreachable("connect failed (errno \(ECONNREFUSED))").description
        }
    }

    private static func spawnDaemon() throws {
        // Re-spawn THIS binary. Bundle.main.executablePath wraps
        // _NSGetExecutablePath() which always returns the actual resolved
        // filesystem path the OS exec'd, regardless of what argv[0] was set
        // to. CommandLine.arguments[0] is unreliable: for PATH-invoked
        // binaries it's just "llmdb" with no directory component, and the
        // old cwd-relative fallback would try to spawn `<cwd>/llmdb` which
        // doesn't exist when the binary lives in /opt/homebrew/bin.
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = ["daemon"]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            throw LlmdbError.daemonUnreachable("failed to spawn daemon (\(exe)): \(error)")
        }
    }

    // MARK: - I/O helpers

    /// Read a single newline-terminated line. Buffered in 4 KiB chunks; for a
    /// modest response this is one or two syscalls instead of one per byte.
    /// The newline itself is consumed and stripped.
    private static func readLine(fd: Int32) throws -> Data {
        var line = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBytes { raw -> Int in
                while true {
                    let r = Darwin.read(fd, raw.baseAddress, raw.count)
                    if r < 0 {
                        if errno == EINTR {
                            continue
                        }
                        return -Int(errno)
                    }
                    return r
                }
            }
            if n < 0 {
                throw LlmdbError.daemonUnreachable("read failed (errno \(-n))")
            }
            if n == 0 {
                throw LlmdbError.daemonUnreachable("socket closed before response")
            }
            if let nl = chunk[..<n].firstIndex(of: 0x0A) {
                line.append(contentsOf: chunk[..<nl])
                // Anything after the newline in this chunk is part of the next
                // response — but DaemonClient closes the fd after each call,
                // so there's never a next response on this connection. Discard.
                return line
            }
            line.append(contentsOf: chunk[..<n])
        }
    }
}
