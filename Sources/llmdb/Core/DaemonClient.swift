import Darwin
import Foundation

/// CLI-side client for `llmdbd`. Connects to the Unix socket, sends
/// newline-delimited JSON-RPC requests, returns decoded responses.
/// Auto-spawns `llmdb daemon` if the socket is absent.
struct DaemonClient: Sendable {

    static let socketPath: String = Daemon.defaultSocketPath

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
            throw LlmdbError.daemonUnreachable(error)
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
        // Socket exists → try to connect. Surface any connect error directly so
        // we don't silently re-spawn a daemon that's already up.
        if FileManager.default.fileExists(atPath: socketPath) {
            return try connect()
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

    private static func readLine(fd: Int32) throws -> Data {
        var buffer = Data()
        var byte: UInt8 = 0
        while true {
            let n = Darwin.read(fd, &byte, 1)
            if n < 0 {
                if errno == EINTR { continue }
                throw LlmdbError.daemonUnreachable("read failed (errno \(errno))")
            }
            if n == 0 { throw LlmdbError.daemonUnreachable("socket closed before response") }
            if byte == 0x0A { return buffer }
            buffer.append(byte)
        }
    }
}

// MARK: - Wire types

private struct RPCRequest<P: Encodable>: Encodable {
    let id: Int
    let method: String
    let params: P
}

private struct RPCResponse<T: Decodable>: Decodable {
    let id: Int
    let result: T?
    let error: String?
}

private struct EmptyParams: Encodable, Sendable {}
