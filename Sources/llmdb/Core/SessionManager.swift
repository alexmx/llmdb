import Foundation

/// Owns the set of live debug sessions. Drives the DAP handshake per session,
/// tracks the most recent stop event, and exposes the high-level verbs.
///
/// Event multiplexing lives in `DAPClient` itself — SessionManager just
/// subscribes to its own listener stream and asks `client.waitForEvent(...)`
/// for the per-call awaits. No subscriber bookkeeping here.
actor SessionManager {
    private var sessions: [String: SessionEntry] = [:]
    /// lldb-dap binary to spawn; nil resolves it via `xcrun`. Tests inject a
    /// stand-in that never answers to exercise the handshake timeout.
    private let dapExecutable: String?

    init(dapExecutable: String? = nil) {
        self.dapExecutable = dapExecutable
    }

    private final class SessionEntry: @unchecked Sendable {
        let id: String
        let client: DAPClient
        var info: Session
        var stoppedThreadId: Int?
        var listener: Task<Void, Never>?
        var breakpoints: [Int: Breakpoint] = [:]
        // Program output captured from DAP `output` events, oldest first.
        // Trimmed from the front once it exceeds `maxOutputChars`.
        var output: [OutputChunk] = []
        var outputChars = 0
        // Exception-breakpoint filters the adapter advertised at initialize,
        // and the subset currently enabled.
        var exceptionFilters: [ExceptionFilter] = []
        var enabledExceptionFilters: [String] = []
        // Reason to report for a SIGSTOP we caused ourselves: "entry"/"attach"
        // for the launch/attach pause, "pause" for interrupt. lldb-dap reports
        // these as "exception", which reads like a crash.
        var expectedStopReason: String?
        // Set once we've tried importing Foundation/UIKit/AppKit for ObjC
        // expressions, so a session pays for the import at most once.
        var triedObjCImports = false

        init(id: String, client: DAPClient, info: Session) {
            self.id = id
            self.client = client
            self.info = info
        }

        /// Append a chunk, dropping the oldest chunks if the buffer grows past
        /// the cap so a chatty long-running target can't exhaust memory.
        func appendOutput(_ chunk: OutputChunk) {
            output.append(chunk)
            outputChars += chunk.text.count
            while outputChars > SessionManager.maxOutputChars, output.count > 1 {
                outputChars -= output.removeFirst().text.count
            }
        }
    }

    /// Default seconds each launch/attach handshake step may take. Generous
    /// because a first attach to a new OS runtime can spend a while loading
    /// symbols; the point is that a wedged lldb-dap can't freeze the target
    /// forever.
    static let defaultHandshakeTimeout: Double = 60

    /// Upper bound on buffered output characters per session (~1 MB).
    static let maxOutputChars = 1_000_000

    /// lldb truncates string summaries at 1024 characters by default, which
    /// cuts off things like `recursiveDescription`. Raise it so `expr` and
    /// `locals` return whole strings.
    static let maxStringSummaryLength = 1_000_000

    /// lldb commands run in every new session before the target is created.
    /// The `?` prefix keeps lldb-dap from echoing them into the target's
    /// captured output (it prints them only if they fail).
    private static let initCommands = [
        "?settings set target.max-string-summary-length \(maxStringSummaryLength)"
    ]

    /// lldb-dap fails `evaluate` with this message when the expression ran but
    /// produced no value (e.g. a call returning `void`).
    private static let noResultMessage = "unknown error"

    // MARK: - Public API

    func list() -> [Session] {
        sessions.values.map(\.info)
    }

    /// Launch a binary under lldb-dap. Stops on entry so subsequent
    /// `break set` calls have a quiescent target. For `.app` bundles, routes
    /// through LaunchServices so the process is registered with WindowServer/
    /// AppKit (required for AX-driven tools to see the app).
    func launch(binary: String, args: [String], timeout: Double? = nil) async throws -> SessionSnapshot {
        if let appURL = AppBundleLauncher.appBundleURL(for: binary) {
            let pid = try await AppBundleLauncher.openApplication(at: appURL, args: args)
            return try await attach(pid: pid, timeout: timeout)
        }
        return try await openSession(target: .launched(binary: binary, args: args), timeout: timeout)
    }

    /// Attach to a running process. lldb-dap pauses the target on attach,
    /// so the returned snapshot is `.stopped`.
    func attach(pid: Int32, timeout: Double? = nil) async throws -> SessionSnapshot {
        try await openSession(target: .attached(pid: pid), timeout: timeout)
    }

    /// Common path for launch/attach: open a DAPClient, run the handshake,
    /// register the session (or roll back on failure). Each handshake step
    /// gets `timeout` seconds (default `defaultHandshakeTimeout`).
    private func openSession(target: Session.Target, timeout: Double?) async throws -> SessionSnapshot {
        let timeout = timeout ?? Self.defaultHandshakeTimeout
        guard timeout > 0 else {
            throw LlmdbError.invalidArgument(name: "timeout", value: "\(timeout)", valid: ["seconds > 0"])
        }
        let id = Self.makeID()
        let client = try await DAPClient.spawn(executable: dapExecutable)
        let entry = SessionEntry(
            id: id,
            client: client,
            info: Session(id: id, target: target, state: .initializing, stopReason: nil)
        )
        sessions[id] = entry
        startListener(entry)

        do {
            try await handshake(entry, target: target, timeout: timeout)
        } catch {
            // Killing lldb-dap releases the target: debugserver detaches an
            // attached process (it resumes) and kills a launched one.
            await client.terminate()
            sessions.removeValue(forKey: id)
            if case DAPError.timedOut = error {
                throw LlmdbError.dapFailure(Self.handshakeTimeoutMessage(target: target, timeout: timeout))
            }
            throw error
        }
        return snapshot(entry)
    }

    private static func handshakeTimeoutMessage(target: Session.Target, timeout: Double) -> String {
        let seconds = timeout.formatted()
        switch target {
        case .launched:
            return "launch timed out after \(seconds)s waiting for lldb-dap; the launched process was terminated. Retry, or pass a longer timeout."
        case .attached, .simulator:
            return "attach timed out after \(seconds)s waiting for lldb-dap; the target was detached and left running. A first attach to a new OS runtime can be slow while lldb loads symbols — retry, or pass a longer timeout."
        }
    }

    func setBreakpoint(
        sessionId: String?,
        file: String,
        line: Int,
        condition: String? = nil,
        hitCondition: String? = nil
    ) async throws -> (SessionSnapshot, Breakpoint) {
        let entry = try resolve(sessionId)
        let resp = try await entry.client.request(
            "setBreakpoints",
            arguments: SetBreakpointsArgs(
                source: .init(path: file),
                breakpoints: [.init(line: line, condition: condition, hitCondition: hitCondition)]
            )
        )
        let body = try resp.decodeBody(SetBreakpointsBody.self)
        guard let bp = body.breakpoints.first else {
            throw LlmdbError.dapFailure("setBreakpoints returned no breakpoint")
        }
        // Stock message for unverified BPs so callers don't panic at `verified: false`.
        let message: String? = if let bpMessage = bp.message {
            bpMessage
        } else if bp.verified {
            nil
        } else {
            Self.unverifiedBreakpointMessage
        }
        // lldb-dap doesn't echo condition/hitCondition, so carry the request
        // values through onto the tracked model.
        let model = Breakpoint(
            id: bp.id ?? 0,
            verified: bp.verified,
            line: bp.line,
            source: bp.source?.path ?? file,
            message: message,
            condition: condition,
            hitCondition: hitCondition
        )
        if let bid = bp.id {
            entry.breakpoints[bid] = model
        }
        return (snapshot(entry), model)
    }

    /// Enable the given exception-breakpoint filters (e.g. `swift_throw`),
    /// replacing any previously set. An empty list clears them. Returns the
    /// filters the adapter advertises plus the ids now active. Unknown ids are
    /// rejected against the advertised set.
    func setExceptionBreakpoints(
        sessionId: String?,
        filters: [String]
    ) async throws -> (available: [ExceptionFilter], enabled: [String]) {
        let entry = try resolve(sessionId)
        let known = Set(entry.exceptionFilters.map(\.id))
        if let unknown = filters.first(where: { !known.contains($0) }) {
            throw LlmdbError.invalidArgument(
                name: "filter",
                value: unknown,
                valid: entry.exceptionFilters.map(\.id)
            )
        }
        _ = try await entry.client.request(
            "setExceptionBreakpoints",
            arguments: SetExceptionBreakpointsArgs(filters: filters)
        )
        entry.enabledExceptionFilters = filters
        return (entry.exceptionFilters, filters)
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
        let waiter = await entry.client.waitForEvent(timeout: timeout ?? 60, matching: Self.isStopOrExit)
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
        // Only our own `pause` produces a SIGSTOP worth relabeling; any other
        // command's stop is reported as lldb-dap describes it.
        entry.expectedStopReason = command == "pause" ? "pause" : nil

        if wait == 0 {
            _ = try await entry.client.request(command, arguments: ThreadIdArgs(threadId: threadId))
            // Optimistic — listener overwrites when the real continued/stopped event lands.
            entry.info.state = .running
            entry.info.stopReason = nil
            return snapshot(entry)
        }

        // Subscribe BEFORE sending so we don't miss the stop.
        let waiter = await entry.client.waitForEvent(timeout: wait, matching: Self.isStopOrExit)
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
        do {
            return try await evaluate(entry, expression: expression, frameId: frame.id)
        } catch DAPError.responseError(let command, let message)
            where !entry.triedObjCImports && Self.isClangCompileError(message) {
            // In a frame without debug info (e.g. right after attach) lldb
            // compiles as Objective-C++ with no framework declarations, so
            // ObjC calls fail until Foundation/UIKit are imported. Import them
            // once and retry — safe, since a compile error means nothing ran.
            entry.triedObjCImports = true
            guard await importObjCModules(entry, frameId: frame.id) else {
                throw DAPError.responseError(command: command, message: message)
            }
            return try await evaluate(entry, expression: expression, frameId: frame.id)
        }
    }

    /// Single `evaluate` round-trip, with void results reported as success.
    private func evaluate(
        _ entry: SessionEntry,
        expression: String,
        frameId: Int
    ) async throws -> (value: String, type: String?, variablesReference: Int) {
        // context="watch" returns just the value (e.g. "20") instead of the
        // REPL's verbose "(Int) $R0 = 20" form. Closer to what locals returns.
        let resp: DAPResponse
        do {
            resp = try await entry.client.request(
                "evaluate",
                arguments: EvaluateArgs(expression: expression, frameId: frameId, context: "watch")
            )
        } catch DAPError.responseError(_, let message) where message == Self.noResultMessage {
            // The expression ran; it just has no value (void call). Report
            // success — retrying would repeat its side effects.
            return ("", "void", 0)
        }
        let body = try resp.decodeBody(EvaluateBody.self)
        return (body.result, body.type, body.variablesReference)
    }

    /// Import Foundation, plus UIKit or AppKit when the target has loaded it,
    /// into the session's expression context. Imports persist for later
    /// expressions. Returns false if even Foundation couldn't be imported.
    private func importObjCModules(_ entry: SessionEntry, frameId: Int) async -> Bool {
        guard await (try? evaluate(entry, expression: "@import Foundation", frameId: frameId)) != nil else {
            return false
        }
        for (uiClass, module) in [("UIApplication", "UIKit"), ("NSApplication", "AppKit")] {
            let loaded = try? await evaluate(
                entry,
                expression: "(int)(NSClassFromString(@\"\(uiClass)\") != nil)",
                frameId: frameId
            )
            if loaded?.value == "1" {
                _ = try? await evaluate(entry, expression: "@import \(module)", frameId: frameId)
                break
            }
        }
        return true
    }

    /// True for a clang (C/ObjC) compile error. Swift errors cite `<EXPR>`
    /// instead, and runtime failures ("Execution was interrupted") cite
    /// neither — those must never be retried.
    private static func isClangCompileError(_ message: String) -> Bool {
        message.contains("<user expression")
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
        let surviving = entry.breakpoints.values
            .filter { $0.source == source && $0.id != id }
        let survivors = surviving.compactMap { bp in
            bp.line.map { BPLine(line: $0, condition: bp.condition, hitCondition: bp.hitCondition) }
        }
        // Keyed by line so we can re-attach condition/hitCondition (which
        // lldb-dap doesn't echo) after the rebuild hands back fresh ids.
        let conditionsByLine = Dictionary(
            surviving.compactMap { bp in bp.line.map { ($0, bp) } },
            uniquingKeysWith: { first, _ in first }
        )

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
            let prior = bp.line.flatMap { conditionsByLine[$0] }
            entry.breakpoints[bid] = Breakpoint(
                id: bid,
                verified: bp.verified,
                line: bp.line,
                source: bp.source?.path ?? source,
                message: bp.message,
                condition: prior?.condition,
                hitCondition: prior?.hitCondition
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
        guard let ref = try await localsScopeRef(entry, threadId: threadId, frameIndex: frameIndex) else {
            return []
        }
        let varsResp = try await entry.client.request(
            "variables",
            arguments: VariablesArgs(variablesReference: ref)
        )
        return try varsResp.decodeBody(VariablesBody.self).variables.map {
            Local(name: $0.name, type: $0.type, value: $0.value, variablesReference: $0.variablesReference)
        }
    }

    /// The variable scopes for a frame (Locals, Globals, Registers, …), each
    /// with a `variablesReference` that `expand` can read. Lets callers reach
    /// globals/statics and registers, which `locals` (Locals-only) skips.
    func scopes(
        sessionId: String?,
        threadId: Int? = nil,
        frameIndex: Int = 0
    ) async throws -> [Scope] {
        let entry = try resolve(sessionId)
        return try await fetchScopes(entry, threadId: threadId, frameIndex: frameIndex).map {
            Scope(name: $0.name, variablesReference: $0.variablesReference, expensive: $0.expensive ?? false)
        }
    }

    /// Resolve the `Locals` scope's variablesReference for a frame, or nil if
    /// the frame has no such scope. Used by `locals` and `setVariable`.
    private func localsScopeRef(
        _ entry: SessionEntry,
        threadId: Int?,
        frameIndex: Int
    ) async throws -> Int? {
        let scopes = try await fetchScopes(entry, threadId: threadId, frameIndex: frameIndex)
        return scopes.first { $0.name == "Locals" }?.variablesReference
    }

    /// Fetch the raw DAP scopes for a frame, validating the thread/frame.
    private func fetchScopes(
        _ entry: SessionEntry,
        threadId: Int?,
        frameIndex: Int
    ) async throws -> [DAPScope] {
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
        return try scopesResp.decodeBody(ScopesBody.self).scopes
    }

    /// Assign a new value to a variable during a stop, then return its updated
    /// state. `target` is any assignable expression in the target's language —
    /// a local name, `self.count`, `arr[0]`, etc. Implemented via expression
    /// assignment because lldb-dap's `setVariable` request is unreliable for
    /// Swift (it rejects valid values as "Invalid encoding").
    func setVariable(
        sessionId: String?,
        target: String,
        value: String,
        frameIndex: Int = 0
    ) async throws -> Local {
        // Perform the assignment; lldb evaluates it for its side effect and
        // returns "()", which we discard.
        _ = try await evaluate(
            sessionId: sessionId,
            expression: "\(target) = \(value)",
            frameIndex: frameIndex
        )
        // Read the result back so the caller sees the resulting value and type.
        let updated = try await evaluate(sessionId: sessionId, expression: target, frameIndex: frameIndex)
        return Local(
            name: target,
            type: updated.type,
            value: updated.value,
            variablesReference: updated.variablesReference
        )
    }

    /// Expand a structured value into its children. `variablesReference` comes
    /// from a non-zero `variablesReference` on a `locals` (or prior `expand`)
    /// entry; a value of 0 means the entry is a leaf with nothing to expand.
    func expand(sessionId: String?, variablesReference: Int) async throws -> [Local] {
        guard variablesReference > 0 else {
            throw LlmdbError.invalidArgument(
                name: "variablesReference",
                value: "\(variablesReference)",
                valid: ["a non-zero reference from a locals/expand entry"]
            )
        }
        let entry = try resolve(sessionId)
        let resp = try await entry.client.request(
            "variables",
            arguments: VariablesArgs(variablesReference: variablesReference)
        )
        return try resp.decodeBody(VariablesBody.self).variables.map {
            Local(name: $0.name, type: $0.type, value: $0.value, variablesReference: $0.variablesReference)
        }
    }

    /// Buffered program output (stdout/stderr/console) captured so far, oldest
    /// first. Pass `clear: true` to drain the buffer so the next call returns
    /// only output produced after this one.
    func output(sessionId: String?, clear: Bool = false) throws -> [OutputChunk] {
        let entry = try resolve(sessionId)
        let chunks = entry.output
        if clear {
            entry.output.removeAll()
            entry.outputChars = 0
        }
        return chunks
    }

    /// End a session. `mode` nil → terminate launched targets, detach from
    /// attached ones (the target keeps running). Returns what happened:
    /// "terminated", "detached", or "exited" if the target had already ended.
    @discardableResult
    func stop(sessionId: String?, mode: StopMode? = nil) async throws -> String {
        let entry = try resolve(sessionId)
        sessions.removeValue(forKey: entry.id)
        entry.listener?.cancel()

        let action: String
        if entry.info.state == .terminated {
            action = "exited"
        } else {
            let mode = mode ?? Self.defaultStopMode(for: entry.info.target)
            // Best effort: if lldb-dap is wedged, terminating it below still
            // ends the session (and detaches/kills the target as a side effect).
            _ = try? await entry.client.request(
                "disconnect",
                arguments: DisconnectArgs(terminateDebuggee: mode == .terminate),
                timeout: 5
            )
            action = mode.action
        }
        await entry.client.terminate()
        return action
    }

    private static func defaultStopMode(for target: Session.Target) -> StopMode {
        switch target {
        case .launched: .terminate
        case .attached, .simulator: .detach
        }
    }

    // MARK: - Internals

    private func resolve(_ sessionId: String?) throws -> SessionEntry {
        if let sessionId {
            guard let entry = sessions[sessionId] else { throw LlmdbError.sessionNotFound(sessionId) }
            return entry
        }
        if sessions.count == 1, let only = sessions.values.first {
            return only
        }
        if sessions.isEmpty {
            throw LlmdbError.sessionNotFound("(none active)")
        }
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

    private func handshake(_ entry: SessionEntry, target: Session.Target, timeout: Double) async throws {
        // Subscribe to `initialized` BEFORE sending the initialize request.
        // lldb-dap can emit it right after the initialize response, before
        // launch/attach is sent — subscribing later races and loses.
        let initWaiter = await entry.client.waitForEvent(timeout: timeout) { $0.event == "initialized" }

        let initResp = try await entry.client.request(
            "initialize",
            arguments: InitializeArgs(
                clientID: "llmdb",
                clientName: "llmdb",
                adapterID: "lldb-dap",
                linesStartAt1: true,
                columnsStartAt1: true,
                pathFormat: "path",
                supportsRunInTerminalRequest: false
            ),
            timeout: timeout
        )
        // Remember the adapter's exception-breakpoint filters so `break
        // exception` can validate ids and report what's available.
        if let body = try? initResp.decodeBody(InitializeResponseBody.self) {
            entry.exceptionFilters = (body.exceptionBreakpointFilters ?? []).map {
                ExceptionFilter(id: $0.filter, label: $0.label, isDefault: $0.default ?? false)
            }
        }

        switch target {
        case .launched(let binary, let args):
            entry.expectedStopReason = "entry"
            _ = try await entry.client.request(
                "launch",
                arguments: LaunchArgs(
                    program: binary,
                    args: args,
                    stopOnEntry: true,
                    initCommands: Self.initCommands
                ),
                timeout: timeout
            )
        case .attached(let pid):
            entry.expectedStopReason = "attach"
            _ = try await entry.client.request(
                "attach",
                arguments: AttachArgs(pid: Int(pid), stopOnEntry: true, initCommands: Self.initCommands),
                timeout: timeout
            )
        case .simulator:
            throw LlmdbError.notImplemented("simulator attach")
        }

        _ = try await initWaiter.value

        // After `initialized`, send configurationDone; the stopOnEntry stop
        // arrives shortly after.
        let stopWaiter = await entry.client.waitForEvent(timeout: timeout, matching: Self.isStopOrExit)
        _ = try await entry.client.request("configurationDone", timeout: timeout)
        // Apply the stop here rather than relying on the listener, which may
        // not have processed it yet when we return the snapshot.
        let stop = try await stopWaiter.value
        await handleEvent(stop, entryID: entry.id)
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
                var reason = body.reason
                if let expected = entry.expectedStopReason, Self.isRequestedPause(body) {
                    reason = expected
                }
                entry.info.state = .stopped
                entry.info.stopReason = StopReason(
                    reason: reason,
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
        case "output":
            // Buffer the target's stdout/stderr/console output. Skip telemetry,
            // which carries structured analytics rather than display text.
            if let body = try? event.decodeBody(OutputEventBody.self) {
                let category = body.category ?? "console"
                if category != "telemetry" {
                    entry.appendOutput(OutputChunk(category: category, text: body.output))
                }
            }
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
                    message: body.breakpoint.message ?? existing?.message,
                    condition: existing?.condition,
                    hitCondition: existing?.hitCondition
                )
            }
        default:
            break
        }
    }

    private func markTerminated(entryID: String) {
        sessions[entryID]?.info.state = .terminated
    }

    /// True for the DAP events that mean a session has left `.running`:
    /// it either stopped at a breakpoint/step or the target ended.
    private static let isStopOrExit: @Sendable (DAPEvent) -> Bool = {
        $0.event == "stopped" || $0.event == "terminated" || $0.event == "exited"
    }

    /// A stop lldb-dap may report for a pause we requested: SIGSTOP (as
    /// "exception"), or a plain "entry"/"pause" on some targets.
    private static func isRequestedPause(_ body: StoppedEventBody) -> Bool {
        ["entry", "pause"].contains(body.reason) || body.description?.contains("SIGSTOP") == true
    }

    private static let unverifiedBreakpointMessage =
        "verification deferred until module loads — common for breakpoints set before launch or in lazily-loaded modules"

    private static func makeID() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }
}
