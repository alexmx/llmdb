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
    /// lldb-dap's stdout, chunk by chunk, in arrival order. Finished on EOF
    /// or `terminate()`.
    private let stdoutChunks: AsyncStream<Data>.Continuation

    private var nextSeq = 0
    private var pending: [Int: CheckedContinuation<DAPResponse, Error>] = [:]
    private var subscribers: [UUID: AsyncStream<DAPEvent>.Continuation] = [:]
    private var readBuffer = Data()
    private var closed = false

    // MARK: - Lifecycle

    /// Spawn `lldb-dap` and return a ready DAPClient. Without an explicit
    /// executable, uses the one `xcrun` finds, else `lldb-dap` from PATH.
    static func spawn(executable: String? = nil) async throws -> DAPClient {
        let path = if let executable {
            executable
        } else {
            await findLldbDap() ?? "lldb-dap"
        }
        return try DAPClient(executablePath: path)
    }

    /// The active toolchain's `lldb-dap` per `xcrun --find`, or nil if it
    /// can't be found.
    static func findLldbDap() async -> String? {
        guard let result = try? await ProcessRunner.run("/usr/bin/xcrun", ["--find", "lldb-dap"]),
              result.status.isSuccess
        else {
            return nil
        }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
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
        let (chunks, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        self.stdoutChunks = continuation

        do {
            try proc.run()
        } catch {
            throw DAPError.launchFailed("\(error)")
        }

        // FileHandle calls the handler serially on its own queue; it only
        // enqueues. A single task drains the stream so chunks are parsed in
        // order and close always comes after the last one — a Task per chunk
        // would let the actor run them in any order.
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(chunk)
            }
        }
        Task { [weak self] in
            for await chunk in chunks {
                await self?.feed(chunk)
            }
            await self?.handleClose()
        }
    }

    deinit {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stdoutChunks.finish()
        if process.isRunning {
            process.terminate()
        }
        for (_, cont) in subscribers {
            cont.finish()
        }
    }

    func terminate() {
        guard !closed else { return }
        closed = true
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stdoutChunks.finish()
        if process.isRunning {
            process.terminate()
        }
        finishSubscribersAndPending()
    }

    /// Finish every event stream and fail every in-flight request. Idempotent
    /// via the `closed` guard in callers.
    private func finishSubscribersAndPending() {
        for cont in subscribers.values {
            cont.finish()
        }
        subscribers.removeAll()
        for cont in pending.values {
            cont.resume(throwing: DAPError.closed)
        }
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
        let (stream, continuation) = AsyncStream<DAPEvent>.makeStream(bufferingPolicy: .unbounded)
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeSubscriber(id: id) }
        }
        subscribers[id] = continuation
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
                    for await event in stream where predicate(event) {
                        return event
                    }
                    throw DAPError.closed
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw DAPError.timedOut(command: "waitForEvent", seconds: timeout)
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

    func request(_ command: String, timeout: Double? = nil) async throws -> DAPResponse {
        try await request(command, arguments: EmptyArgs(), timeout: timeout)
    }

    /// Send a request and await its response. With `timeout` (seconds), the
    /// call fails if lldb-dap hasn't answered in time instead of hanging.
    func request(
        _ command: String,
        arguments: some Encodable & Sendable,
        timeout: Double? = nil
    ) async throws -> DAPResponse {
        guard !closed else { throw DAPError.closed }
        nextSeq += 1
        let seq = nextSeq
        // Cancelled as soon as this call returns, so a timer doesn't outlive
        // the response it guards.
        let timer = timeout.map { seconds in
            Task { [weak self] in
                guard await (try? Task.sleep(for: .seconds(seconds))) != nil else { return }
                await self?.expire(seq: seq, command: command, after: seconds)
            }
        }
        defer { timer?.cancel() }

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

    /// Fail a still-pending request whose timeout elapsed. No-op if the
    /// response already arrived.
    private func expire(seq: Int, command: String, after timeout: Double) {
        pending.removeValue(forKey: seq)?.resume(throwing: DAPError.timedOut(command: command, seconds: timeout))
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
        finishSubscribersAndPending()
    }

    private func dispatch(_ messageBytes: Data) {
        let msg: DAPMessage
        do {
            msg = try DAPMessage.parse(messageBytes)
        } catch {
            // Malformed or reverse-request; ignore.
            return
        }
        switch msg {
        case .response(let resp):
            if let cont = pending.removeValue(forKey: resp.requestSeq) {
                if resp.success {
                    cont.resume(returning: resp)
                } else {
                    // lldb-dap often puts the real error in body.error.format
                    // rather than the top-level message.
                    let detail = try? resp.decodeBody(ErrorResponseBody.self).error?.format
                    cont.resume(throwing: DAPError.responseError(
                        command: resp.command,
                        message: detail ?? resp.message ?? "request failed"
                    ))
                }
            }
        case .event(let evt):
            for (_, cont) in subscribers {
                cont.yield(evt)
            }
        }
    }

    // MARK: - Framing

    /// Returns `(body, totalBytesConsumed)` when a complete message is present,
    /// or nil if more bytes are needed.
    private func extractMessage(from data: Data) -> (Data, Int)? {
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
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

    private struct EmptyArgs: Encodable {}

    /// A failed response's body: `{ "error": { "format": "…" } }`.
    private struct ErrorResponseBody: Decodable {
        struct Message: Decodable {
            let format: String
        }

        let error: Message?
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
