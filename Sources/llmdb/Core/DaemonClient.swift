import Darwin
import Foundation

/// CLI-side client for `llmdbd`. Connects to the Unix socket, sends
/// newline-delimited JSON-RPC requests, returns decoded responses.
/// Auto-spawns `llmdb daemon` if the socket is absent.
enum DaemonClient {
    /// Re-reads `Daemon.defaultSocketPath` per call so it honors
    /// `LLMDB_SOCKET_PATH` even when the env var is set after import.
    static var socketPath: String { Daemon.defaultSocketPath }

    /// Call a method on the daemon. Auto-spawns the daemon on first use.
    static func call<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        method: String,
        params: Params,
        as resultType: Result.Type
    ) async throws -> Result {
        let fd = try await connectOrSpawn()
        defer { Darwin.close(fd) }

        let id = Int.random(in: 1...1_000_000)
        let request = RPCRequest(id: id, method: method, params: params)
        var requestData = try JSONEncoder().encode(request)
        requestData.append(0x0A)
        try UnixSocketIO.writeAll(fd: fd, data: requestData)

        let responseLine = try readLine(fd: fd)
        let envelope = try JSONDecoder().decode(RPCResponse<Result>.self, from: responseLine)
        if let error = envelope.error {
            // Daemon-originated error — pass through without our own prefix.
            throw LlmdbError.remote(error)
        }
        guard let result = envelope.result else {
            throw LlmdbError.daemonUnreachable("daemon returned no result and no error")
        }
        return result
    }

    static func call<Result: Decodable & Sendable>(
        method: String,
        as resultType: Result.Type
    ) async throws -> Result {
        try await call(method: method, params: EmptyParams(), as: resultType)
    }

    // MARK: - Connect / auto-spawn

    private static func connectOrSpawn() async throws -> Int32 {
        // Try to connect to an existing daemon. If the socket file is missing
        // OR it's stale (ECONNREFUSED = no listener bound) — spawn a fresh
        // daemon and poll until the socket is up.
        if FileManager.default.fileExists(atPath: socketPath) {
            do {
                return try connect()
            } catch LlmdbError.daemonUnreachable where errno == ECONNREFUSED {
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
                do { return try connect() } catch { lastError = error }
            }
        }
        throw lastError ?? LlmdbError.daemonUnreachable("daemon spawned but socket did not appear")
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
            throw LlmdbError.daemonUnreachable("connect failed (errno \(savedErrno))")
        }
        return fd
    }

    private static func spawnDaemon() throws {
        let exe = CommandLine.arguments[0]
        let resolved: String = (exe as NSString).isAbsolutePath
            ? exe
            : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(exe)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: resolved)
        proc.arguments = ["daemon"]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            throw LlmdbError.daemonUnreachable("failed to spawn daemon: \(error)")
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
                        if errno == EINTR { continue }
                        return -Int(errno)
                    }
                    return r
                }
            }
            if n < 0 { throw LlmdbError.daemonUnreachable("read failed (errno \(-n))") }
            if n == 0 { throw LlmdbError.daemonUnreachable("socket closed before response") }
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
