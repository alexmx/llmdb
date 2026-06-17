import Darwin
import Foundation

/// `llmdbd` — a small JSON-RPC server over a Unix socket that exposes
/// `SessionManager`'s verbs to CLI / MCP clients.
///
/// Wire format: newline-delimited JSON. Single user, no auth. One client per
/// accepted connection; a client may pipeline many requests, each handled in
/// the order they arrive.
///
/// Methods (M1):
///   launch       { binary: String, args: [String] }            → SessionSnapshot
///   sessions     {}                                            → [Session]
///   break.set    { sessionId?: String, file: String, line: Int } → { snapshot, breakpoint }
///   continue     { sessionId?: String }                        → SessionSnapshot
///   bt           { sessionId?: String, depth?: Int }           → { snapshot, frames }
///   locals       { sessionId?: String, frame?: Int }           → { snapshot, locals }
///   stop         { sessionId?: String }                        → { ok: true }
public final class Daemon: @unchecked Sendable {

    public static var defaultSocketPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Caches/llmdb/llmdbd.sock").path
    }

    private let socketPath: String
    private let manager = SessionManager()
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "llmdbd-accept")

    public init(socketPath: String = Daemon.defaultSocketPath) {
        self.socketPath = socketPath
    }

    public func start() throws {
        let parent = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: parent, withIntermediateDirectories: true
        )
        _ = Darwin.unlink(socketPath)

        listenFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw LlmdbError.daemonUnreachable("socket() failed (errno \(errno))")
        }

        try bindUnixSocket(fd: listenFD, path: socketPath)
        guard Darwin.listen(listenFD, 16) == 0 else {
            throw LlmdbError.daemonUnreachable("listen() failed (errno \(errno))")
        }
        let flags = Darwin.fcntl(listenFD, F_GETFL, 0)
        _ = Darwin.fcntl(listenFD, F_SETFL, flags | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            self?.acceptPending()
        }
        source.resume()
        self.acceptSource = source

        FileHandle.standardError.write(Data("llmdbd listening on \(socketPath)\n".utf8))
    }

    /// Park the calling async task forever. The dispatch source on its own
    /// queue keeps accepting connections; this just prevents the process from
    /// exiting. (Note: `dispatchMain()` does NOT block when called from a
    /// Swift concurrency task — only from the actual main thread.)
    public func runForever() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
        }
    }

    // MARK: - Accept loop

    private func acceptPending() {
        while true {
            let clientFD = Darwin.accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                return
            }
            // On BSD/macOS the accepted socket inherits the listen socket's
            // O_NONBLOCK flag. We want blocking reads inside handleClient,
            // so clear it explicitly.
            let flags = Darwin.fcntl(clientFD, F_GETFL, 0)
            _ = Darwin.fcntl(clientFD, F_SETFL, flags & ~O_NONBLOCK)

            let mgr = self.manager
            Task { await Self.handleClient(fd: clientFD, manager: mgr) }
        }
    }

    private static func handleClient(fd: Int32, manager: SessionManager) async {
        defer { Darwin.close(fd) }
        var buffer = Data()
        var readBuf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = readBuf.withUnsafeMutableBytes { raw -> Int in
                while true {
                    let r = Darwin.read(fd, raw.baseAddress, raw.count)
                    if r < 0 {
                        if errno == EINTR { continue }
                        return -Int(errno)
                    }
                    return r
                }
            }
            if n <= 0 { return }  // error or EOF
            buffer.append(contentsOf: readBuf.prefix(n))

            while let nlIndex = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nlIndex]
                buffer.removeSubrange(buffer.startIndex...nlIndex)
                if line.isEmpty { continue }

                let response = await dispatch(messageBytes: Data(line), manager: manager)
                var bytes = response
                bytes.append(0x0A)
                // A write failure here means the client went away; nothing to do.
                try? UnixSocketIO.writeAll(fd: fd, data: bytes)
            }
        }
    }

    // MARK: - Dispatch

    private static func dispatch(messageBytes: Data, manager: SessionManager) async -> Data {
        var requestID = 0
        do {
            guard let obj = try JSONSerialization.jsonObject(with: messageBytes) as? [String: Any] else {
                return encodeError(id: 0, message: "expected JSON object")
            }
            requestID = obj["id"] as? Int ?? 0
            guard let method = obj["method"] as? String else {
                return encodeError(id: requestID, message: "missing `method`")
            }
            let paramsObj = obj["params"] as? [String: Any] ?? [:]
            let paramsData = try JSONSerialization.data(withJSONObject: paramsObj)

            switch method {
            case "launch":
                let p = try JSONDecoder().decode(LaunchParams.self, from: paramsData)
                let snap = try await manager.launch(binary: p.binary, args: p.args ?? [])
                return encodeOK(id: requestID, result: snap)

            case "sessions":
                let list = await manager.list()
                return encodeOK(id: requestID, result: list)

            case "break.set":
                let p = try JSONDecoder().decode(BreakSetParams.self, from: paramsData)
                let (snap, bp) = try await manager.setBreakpoint(
                    sessionId: p.sessionId, file: p.file, line: p.line
                )
                return encodeOK(id: requestID, result: BreakSetResult(snapshot: snap, breakpoint: bp))

            case "continue":
                let p = try JSONDecoder().decode(SessionParams.self, from: paramsData)
                let snap = try await manager.continueExecution(sessionId: p.sessionId)
                return encodeOK(id: requestID, result: snap)

            case "bt":
                let p = try JSONDecoder().decode(BtParams.self, from: paramsData)
                let frames = try await manager.backtrace(
                    sessionId: p.sessionId, threadId: p.threadId, depth: p.depth
                )
                return encodeOK(id: requestID, result: BacktraceResult(frames: frames))

            case "locals":
                let p = try JSONDecoder().decode(LocalsParams.self, from: paramsData)
                let locals = try await manager.locals(
                    sessionId: p.sessionId, threadId: p.threadId, frameIndex: p.frame ?? 0
                )
                return encodeOK(id: requestID, result: LocalsResult(locals: locals))

            case "stop":
                let p = try JSONDecoder().decode(SessionParams.self, from: paramsData)
                _ = try await manager.stop(sessionId: p.sessionId)
                return encodeOK(id: requestID, result: StopResult(ok: true))

            default:
                return encodeError(id: requestID, message: "unknown method: \(method)")
            }
        } catch {
            return encodeError(id: requestID, message: "\(error)")
        }
    }

    // MARK: - JSON-RPC encoding

    private static func encodeOK<T: Encodable>(id: Int, result: T) -> Data {
        do {
            return try JSONEncoder().encode(RPCResult(id: id, result: result))
        } catch {
            return encodeError(id: id, message: "encode failed: \(error)")
        }
    }

    private static func encodeError(id: Int, message: String) -> Data {
        (try? JSONEncoder().encode(RPCError(id: id, error: message))) ?? Data()
    }
}

private struct RPCResult<T: Encodable>: Encodable {
    let id: Int
    let result: T
}

private struct RPCError: Encodable {
    let id: Int
    let error: String
}

// MARK: - Helpers

private func bindUnixSocket(fd: Int32, path: String) throws {
    let rc = try UnixSocketIO.withSockaddr(path: path) { sptr, len in
        Darwin.bind(fd, sptr, len)
    }
    guard rc == 0 else {
        throw LlmdbError.daemonUnreachable("bind(\(path)) failed (errno \(errno))")
    }
}
