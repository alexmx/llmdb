import Foundation

/// Speaks Debug Adapter Protocol to a child `lldb-dap` process.
///
/// Spawns lldb-dap, frames Content-Length-prefixed JSON over its stdio,
/// correlates request → response by `seq` via continuations, broadcasts
/// events to any number of subscribers obtained via `events()` or
/// `waitForEvent(...)`. One DAPClient = one lldb-dap process = one debug session.
///
/// Subscription is actor-isolated so registration is atomic with respect to
/// event dispatch — a caller can `events()` (or `waitForEvent`) and *then*
/// send the request that triggers the event without racing.
actor DAPClient {
    private let process: Process
    private let stdin: FileHandle
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe

    private var nextSeq = 0
    private var pending: [Int: CheckedContinuation<DAPResponse, Error>] = [:]
    private var subscribers: [UUID: AsyncStream<DAPEvent>.Continuation] = [:]
    private var readBuffer = Data()
    private var closed = false

    // MARK: - Lifecycle

    /// Spawn `lldb-dap` and return a ready DAPClient. Resolves the executable
    /// off the calling task (via `xcrun --find lldb-dap`) before constructing
    /// the actor, so the blocking lookup doesn't park an actor's executor.
    static func spawn(executable: String? = nil) async throws -> DAPClient {
        let path: String
        if let executable {
            path = executable
        } else {
            path = await Self.resolveExecutable()
        }
        return try DAPClient(executablePath: path)
    }

    private init(executablePath: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        let sin = Pipe(), sout = Pipe(), serr = Pipe()
        proc.standardInput = sin
        proc.standardOutput = sout
        proc.standardError = serr

        self.process = proc
        self.stdin = sin.fileHandleForWriting
        self.stdoutPipe = sout
        self.stderrPipe = serr

        do {
            try proc.run()
        } catch {
            throw DAPError.launchFailed("\(error)")
        }

        // Non-blocking read loop. FileHandle invokes the handler on its own
        // internal queue whenever data is available; we forward chunks back
        // into the actor for parsing.
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                Task { await self.handleClose() }
            } else {
                Task { await self.feed(chunk) }
            }
        }
    }

    deinit {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        for (_, cont) in subscribers { cont.finish() }
    }

    func terminate() {
        guard !closed else { return }
        closed = true
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        for (_, cont) in subscribers { cont.finish() }
        subscribers.removeAll()
        for (_, cont) in pending { cont.resume(throwing: DAPError.closed) }
        pending.removeAll()
    }

    // MARK: - Events (fan-out)

    /// Subscribe to all DAP events for this session. Each call returns a fresh
    /// stream; every subscriber sees every event. The stream finishes when the
    /// session closes (lldb-dap exits, EOF on stdout, or `terminate()`).
    ///
    /// Actor-isolated so registration is atomic — issue `events()` (or
    /// `waitForEvent`) *before* the request that triggers the event you want
    /// and you cannot miss it.
    func events() -> AsyncStream<DAPEvent> {
        let id = UUID()
        var captured: AsyncStream<DAPEvent>.Continuation!
        let stream = AsyncStream<DAPEvent>(bufferingPolicy: .unbounded) { captured = $0 }
        captured.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeSubscriber(id: id) }
        }
        subscribers[id] = captured
        return stream
    }

    /// Wait for an event matching `predicate`, with a timeout. Subscription
    /// happens synchronously on the actor before returning — the returned Task
    /// can be safely awaited *after* sending the triggering request.
    func waitForEvent(
        timeout: TimeInterval,
        matching predicate: @escaping @Sendable (DAPEvent) -> Bool
    ) -> Task<DAPEvent, Error> {
        let stream = events()
        return Task {
            try await withThrowingTaskGroup(of: DAPEvent.self) { group in
                group.addTask {
                    for await event in stream where predicate(event) { return event }
                    throw DAPError.closed
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw DAPError.responseError(command: "waitForEvent", message: "timed out after \(timeout)s")
                }
                let event = try await group.next()!
                group.cancelAll()
                return event
            }
        }
    }

    private func removeSubscriber(id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    // MARK: - Requests

    func request(_ command: String) async throws -> DAPResponse {
        try await request(command, arguments: EmptyArgs())
    }

    func request<T: Encodable & Sendable>(
        _ command: String,
        arguments: T
    ) async throws -> DAPResponse {
        guard !closed else { throw DAPError.closed }
        nextSeq += 1
        let seq = nextSeq

        let body = try JSONEncoder().encode(
            DAPRequestEnvelope(seq: seq, command: command, arguments: arguments)
        )
        let header = "Content-Length: \(body.count)\r\n\r\n".data(using: .utf8)!

        return try await withCheckedThrowingContinuation { cont in
            pending[seq] = cont
            do {
                try stdin.write(contentsOf: header)
                try stdin.write(contentsOf: body)
            } catch {
                pending.removeValue(forKey: seq)
                cont.resume(throwing: error)
            }
        }
    }

    // MARK: - Read pipeline

    private func feed(_ chunk: Data) {
        readBuffer.append(chunk)
        while let (messageBytes, consumed) = extractMessage(from: readBuffer) {
            readBuffer.removeFirst(consumed)
            dispatch(messageBytes)
        }
    }

    private func handleClose() {
        guard !closed else { return }
        closed = true
        for (_, cont) in subscribers { cont.finish() }
        subscribers.removeAll()
        for (_, cont) in pending { cont.resume(throwing: DAPError.closed) }
        pending.removeAll()
    }

    private func dispatch(_ messageBytes: Data) {
        let msg: DAPMessage
        do {
            msg = try DAPMessage.parse(messageBytes)
        } catch {
            // Malformed or reverse-request; ignore for M1.
            return
        }
        switch msg {
        case .response(let resp):
            if let cont = pending.removeValue(forKey: resp.requestSeq) {
                if resp.success {
                    cont.resume(returning: resp)
                } else {
                    // Surface the raw body too — lldb-dap often puts the real
                    // error in body.error.format rather than the top-level message.
                    var msgText = resp.message ?? "request failed"
                    if let body = resp.body,
                       let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                       let err = obj["error"] as? [String: Any],
                       let fmt = err["format"] as? String {
                        msgText = fmt
                    }
                    cont.resume(throwing: DAPError.responseError(
                        command: resp.command,
                        message: msgText
                    ))
                }
            }
        case .event(let evt):
            for (_, cont) in subscribers { cont.yield(evt) }
        }
    }

    // MARK: - Framing

    /// Returns `(body, totalBytesConsumed)` when a complete message is present,
    /// or nil if more bytes are needed.
    private func extractMessage(from data: Data) -> (Data, Int)? {
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A])  // \r\n\r\n
        guard let sepRange = data.range(of: separator) else { return nil }
        let headerBytes = data[data.startIndex..<sepRange.lowerBound]
        guard let headerString = String(data: headerBytes, encoding: .utf8) else { return nil }

        var length: Int?
        for line in headerString.split(separator: "\r\n") {
            if line.hasPrefix("Content-Length:") {
                let value = line.dropFirst("Content-Length:".count).trimmingCharacters(in: .whitespaces)
                length = Int(value)
            }
        }
        guard let length else { return nil }

        let bodyStart = sepRange.upperBound
        let bodyEnd = bodyStart + length
        guard data.count >= bodyEnd - data.startIndex else { return nil }
        return (Data(data[bodyStart..<bodyEnd]), bodyEnd - data.startIndex)
    }

    // MARK: - Helpers

    private struct EmptyArgs: Encodable, Sendable {}

    private static func resolveExecutable() async -> String {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            p.arguments = ["--find", "lldb-dap"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            do {
                try p.run()
                p.waitUntilExit()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let path = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty { return path }
            } catch {
                // Fall through to PATH lookup.
            }
            return "lldb-dap"
        }.value
    }
}

// MARK: - Request envelope

/// Single-allocation DAP request envelope. Encodes directly with the typed
/// arguments — no JSONSerialization round-trip.
private struct DAPRequestEnvelope<T: Encodable>: Encodable {
    let seq: Int
    let type = "request"
    let command: String
    let arguments: T
}
