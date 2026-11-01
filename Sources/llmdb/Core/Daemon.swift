import Darwin
import Foundation

/// `llmdbd` — a small JSON-RPC server over a Unix socket that exposes
/// `SessionManager`'s verbs to CLI / MCP clients.
///
/// Wire format: newline-delimited JSON. Single user, no auth. One client per
/// accepted connection; a client may pipeline many requests, each handled in
/// the order they arrive.
///
/// Methods, with their params and result types, are listed in `RPC`
/// (RPCTypes.swift).
public final class Daemon: @unchecked Sendable {
    /// Where the daemon binds and where clients connect. Default is
    /// `~/Library/Caches/llmdb/llmdbd.sock`; override via the
    /// `LLMDB_SOCKET_PATH` env var when you need isolated daemons (e.g.,
    /// two MCP-driven agents that shouldn't share sessions).
    ///
    /// The CLI's auto-spawn inherits the parent's environment, so a child
    /// daemon picks up the same path automatically — no extra plumbing.
    public static var defaultSocketPath: String {
        if let override = ProcessInfo.processInfo.environment["LLMDB_SOCKET_PATH"],
           !override.isEmpty {
            return override
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Caches/llmdb/llmdbd.sock").path
    }

    private let socketPath: String
    private let handlers = Daemon.handlers(manager: SessionManager())
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "llmdbd-accept")
    private var signalSources: [DispatchSourceSignal] = []

    public init(socketPath: String = Daemon.defaultSocketPath) {
        self.socketPath = socketPath
    }

    public func start() throws {
        // Pin the build ID now, before the binary on disk can be replaced.
        _ = DaemonBuild.current
        let parent = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: parent, withIntermediateDirectories: true
        )
        _ = Darwin.unlink(socketPath)

        listenFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw LlmdbError.daemonUnreachable("socket() failed (errno \(errno))")
        }

        let bindRC = try UnixSocketIO.withSockaddr(path: socketPath) { sptr, len in
            Darwin.bind(listenFD, sptr, len)
        }
        guard bindRC == 0 else {
            throw LlmdbError.daemonUnreachable("bind(\(socketPath)) failed (errno \(errno))")
        }
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
        acceptSource = source

        installSignalHandlers()

        FileHandle.standardError.write(Data("llmdbd listening on \(socketPath)\n".utf8))
    }

    /// Unlink the socket file on SIGINT/SIGTERM/SIGHUP so `llmdb doctor` doesn't
    /// later report a stale socket. SIGKILL and segfaults can't be caught;
    /// `DaemonClient.connectOrSpawn` recovers from those by detecting ECONNREFUSED
    /// and unlinking before respawning.
    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            // Default disposition (terminate) fires immediately unless we suppress it
            // — only then does the dispatch source get a chance to run.
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { [weak self] in
                self?.shutdown()
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func shutdown() {
        FileHandle.standardError.write(Data("llmdbd shutting down, unlinking \(socketPath)\n".utf8))
        _ = Darwin.unlink(socketPath)
        exit(0)
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
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }
                if errno == EINTR {
                    continue
                }
                return
            }
            // On BSD/macOS the accepted socket inherits the listen socket's
            // O_NONBLOCK flag. We want blocking reads inside handleClient,
            // so clear it explicitly.
            let flags = Darwin.fcntl(clientFD, F_GETFL, 0)
            _ = Darwin.fcntl(clientFD, F_SETFL, flags & ~O_NONBLOCK)

            let handlers = handlers
            Task { await Self.handleClient(fd: clientFD, handlers: handlers) }
        }
    }

    private static func handleClient(fd: Int32, handlers: [String: Handler]) async {
        defer { Darwin.close(fd) }
        var buffer = Data()
        var readBuf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = readBuf.withUnsafeMutableBytes { raw -> Int in
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
            if n <= 0 {
                return
            } // error or EOF
            buffer.append(contentsOf: readBuf.prefix(n))

            while let nlIndex = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nlIndex]
                buffer.removeSubrange(buffer.startIndex...nlIndex)
                if line.isEmpty {
                    continue
                }

                let response = await dispatch(Data(line), handlers: handlers)
                var bytes = response
                bytes.append(0x0A)
                // A write failure here means the client went away; nothing to do.
                try? UnixSocketIO.writeAll(fd: fd, data: bytes)
            }
        }
    }

    // MARK: - Dispatch

    /// Decodes one request line's params, runs the method, and encodes the
    /// whole response envelope.
    private typealias Handler = @Sendable (_ id: Int, _ request: Data) async throws -> Data

    private static func dispatch(_ request: Data, handlers: [String: Handler]) async -> Data {
        guard let header = try? JSONDecoder().decode(RPCRequestHeader.self, from: request) else {
            return encodeError(id: 0, message: "expected JSON object")
        }
        guard let method = header.method else {
            return encodeError(id: header.id, message: "missing `method`")
        }
        guard let handler = handlers[method] else {
            return encodeError(id: header.id, message: "unknown method: \(method)")
        }
        do {
            return try await handler(header.id, request)
        } catch {
            return encodeError(id: header.id, message: "\(error)")
        }
    }

    /// One handler per `RPC` method. Building the table traps on a duplicate
    /// name, so a copy-pasted registration fails on the first daemon start.
    private static func handlers(manager: SessionManager) -> [String: Handler] {
        Dictionary(uniqueKeysWithValues: [
            register(RPC.version) { _ in
                DaemonInfo(version: llmdbVersion, build: DaemonBuild.current)
            },
            register(RPC.launch) { p in
                try await manager.launch(binary: p.binary, args: p.args ?? [], timeout: p.timeout)
            },
            register(RPC.attach) { p in
                try await manager.attach(pid: resolveAttachPID(p), timeout: p.timeout)
            },
            register(RPC.sessions) { _ in
                await manager.list()
            },
            register(RPC.breakSet) { p in
                let (snap, bp) = try await manager.setBreakpoint(
                    sessionId: p.sessionId,
                    file: p.file,
                    line: p.line,
                    condition: p.condition,
                    hitCondition: p.hitCondition
                )
                return BreakSetResult(snapshot: snap, breakpoint: bp)
            },
            register(RPC.breakList) { p in
                try await BreakListResult(breakpoints: manager.listBreakpoints(sessionId: p.sessionId))
            },
            register(RPC.breakDelete) { p in
                try await BreakListResult(breakpoints: manager.deleteBreakpoint(sessionId: p.sessionId, id: p.id))
            },
            register(RPC.breakException) { p in
                let (available, enabled) = try await manager.setExceptionBreakpoints(
                    sessionId: p.sessionId, filters: p.filters
                )
                return BreakExceptionResult(available: available, enabled: enabled)
            },
            register(RPC.continue) { p in
                try await manager.continueExecution(sessionId: p.sessionId, wait: p.wait)
            },
            register(RPC.runUntil) { p in
                let (snap, bp) = try await manager.runUntil(
                    sessionId: p.sessionId, file: p.file, line: p.line, wait: p.wait
                )
                return BreakSetResult(snapshot: snap, breakpoint: bp)
            },
            register(RPC.interrupt) { p in
                try await manager.interrupt(sessionId: p.sessionId, wait: p.wait)
            },
            register(RPC.step) { p in
                try await manager.step(sessionId: p.sessionId, granularity: p.granularity, wait: p.wait)
            },
            register(RPC.wait) { p in
                try await manager.wait(sessionId: p.sessionId, timeout: p.timeout)
            },
            register(RPC.backtrace) { p in
                try await BacktraceResult(
                    frames: manager.backtrace(sessionId: p.sessionId, threadId: p.threadId, depth: p.depth)
                )
            },
            register(RPC.locals) { p in
                try await LocalsResult(
                    locals: manager.locals(sessionId: p.sessionId, threadId: p.threadId, frameIndex: p.frame ?? 0)
                )
            },
            register(RPC.expand) { p in
                try await ExpandResult(
                    children: manager.expand(sessionId: p.sessionId, variablesReference: p.variablesReference)
                )
            },
            register(RPC.scopes) { p in
                try await ScopesResult(
                    scopes: manager.scopes(sessionId: p.sessionId, threadId: p.threadId, frameIndex: p.frame ?? 0)
                )
            },
            register(RPC.output) { p in
                try await OutputResult(output: manager.output(sessionId: p.sessionId, clear: p.clear ?? false))
            },
            register(RPC.setVar) { p in
                try await SetVarResult(variable: manager.setVariable(
                    sessionId: p.sessionId,
                    target: p.target,
                    value: p.value,
                    frameIndex: p.frame ?? 0
                ))
            },
            register(RPC.threads) { p in
                try await ThreadsResult(threads: manager.threads(sessionId: p.sessionId))
            },
            register(RPC.expr) { p in
                let r = try await manager.evaluate(
                    sessionId: p.sessionId, expression: p.expression, frameIndex: p.frame ?? 0
                )
                return ExprResult(value: r.value, type: r.type, variablesReference: r.variablesReference)
            },
            register(RPC.stop) { p in
                try await StopResult(ok: true, action: manager.stop(sessionId: p.sessionId, mode: p.mode))
            }
        ])
    }

    /// Pair a method's name with a handler typed by its params and result.
    private static func register<P, R>(
        _ method: RPCMethod<P, R>,
        _ body: @escaping @Sendable (P) async throws -> R
    ) -> (String, Handler) {
        (method.name, { id, request in
            let params = try JSONDecoder().decode(RPCParamsEnvelope<P>.self, from: request).params
                ?? JSONDecoder().decode(P.self, from: Data("{}".utf8))
            return try await encodeOK(id: id, result: body(params))
        })
    }

    /// Resolve `AttachParams` to a concrete host PID. Enforces the
    /// exactly-one-of-(pid, app) constraint that the flat JSON shape can't.
    private static func resolveAttachPID(_ p: AttachParams) async throws -> Int32 {
        switch (p.pid, p.app) {
        case (let pid?, nil):
            return pid
        case (nil, let bundleID?):
            return try await SimulatorResolver.resolvePID(bundleID: bundleID)
        case (nil, nil):
            throw LlmdbError.invalidArgument(
                name: "attach", value: "(nothing)", valid: ["pid", "app"]
            )
        case (_, _):
            throw LlmdbError.invalidArgument(
                name: "attach", value: "both pid and app", valid: ["one of pid or app"]
            )
        }
    }

    // MARK: - JSON-RPC encoding

    private static func encodeOK(id: Int, result: some Encodable) -> Data {
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
