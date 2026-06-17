import Foundation

/// Owns the set of live debug sessions. Drives the DAP handshake per session,
/// tracks the most recent stop event, and exposes the high-level M1 verbs.
///
/// Event fan-out: only the listener Task consumes `DAPClient.events` directly;
/// per-call waiters subscribe via `subscribe(entryID:)` to receive a buffered
/// copy. This avoids the classic single-consumer race where the listener and a
/// waiter compete for the same event.
actor SessionManager {

    private var sessions: [String: SessionEntry] = [:]
    private var subscribers: [String: [Subscriber]] = [:]

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

    private struct Subscriber: Sendable {
        let id: UUID
        let continuation: AsyncStream<DAPEvent>.Continuation
    }

    // MARK: - Public API

    func list() -> [Session] {
        sessions.values.map(\.info)
    }

    /// Launch a binary under lldb-dap. Stops on entry so subsequent
    /// `break set` calls have a quiescent target.
    func launch(binary: String, args: [String]) async throws -> SessionSnapshot {
        let id = Self.makeID()
        let client = try DAPClient()
        let info = Session(
            id: id,
            target: .launched(binary: binary, args: args),
            state: .initializing,
            stopReason: nil
        )
        let entry = SessionEntry(id: id, client: client, info: info)
        sessions[id] = entry

        startListener(entry)

        do {
            try await handshake(entry, launch: true, binary: binary, args: args, pid: nil)
        } catch {
            await client.terminate()
            sessions.removeValue(forKey: id)
            subscribers.removeValue(forKey: id)
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
        let model = Breakpoint(
            id: bp.id ?? 0,
            verified: bp.verified,
            line: bp.line,
            source: bp.source?.path ?? file,
            message: bp.message
        )
        if let bid = bp.id { entry.breakpoints[bid] = model }
        return (snapshot(entry), model)
    }

    func continueExecution(sessionId: String?) async throws -> SessionSnapshot {
        let entry = try resolve(sessionId)
        let threadId = entry.stoppedThreadId ?? 1
        entry.info.state = .running
        entry.info.stopReason = nil

        // Register the waiter BEFORE sending continue so we don't miss the stop.
        let waiter = waitForStateChange(entry, timeout: 60)
        _ = try await entry.client.request(
            "continue",
            arguments: ContinueArgs(threadId: threadId)
        )
        try await waiter.value
        return snapshot(entry)
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
        let resp = try await entry.client.request(
            "stackTrace",
            arguments: StackTraceArgs(threadId: tid, startFrame: 0, levels: depth ?? 64)
        )
        let body = try resp.decodeBody(StackTraceBody.self)
        return body.stackFrames.map {
            Frame(id: $0.id, name: $0.name, source: $0.source?.path, line: $0.line, column: $0.column)
        }
    }

    func locals(
        sessionId: String?,
        threadId: Int? = nil,
        frameIndex: Int = 0
    ) async throws -> [Local] {
        let frames = try await backtrace(sessionId: sessionId, threadId: threadId)
        guard frameIndex >= 0, frameIndex < frames.count else {
            throw LlmdbError.invalidArgument(
                name: "frame",
                value: "\(frameIndex)",
                valid: (0..<frames.count).map(String.init)
            )
        }
        let entry = try resolve(sessionId)
        let frameId = frames[frameIndex].id
        let scopesResp = try await entry.client.request(
            "scopes",
            arguments: ScopesArgs(frameId: frameId)
        )
        let scopes = try scopesResp.decodeBody(ScopesBody.self).scopes
        guard let localsScope = scopes.first(where: { $0.name == "Locals" }) else {
            return []
        }
        let varsResp = try await entry.client.request(
            "variables",
            arguments: VariablesArgs(variablesReference: localsScope.variablesReference)
        )
        let body = try varsResp.decodeBody(VariablesBody.self)
        return body.variables.map {
            Local(name: $0.name, type: $0.type, value: $0.value, variablesReference: $0.variablesReference)
        }
    }

    @discardableResult
    func stop(sessionId: String?) async throws -> Bool {
        let entry = try resolve(sessionId)
        entry.listener?.cancel()
        await entry.client.terminate()
        sessions.removeValue(forKey: entry.id)
        // Finish any lingering subscribers so their awaiters don't hang.
        for sub in subscribers[entry.id] ?? [] { sub.continuation.finish() }
        subscribers.removeValue(forKey: entry.id)
        return true
    }

    // MARK: - Subscriber fan-out

    /// Create a per-call event subscription for a session. The caller is the
    /// sole consumer of the returned stream. The stream finishes when the
    /// session ends.
    private func subscribe(entryID: String) -> AsyncStream<DAPEvent> {
        let subID = UUID()
        var captured: AsyncStream<DAPEvent>.Continuation!
        let stream = AsyncStream<DAPEvent>(bufferingPolicy: .unbounded) { captured = $0 }
        captured.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeSubscriber(entryID: entryID, subscriberID: subID) }
        }
        subscribers[entryID, default: []].append(Subscriber(id: subID, continuation: captured))
        return stream
    }

    private func removeSubscriber(entryID: String, subscriberID: UUID) {
        subscribers[entryID]?.removeAll { $0.id == subscriberID }
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

    private func handshake(
        _ entry: SessionEntry,
        launch: Bool,
        binary: String?,
        args: [String],
        pid: Int32?
    ) async throws {
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

        // Subscribe BEFORE sending launch so we don't miss `initialized`.
        let initWaiter = waitForEvent(entry, named: "initialized", timeout: 10)

        if launch, let binary {
            _ = try await entry.client.request(
                "launch",
                arguments: LaunchArgs(program: binary, args: args, stopOnEntry: true)
            )
        } else if let pid {
            _ = try await entry.client.request(
                "attach",
                arguments: AttachArgs(pid: Int(pid))
            )
        } else {
            throw LlmdbError.dapFailure("handshake called with neither launch binary nor pid")
        }

        try await initWaiter.value

        // After `initialized`, send configurationDone, then wait for the
        // entry-stop (we asked for stopOnEntry).
        let stopWaiter = waitForStateChange(entry, timeout: 10)
        _ = try await entry.client.request("configurationDone")
        try await stopWaiter.value
    }

    private func startListener(_ entry: SessionEntry) {
        entry.listener = Task { [weak self, weak entry] in
            guard let entry else { return }
            for await event in entry.client.events {
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
            if let body = try? event.decodeBody(BreakpointEventBody.self),
               let bid = body.breakpoint.id {
                entry.breakpoints[bid] = Breakpoint(
                    id: bid,
                    verified: body.breakpoint.verified,
                    line: body.breakpoint.line,
                    source: body.breakpoint.source?.path,
                    message: body.breakpoint.message
                )
            }
        default:
            break
        }
        // Fan out to per-call subscribers.
        for sub in subscribers[entryID] ?? [] {
            sub.continuation.yield(event)
        }
    }

    private func markTerminated(entryID: String) {
        guard let entry = sessions[entryID] else { return }
        entry.info.state = .terminated
        for sub in subscribers[entryID] ?? [] { sub.continuation.finish() }
        subscribers.removeValue(forKey: entryID)
    }

    private func waitForEvent(
        _ entry: SessionEntry,
        named: String,
        timeout: TimeInterval
    ) -> Task<Void, Error> {
        waitForEvent(entry, timeout: timeout, label: named) { $0.event == named }
    }

    private func waitForStateChange(
        _ entry: SessionEntry,
        timeout: TimeInterval
    ) -> Task<Void, Error> {
        waitForEvent(entry, timeout: timeout, label: "stop/terminate") {
            $0.event == "stopped" || $0.event == "terminated" || $0.event == "exited"
        }
    }

    private func waitForEvent(
        _ entry: SessionEntry,
        timeout: TimeInterval,
        label: String,
        matching: @escaping @Sendable (DAPEvent) -> Bool
    ) -> Task<Void, Error> {
        let stream = subscribe(entryID: entry.id)
        return Task {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await event in stream where matching(event) { return }
                    throw DAPError.closed
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw LlmdbError.dapFailure("timed out waiting for `\(label)` event")
                }
                _ = try await group.next()!
                group.cancelAll()
            }
        }
    }

    private static func makeID() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }
}

// MARK: - DAP wire types (private to SessionManager)

private struct InitializeArgs: Encodable, Sendable {
    let clientID: String
    let clientName: String
    let adapterID: String
    let linesStartAt1: Bool
    let columnsStartAt1: Bool
    let pathFormat: String
    let supportsRunInTerminalRequest: Bool
}

private struct LaunchArgs: Encodable, Sendable {
    let program: String
    let args: [String]
    let stopOnEntry: Bool
}

private struct AttachArgs: Encodable, Sendable {
    let pid: Int
}

private struct SourceArg: Encodable, Decodable, Sendable {
    let path: String?
    let name: String?
    init(path: String) { self.path = path; self.name = nil }
}

private struct BPLine: Encodable, Sendable {
    let line: Int
}

private struct SetBreakpointsArgs: Encodable, Sendable {
    let source: SourceArg
    let breakpoints: [BPLine]
}

private struct SetBreakpointsBody: Decodable, Sendable {
    let breakpoints: [DAPBreakpointInfo]
}

private struct DAPBreakpointInfo: Decodable, Sendable {
    let id: Int?
    let verified: Bool
    let line: Int?
    let source: SourceArg?
    let message: String?
}

private struct BreakpointEventBody: Decodable, Sendable {
    let reason: String
    let breakpoint: DAPBreakpointInfo
}

private struct ContinueArgs: Encodable, Sendable {
    let threadId: Int
}

private struct StackTraceArgs: Encodable, Sendable {
    let threadId: Int
    let startFrame: Int
    let levels: Int
}

private struct StackTraceBody: Decodable, Sendable {
    let stackFrames: [DAPFrame]
}

private struct DAPFrame: Decodable, Sendable {
    let id: Int
    let name: String
    let source: SourceArg?
    let line: Int?
    let column: Int?
}

private struct ScopesArgs: Encodable, Sendable {
    let frameId: Int
}

private struct ScopesBody: Decodable, Sendable {
    let scopes: [DAPScope]
}

private struct DAPScope: Decodable, Sendable {
    let name: String
    let variablesReference: Int
}

private struct VariablesArgs: Encodable, Sendable {
    let variablesReference: Int
}

private struct VariablesBody: Decodable, Sendable {
    let variables: [DAPVariable]
}

private struct DAPVariable: Decodable, Sendable {
    let name: String
    let value: String
    let type: String?
    let variablesReference: Int
}

private struct StoppedEventBody: Decodable, Sendable {
    let reason: String
    let threadId: Int?
    let description: String?
    let hitBreakpointIds: [Int]?
}
