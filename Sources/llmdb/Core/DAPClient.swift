import Foundation

/// Speaks Debug Adapter Protocol to a child `lldb-dap` process.
///
/// Spawns lldb-dap, frames Content-Length-prefixed JSON over its stdio,
/// correlates request → response by `seq` via continuations, surfaces
/// events on a nonisolated `AsyncStream<DAPEvent>`.
///
/// One DAPClient = one lldb-dap process = one debug session.
actor DAPClient {
    private let process: Process
    private let stdin: FileHandle
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe

    private var nextSeq = 0
    private var pending: [Int: CheckedContinuation<DAPResponse, Error>] = [:]
    private var readBuffer = Data()
    private var closed = false

    nonisolated let events: AsyncStream<DAPEvent>
    private let eventContinuation: AsyncStream<DAPEvent>.Continuation

    // MARK: - Lifecycle

    init(executable: String? = nil) throws {
        let path = executable ?? Self.resolveExecutable()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        let sin = Pipe(), sout = Pipe(), serr = Pipe()
        proc.standardInput = sin
        proc.standardOutput = sout
        proc.standardError = serr

        self.process = proc
        self.stdin = sin.fileHandleForWriting
        self.stdoutPipe = sout
        self.stderrPipe = serr

        var captured: AsyncStream<DAPEvent>.Continuation!
        let stream = AsyncStream<DAPEvent> { captured = $0 }
        self.events = stream
        self.eventContinuation = captured

        do {
            try proc.run()
        } catch {
            throw DAPError.launchFailed("\(error)")
        }

        // Non-blocking read loop. FileHandle invokes the handler on its own
        // internal queue whenever data is available; we forward chunks back
        // into the actor for parsing.
        let writer = stdoutPipe.fileHandleForReading
        writer.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                // EOF — child exited or closed stdout.
                handle.readabilityHandler = nil
                Task { await self.handleClose() }
            } else {
                Task { await self.feed(chunk) }
            }
        }
    }

    deinit {
        // We can't await an actor method from deinit; do the synchronous parts.
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
        eventContinuation.finish()
    }

    func terminate() {
        guard !closed else { return }
        closed = true
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
        eventContinuation.finish()
        for (_, cont) in pending {
            cont.resume(throwing: DAPError.closed)
        }
        pending.removeAll()
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

        // Build the request envelope. We encode arguments to JSON then merge it
        // into the envelope dict so we don't need a generic envelope type.
        let argsData = try JSONEncoder().encode(arguments)
        let argsObj = try JSONSerialization.jsonObject(with: argsData)
        let envelope: [String: Any] = [
            "seq": seq,
            "type": "request",
            "command": command,
            "arguments": argsObj
        ]
        let body = try JSONSerialization.data(withJSONObject: envelope)
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
        eventContinuation.finish()
        for (_, cont) in pending {
            cont.resume(throwing: DAPError.closed)
        }
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
                    cont.resume(throwing: DAPError.responseError(
                        command: resp.command,
                        message: resp.message ?? "request failed"
                    ))
                }
            }
        case .event(let evt):
            eventContinuation.yield(evt)
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
                let value = line.dropFirst("Content-Length:".count)
                    .trimmingCharacters(in: .whitespaces)
                length = Int(value)
            }
        }
        guard let length else { return nil }

        let bodyStart = sepRange.upperBound
        let bodyEnd = bodyStart + length
        guard data.count >= bodyEnd - data.startIndex else { return nil }
        let body = Data(data[bodyStart..<bodyEnd])
        return (body, bodyEnd - data.startIndex)
    }

    // MARK: - Helpers

    private struct EmptyArgs: Encodable, Sendable {}

    private nonisolated static func resolveExecutable() -> String {
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
    }
}
