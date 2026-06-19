import Foundation

/// Owns the set of live debug sessions. Drives the DAP handshake per session,
/// tracks the most recent stop event, and exposes the high-level M1 verbs.
///
/// Event multiplexing lives in `DAPClient` itself — SessionManager just
/// subscribes to its own listener stream and asks `client.waitForEvent(...)`
/// for the per-call awaits. No subscriber bookkeeping here.
actor SessionManager {
    private var sessions: [String: SessionEntry] = [:]

    private final class SessionEntry: @unchecked Sendable {
        let id: String
        let client: DAPClient
        var info: Session
        var stoppedThreadId: Int?
        var listener: Task<Void, Never>?
        var breakpoints: [Int: Breakpoint] = [:]

        init(id: String, client: DAPClient, info: Session) {
            self.id = id
            self.client = client
            self.info = info
        }
    }

    // MARK: - Public API

    func list() -> [Session] {
        sessions.values.map(\.info)
    }

    /// Launch a binary under lldb-dap. Stops on entry so subsequent
    /// `break set` calls have a quiescent target. For `.app` bundles, routes
    /// through LaunchServices so the process is registered with WindowServer/
    /// AppKit (required for AX-driven tools to see the app).
    func launch(binary: String, args: [String]) async throws -> SessionSnapshot {
        if let appURL = AppBundleLauncher.appBundleURL(for: binary) {
            let pid = try await AppBundleLauncher.openApplication(at: appURL, args: args)
            return try await attach(pid: pid)
        }
        return try await openSession(target: .launched(binary: binary, args: args))
    }

    /// Attach to a running process. lldb-dap pauses the target on attach,
    /// so the returned snapshot is `.stopped`.
    func attach(pid: Int32) async throws -> SessionSnapshot {
        try await openSession(target: .attached(pid: pid))
    }

    /// Common path for launch/attach: open a DAPClient, run the handshake,
    /// register the session (or roll back on failure).
    private func openSession(target: Session.Target) async throws -> SessionSnapshot {
        let id = Self.makeID()
        let client = try await DAPClient.spawn()
        let entry = SessionEntry(
            id: id,
            client: client,
            info: Session(id: id, target: target, state: .initializing, stopReason: nil)
        )
        sessions[id] = entry
        startListener(entry)

        do {
            try await handshake(entry, target: target)
        } catch {
            await client.terminate()
            sessions.removeValue(forKey: id)
            throw error
        }
        return snapshot(entry)
    }

    func setBreakpoint(
        sessionId: String?,
        file: String,
        line: Int
    ) async throws -> (SessionSnapshot, Breakpoint) {
        let entry = try resolve(sessionId)
        let resp = try await entry.client.request(
            "setBreakpoints",
            arguments: SetBreakpointsArgs(
                source: .init(path: file),
                breakpoints: [.init(line: line)]
            )
        )
        let body = try resp.decodeBody(SetBreakpointsBody.self)
        guard let bp = body.breakpoints.first else {
            throw LlmdbError.dapFailure("setBreakpoints returned no breakpoint")
        }
        // Stock message for unverified BPs so callers don't panic at `verified: false`.
        let message = bp.message ?? (bp.verified
            ? nil
            :
            "verification deferred until module loads — common for breakpoints set before launch or in lazily-loaded modules")
        let model = Breakpoint(
            id: bp.id ?? 0,
            verified: bp.verified,
            line: bp.line,
            source: bp.source?.path ?? file,
            message: message
        )
        if let bid = bp.id { entry.breakpoints[bid] = model }
        return (snapshot(entry), model)
    }

    func continueExecution(sessionId: String?, wait: Double? = nil) async throws -> SessionSnapshot {
        try await runUntilStop(sessionId: sessionId, command: "continue", wait: wait ?? 60)
    }

    /// Set a breakpoint and continue in one call. Returns the post-continue
    /// snapshot (stopped at the breakpoint, hopefully) plus the breakpoint
    /// itself so the caller can clean it up later.
    func runUntil(
        sessionId: String?,
        file: String,
        line: Int,
        wait: Double? = nil
    ) async throws -> (SessionSnapshot, Breakpoint) {
        let (_, bp) = try await setBreakpoint(sessionId: sessionId, file: file, line: line)
        let snap = try await continueExecution(sessionId: sessionId, wait: wait)
        return (snap, bp)
    }

    /// Pause a running session. Returns once the target is stopped.
    func interrupt(sessionId: String?, wait: Double? = nil) async throws -> SessionSnapshot {
        try await runUntilStop(sessionId: sessionId, command: "pause", wait: wait ?? 10)
    }

    /// Step one source line. `granularity` picks the DAP command:
    /// `.over` → next, `.in` → stepIn, `.out` → stepOut.
    func step(
        sessionId: String?,
        granularity: StepGranularity,
        wait: Double? = nil
    ) async throws -> SessionSnapshot {
        try await runUntilStop(sessionId: sessionId, command: granularity.dapCommand, wait: wait ?? 30)
    }

    /// Block until the session leaves `.running` (i.e., stops or terminates).
    /// Returns immediately if already stopped/terminated.
    func wait(sessionId: String?, timeout: Double? = nil) async throws -> SessionSnapshot {
        let entry = try resolve(sessionId)
        if entry.info.state != .running {
            return snapshot(entry)
        }
        let waiter = await entry.client.waitForEvent(timeout: timeout ?? 60) {
            $0.event == "stopped" || $0.event == "terminated" || $0.event == "exited"
        }
        _ = try await waiter.value
        return snapshot(entry)
    }

    /// `wait == 0` → fire-and-forget; otherwise block up to `wait` seconds.
    private func runUntilStop(
        sessionId: String?,
        command: String,
        wait: Double
    ) async throws -> SessionSnapshot {
        let entry = try resolve(sessionId)
        let threadId = entry.stoppedThreadId ?? 1

        if wait == 0 {
            _ = try await entry.client.request(command, arguments: ThreadIdArgs(threadId: threadId))
            // Optimistic — listener overwrites when the real continued/stopped event lands.
            entry.info.state = .running
            entry.info.stopReason = nil
            return snapshot(entry)
        }

        // Subscribe BEFORE sending so we don't miss the stop.
        let waiter = await entry.client.waitForEvent(timeout: wait) {
            $0.event == "stopped" || $0.event == "terminated" || $0.event == "exited"
        }
        _ = try await entry.client.request(command, arguments: ThreadIdArgs(threadId: threadId))
        _ = try await waiter.value
        return snapshot(entry)
    }

    func threads(sessionId: String?) async throws -> [Thread] {
        let entry = try resolve(sessionId)
        let resp = try await entry.client.request("threads")
        return try resp.decodeBody(ThreadsBody.self).threads.map {
            Thread(id: $0.id, name: $0.name)
        }
    }

    /// Evaluate an expression in the context of a stack frame (default: top
    /// frame of the stopped thread). Returns the raw result string lldb
    /// produced — same shape as `locals` values.
    func evaluate(
        sessionId: String?,
        expression: String,
        frameIndex: Int = 0
    ) async throws -> (value: String, type: String?, variablesReference: Int) {
        let entry = try resolve(sessionId)
        guard let tid = entry.stoppedThreadId else {
            throw LlmdbError.dapFailure("no stopped thread; expr requires a paused session")
        }
        // Fetch just the one frame so we can pass its frameId for context.
        let frames = try await fetchFrames(entry, threadId: tid, startFrame: frameIndex, levels: 1)
        guard let frame = frames.first else {
            throw LlmdbError.invalidArgument(name: "frame", value: "\(frameIndex)", valid: ["0..<stack depth"])
        }
        // context="watch" returns just the value (e.g. "20") instead of the
        // REPL's verbose "(Int) $R0 = 20" form. Closer to what locals returns.
        let resp = try await entry.client.request(
            "evaluate",
            arguments: EvaluateArgs(expression: expression, frameId: frame.id, context: "watch")
        )
        let body = try resp.decodeBody(EvaluateBody.self)
        return (body.result, body.type, body.variablesReference)
    }

    /// All breakpoints currently tracked for the session, sorted by id.
    func listBreakpoints(sessionId: String?) throws -> [Breakpoint] {
        let entry = try resolve(sessionId)
        return entry.breakpoints.values.sorted { $0.id < $1.id }
    }

    /// Delete a breakpoint by id. DAP has no per-id delete: we look up the
    /// breakpoint's source, then re-issue `setBreakpoints` for that source
    /// with the surviving lines.
    func deleteBreakpoint(sessionId: String?, id: Int) async throws -> [Breakpoint] {
        let entry = try resolve(sessionId)
        guard let doomed = entry.breakpoints[id] else {
            throw LlmdbError.invalidArgument(
                name: "id",
                value: "\(id)",
                valid: entry.breakpoints.keys.map { String($0) }
            )
        }
        guard let source = doomed.source else {
            throw LlmdbError.dapFailure("breakpoint \(id) has no source path; cannot rebuild setBreakpoints")
        }
        let survivors = entry.breakpoints.values
            .filter { $0.source == source && $0.id != id }
            .compactMap { $0.line.map { BPLine(line: $0) } }

        let resp = try await entry.client.request(
            "setBreakpoints",
            arguments: SetBreakpointsArgs(source: .init(path: source), breakpoints: survivors)
        )
        // Re-sync our tracking for this source from the response. lldb-dap
        // returns the surviving BPs with their (possibly new) ids.
        for old in entry.breakpoints.values where old.source == source {
            entry.breakpoints.removeValue(forKey: old.id)
        }
        let body = try resp.decodeBody(SetBreakpointsBody.self)
        for bp in body.breakpoints {
            guard let bid = bp.id else { continue }
            entry.breakpoints[bid] = Breakpoint(
                id: bid,
                verified: bp.verified,
                line: bp.line,
                source: bp.source?.path ?? source,
                message: bp.message
            )
        }
        return entry.breakpoints.values.sorted { $0.id < $1.id }
    }

    func backtrace(
        sessionId: String?,
        threadId: Int? = nil,
        depth: Int? = nil
    ) async throws -> [Frame] {
        let entry = try resolve(sessionId)
        guard let tid = threadId ?? entry.stoppedThreadId else {
            throw LlmdbError.dapFailure("no stopped thread; is the session running?")
        }
        let frames = try await fetchFrames(entry, threadId: tid, startFrame: 0, levels: depth ?? 64)
        return frames.map {
            Frame(id: $0.id, name: $0.name, source: $0.source?.path, line: $0.line, column: $0.column)
        }
    }

    func locals(
        sessionId: String?,
        threadId: Int? = nil,
        frameIndex: Int = 0
    ) async throws -> [Local] {
        let entry = try resolve(sessionId)
        guard let tid = threadId ?? entry.stoppedThreadId else {
            throw LlmdbError.dapFailure("no stopped thread; is the session running?")
        }
        guard frameIndex >= 0 else {
            throw LlmdbError.invalidArgument(name: "frame", value: "\(frameIndex)", valid: ["0+"])
        }
        // Fetch just the one frame we need — not the full stack.
        let frames = try await fetchFrames(entry, threadId: tid, startFrame: frameIndex, levels: 1)
        guard let frame = frames.first else {
            throw LlmdbError.invalidArgument(name: "frame", value: "\(frameIndex)", valid: ["0..<stack depth"])
        }

        let scopesResp = try await entry.client.request("scopes", arguments: ScopesArgs(frameId: frame.id))
        let scopes = try scopesResp.decodeBody(ScopesBody.self).scopes
        guard let localsScope = scopes.first(where: { $0.name == "Locals" }) else { return [] }

        let varsResp = try await entry.client.request(
            "variables",
            arguments: VariablesArgs(variablesReference: localsScope.variablesReference)
        )
        return try varsResp.decodeBody(VariablesBody.self).variables.map {
            Local(name: $0.name, type: $0.type, value: $0.value, variablesReference: $0.variablesReference)
        }
    }

    @discardableResult
    func stop(sessionId: String?) async throws -> Bool {
        let entry = try resolve(sessionId)
        entry.listener?.cancel()
        await entry.client.terminate()
        sessions.removeValue(forKey: entry.id)
        return true
    }

    // MARK: - Internals

    private func resolve(_ sessionId: String?) throws -> SessionEntry {
        if let sessionId {
            guard let entry = sessions[sessionId] else { throw LlmdbError.sessionNotFound(sessionId) }
            return entry
        }
        if sessions.count == 1, let only = sessions.values.first { return only }
        if sessions.isEmpty { throw LlmdbError.sessionNotFound("(none active)") }
        throw LlmdbError.sessionNotFound("(multiple active; pass --session)")
    }

    private func snapshot(_ entry: SessionEntry) -> SessionSnapshot {
        SessionSnapshot(
            sessionId: entry.id,
            state: entry.info.state,
            stopReason: entry.info.stopReason,
            topFrame: nil
        )
    }

    private func fetchFrames(
        _ entry: SessionEntry,
        threadId: Int,
        startFrame: Int,
        levels: Int
    ) async throws -> [DAPFrame] {
        let resp = try await entry.client.request(
            "stackTrace",
            arguments: StackTraceArgs(threadId: threadId, startFrame: startFrame, levels: levels)
        )
        return try resp.decodeBody(StackTraceBody.self).stackFrames
    }

    private func handshake(_ entry: SessionEntry, target: Session.Target) async throws {
        // Subscribe to `initialized` BEFORE sending the initialize request.
        // lldb-dap can emit it right after the initialize response, before
        // launch/attach is sent — subscribing later races and loses.
        let initWaiter = await entry.client.waitForEvent(timeout: 10) { $0.event == "initialized" }

        _ = try await entry.client.request(
            "initialize",
            arguments: InitializeArgs(
                clientID: "llmdb",
                clientName: "llmdb",
                adapterID: "lldb-dap",
                linesStartAt1: true,
                columnsStartAt1: true,
                pathFormat: "path",
                supportsRunInTerminalRequest: false
            )
        )

        switch target {
        case .launched(let binary, let args):
            _ = try await entry.client.request(
                "launch",
                arguments: LaunchArgs(program: binary, args: args, stopOnEntry: true)
            )
        case .attached(let pid):
            _ = try await entry.client.request(
                "attach",
                arguments: AttachArgs(pid: Int(pid), stopOnEntry: true)
            )
        case .simulator:
            throw LlmdbError.notImplemented("simulator attach (M2)")
        }

        _ = try await initWaiter.value

        // After `initialized`, send configurationDone; the stopOnEntry stop
        // arrives shortly after.
        let stopWaiter = await entry.client.waitForEvent(timeout: 10) {
            $0.event == "stopped" || $0.event == "terminated" || $0.event == "exited"
        }
        _ = try await entry.client.request("configurationDone")
        _ = try await stopWaiter.value
    }

    private func startListener(_ entry: SessionEntry) {
        entry.listener = Task { [weak self, weak entry] in
            guard let entry else { return }
            let stream = await entry.client.events()
            for await event in stream {
                await self?.handleEvent(event, entryID: entry.id)
            }
            await self?.markTerminated(entryID: entry.id)
        }
    }

    private func handleEvent(_ event: DAPEvent, entryID: String) async {
        guard let entry = sessions[entryID] else { return }
        switch event.event {
        case "stopped":
            if let body = try? event.decodeBody(StoppedEventBody.self) {
                entry.info.state = .stopped
                entry.info.stopReason = StopReason(
                    reason: body.reason,
                    threadID: body.threadId ?? entry.stoppedThreadId ?? 1,
                    description: body.description,
                    hitBreakpointIDs: body.hitBreakpointIds
                )
                entry.stoppedThreadId = body.threadId ?? entry.stoppedThreadId
            }
        case "continued":
            entry.info.state = .running
            entry.info.stopReason = nil
        case "terminated", "exited":
            entry.info.state = .terminated
        case "breakpoint":
            // `breakpoint` events are typically updates (verified status flips
            // as modules load) and may omit source/line. Merge with what we
            // already have so we don't blow away the original source path.
            if let body = try? event.decodeBody(BreakpointEventBody.self),
               let bid = body.breakpoint.id {
                let existing = entry.breakpoints[bid]
                entry.breakpoints[bid] = Breakpoint(
                    id: bid,
                    verified: body.breakpoint.verified,
                    line: body.breakpoint.line ?? existing?.line,
                    source: body.breakpoint.source?.path ?? existing?.source,
                    message: body.breakpoint.message ?? existing?.message
                )
            }
        default:
            break
        }
    }

    private func markTerminated(entryID: String) {
        sessions[entryID]?.info.state = .terminated
    }

    private static func makeID() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }
}
