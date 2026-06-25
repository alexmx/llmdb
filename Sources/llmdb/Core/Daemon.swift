import Darwin
import Foundation

/// `llmdbd` — a small JSON-RPC server over a Unix socket that exposes
/// `SessionManager`'s verbs to CLI / MCP clients.
///
/// Wire format: newline-delimited JSON. Single user, no auth. One client per
/// accepted connection; a client may pipeline many requests, each handled in
/// the order they arrive.
///
/// Methods:
///   launch        { binary: String, args: [String] }            → SessionSnapshot
///   attach        { pid?: Int32, app?: String }                 → SessionSnapshot
///                 // exactly one of pid/app; `app` resolves a bundle ID in
///                 // the booted iOS Simulator to a host PID via simctl.
///   sessions      {}                                            → [Session]
///   break.set     { sessionId?, file, line, condition?, hitCondition? } → { snapshot, breakpoint }
///   break.list    { sessionId? }                                → { breakpoints }
///   break.delete  { sessionId?, id }                            → { breakpoints }
///   break.exception { sessionId?, filters }                     → { available, enabled }
///   continue      { sessionId?, wait? }                         → SessionSnapshot
///   run-until     { sessionId?, file, line, wait? }             → { snapshot, breakpoint }
///   interrupt     { sessionId?, wait? }                         → SessionSnapshot
///   step          { sessionId?, granularity, wait? }            → SessionSnapshot
///   wait          { sessionId?, timeout? }                      → SessionSnapshot
///   bt            { sessionId?, depth? }                        → { frames }
///   locals        { sessionId?, frame? }                        → { locals }
///   expand        { sessionId?, variablesReference }            → { children }
///   output        { sessionId?, clear? }                        → { output }
///   set-var       { sessionId?, target, value, frame? }          → { variable }
///   threads       { sessionId? }                                → { threads }
///   expr          { sessionId?, expression, frame? }            → { value, type, variablesReference }
///   stop          { sessionId? }                                → { ok: true }
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
    private let manager = SessionManager()
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "llmdbd-accept")
    private var signalSources: [DispatchSourceSignal] = []

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
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                return
            }
            // On BSD/macOS the accepted socket inherits the listen socket's
            // O_NONBLOCK flag. We want blocking reads inside handleClient,
            // so clear it explicitly.
            let flags = Darwin.fcntl(clientFD, F_GETFL, 0)
            _ = Darwin.fcntl(clientFD, F_SETFL, flags & ~O_NONBLOCK)

            let mgr = manager
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
            if n <= 0 { return } // error or EOF
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
            func decode<P: Decodable>(_ type: P.Type) throws -> P {
                try JSONDecoder().decode(type, from: paramsData)
            }

            switch method {
            case "launch":
                let p = try decode(LaunchParams.self)
                let snap = try await manager.launch(binary: p.binary, args: p.args ?? [])
                return encodeOK(id: requestID, result: snap)

            case "attach":
                let p = try decode(AttachParams.self)
                let pid = try await resolveAttachPID(p)
                let snap = try await manager.attach(pid: pid)
                return encodeOK(id: requestID, result: snap)

            case "sessions":
                let list = await manager.list()
                return encodeOK(id: requestID, result: list)

            case "break.set":
                let p = try decode(BreakSetParams.self)
                let (snap, bp) = try await manager.setBreakpoint(
                    sessionId: p.sessionId,
                    file: p.file,
                    line: p.line,
                    condition: p.condition,
                    hitCondition: p.hitCondition
                )
                return encodeOK(id: requestID, result: BreakSetResult(snapshot: snap, breakpoint: bp))

            case "break.list":
                let p = try decode(SessionParams.self)
                let bps = try await manager.listBreakpoints(sessionId: p.sessionId)
                return encodeOK(id: requestID, result: BreakListResult(breakpoints: bps))

            case "break.delete":
                let p = try decode(BreakDeleteParams.self)
                let bps = try await manager.deleteBreakpoint(sessionId: p.sessionId, id: p.id)
                return encodeOK(id: requestID, result: BreakListResult(breakpoints: bps))

            case "break.exception":
                let p = try decode(BreakExceptionParams.self)
                let (available, enabled) = try await manager.setExceptionBreakpoints(
                    sessionId: p.sessionId, filters: p.filters
                )
                return encodeOK(
                    id: requestID,
                    result: BreakExceptionResult(available: available, enabled: enabled)
                )

            case "continue":
                let p = try decode(ExecParams.self)
                let snap = try await manager.continueExecution(sessionId: p.sessionId, wait: p.wait)
                return encodeOK(id: requestID, result: snap)

            case "run-until":
                let p = try decode(RunUntilParams.self)
                let (snap, bp) = try await manager.runUntil(
                    sessionId: p.sessionId, file: p.file, line: p.line, wait: p.wait
                )
                return encodeOK(id: requestID, result: BreakSetResult(snapshot: snap, breakpoint: bp))

            case "interrupt":
                let p = try decode(ExecParams.self)
                let snap = try await manager.interrupt(sessionId: p.sessionId, wait: p.wait)
                return encodeOK(id: requestID, result: snap)

            case "step":
                let p = try decode(StepParams.self)
                let snap = try await manager.step(
                    sessionId: p.sessionId, granularity: p.granularity, wait: p.wait
                )
                return encodeOK(id: requestID, result: snap)

            case "wait":
                let p = try decode(WaitParams.self)
                let snap = try await manager.wait(sessionId: p.sessionId, timeout: p.timeout)
                return encodeOK(id: requestID, result: snap)

            case "bt":
                let p = try decode(BtParams.self)
                let frames = try await manager.backtrace(
                    sessionId: p.sessionId, threadId: p.threadId, depth: p.depth
                )
                return encodeOK(id: requestID, result: BacktraceResult(frames: frames))

            case "locals":
                let p = try decode(LocalsParams.self)
                let locals = try await manager.locals(
                    sessionId: p.sessionId, threadId: p.threadId, frameIndex: p.frame ?? 0
                )
                return encodeOK(id: requestID, result: LocalsResult(locals: locals))

            case "expand":
                let p = try decode(ExpandParams.self)
                let children = try await manager.expand(
                    sessionId: p.sessionId, variablesReference: p.variablesReference
                )
                return encodeOK(id: requestID, result: ExpandResult(children: children))

            case "output":
                let p = try decode(OutputParams.self)
                let chunks = try await manager.output(sessionId: p.sessionId, clear: p.clear ?? false)
                return encodeOK(id: requestID, result: OutputResult(output: chunks))

            case "set-var":
                let p = try decode(SetVarParams.self)
                let variable = try await manager.setVariable(
                    sessionId: p.sessionId,
                    target: p.target,
                    value: p.value,
                    frameIndex: p.frame ?? 0
                )
                return encodeOK(id: requestID, result: SetVarResult(variable: variable))

            case "threads":
                let p = try decode(SessionParams.self)
                let ts = try await manager.threads(sessionId: p.sessionId)
                return encodeOK(id: requestID, result: ThreadsResult(threads: ts))

            case "expr":
                let p = try decode(ExprParams.self)
                let r = try await manager.evaluate(
                    sessionId: p.sessionId, expression: p.expression, frameIndex: p.frame ?? 0
                )
                return encodeOK(id: requestID, result: ExprResult(
                    value: r.value, type: r.type, variablesReference: r.variablesReference
                ))

            case "stop":
                let p = try decode(SessionParams.self)
                _ = try await manager.stop(sessionId: p.sessionId)
                return encodeOK(id: requestID, result: StopResult(ok: true))

            default:
                return encodeError(id: requestID, message: "unknown method: \(method)")
            }
        } catch {
            return encodeError(id: requestID, message: "\(error)")
        }
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
