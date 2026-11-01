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

    private final class SessionEntry {
        let id: String
        let client: DAPClient
        var info: Session
        var stoppedThreadId: Int?
        var listener: Task<Void, Never>?
        var breakpoints: [Int: TrackedBreakpoint] = [:]
        // Program output captured from DAP `output` events, oldest first.
        // Trimmed from the front once it exceeds `maxOutputChars`.
        var output: [OutputChunk] = []
        var outputChars = 0
        // Exception-breakpoint filters the adapter advertised at initialize,
        // and the subset currently enabled.
        var exceptionFilters: [ExceptionFilter] = []
        var enabledExceptionFilters: [String] = []
        // The pause we just requested, if any — reported as its reason instead
        // of lldb-dap's "exception", which reads like a crash.
        var expectedStopReason: OwnPause?
        // Set once we've tried importing Foundation/UIKit/AppKit for ObjC
        // expressions, so a session pays for the import at most once.
        var triedObjCImports = false
        // Only the listener writes `info.state` from events, bumping this each
        // time. A verb notes it before sending, then waits for the listener
        // to record a stop newer than that — so it can't miss or race one.
        var stateVersion = 0
        var stopWaiters: [UUID: StopWaiter] = [:]

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

    /// A breakpoint as requested (file and line exactly as sent) plus what
    /// lldb-dap reported for it. The requested values are what gets resent:
    /// lldb-dap groups breakpoints by the path in the request, and may move
    /// the line or omit it while unverified.
    private struct TrackedBreakpoint {
        let file: String
        let line: Int
        var breakpoint: Breakpoint

        var request: BPLine {
            BPLine(line: line, condition: breakpoint.condition, hitCondition: breakpoint.hitCondition)
        }
    }

    /// A verb waiting for the listener to record a stop or exit newer than
    /// `after` (a `stateVersion`).
    private struct StopWaiter {
        let after: Int
        let continuation: CheckedContinuation<Void, Error>
    }

    /// A SIGSTOP we caused ourselves; the raw value is the stop reason we
    /// report for it.
    private enum OwnPause: String {
        /// The launch pause (stopOnEntry).
        case entry
        /// The pause on attach.
        case attach
        /// `interrupt`.
        case pause
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
        case .attached:
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
        // Keep the file's other breakpoints; one already on this line is
        // replaced (so its condition updates) rather than duplicated.
        var lines = trackedBreakpoints(entry, in: file).filter { $0.line != line }.map(\.request)
        lines.append(BPLine(line: line, condition: condition, hitCondition: hitCondition))
        let synced = try await syncBreakpoints(entry, file: file, lines: lines)
        guard let breakpoint = synced.last else {
            throw LlmdbError.dapFailure("setBreakpoints returned no breakpoint")
        }
        return (snapshot(entry), breakpoint)
    }

    /// The breakpoints tracked for `file` (as requested), oldest first.
    private func trackedBreakpoints(_ entry: SessionEntry, in file: String) -> [TrackedBreakpoint] {
        entry.breakpoints.values.filter { $0.file == file }.sorted { $0.breakpoint.id < $1.breakpoint.id }
    }

    /// Make `lines` the complete set of breakpoints in `file`. DAP's
    /// `setBreakpoints` replaces every breakpoint in a file, so sending only
    /// a new line would silently delete the others. Rebuilds the file's
    /// tracking from the reply and returns its breakpoints in request order.
    private func syncBreakpoints(
        _ entry: SessionEntry,
        file: String,
        lines: [BPLine]
    ) async throws -> [Breakpoint] {
        let resp = try await entry.client.request(
            "setBreakpoints",
            arguments: SetBreakpointsArgs(source: .init(path: file), breakpoints: lines)
        )
        let reported = try resp.decodeBody(SetBreakpointsBody.self).breakpoints
        for tracked in trackedBreakpoints(entry, in: file) {
            entry.breakpoints.removeValue(forKey: tracked.breakpoint.id)
        }
        // The reply lists breakpoints in request order. lldb-dap doesn't echo
        // condition/hitCondition, so they come from the request.
        return zip(lines, reported).map { requested, info in
            let breakpoint = Breakpoint(
                id: info.id ?? 0,
                verified: info.verified,
                line: info.line,
                source: info.source?.path ?? file,
                // Stock message so callers don't panic at `verified: false`.
                message: info.message ?? (info.verified ? nil : Self.unverifiedBreakpointMessage),
                condition: requested.condition,
                hitCondition: requested.hitCondition
            )
            if let id = info.id {
                entry.breakpoints[id] = TrackedBreakpoint(file: file, line: requested.line, breakpoint: breakpoint)
            }
            return breakpoint
        }
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
        try await runUntilStop(sessionId: sessionId, command: "continue", relabelingPauseAs: nil, wait: wait ?? 60)
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
        try await runUntilStop(sessionId: sessionId, command: "pause", relabelingPauseAs: .pause, wait: wait ?? 10)
    }

    /// Step one source line. `granularity` picks the DAP command:
    /// `.over` → next, `.in` → stepIn, `.out` → stepOut.
    func step(
        sessionId: String?,
        granularity: StepGranularity,
        wait: Double? = nil
    ) async throws -> SessionSnapshot {
        try await runUntilStop(
            sessionId: sessionId,
            command: granularity.dapCommand,
            relabelingPauseAs: nil,
            wait: wait ?? 30
        )
    }

    /// Block until the session leaves `.running` (i.e., stops or terminates).
    /// Returns immediately if already stopped/terminated.
    func wait(sessionId: String?, timeout: Double? = nil) async throws -> SessionSnapshot {
        let entry = try resolve(sessionId)
        if entry.info.state != .running {
            return snapshot(entry)
        }
        try await awaitStop(entry, after: entry.stateVersion, timeout: timeout ?? 60)
        return snapshot(entry)
    }

    /// `wait == 0` → fire-and-forget; otherwise block up to `wait` seconds.
    /// `relabelingPauseAs` is set only when `command` itself causes a SIGSTOP;
    /// any other command's stop is reported as lldb-dap describes it.
    private func runUntilStop(
        sessionId: String?,
        command: String,
        relabelingPauseAs ownPause: OwnPause?,
        wait: Double
    ) async throws -> SessionSnapshot {
        let entry = try resolve(sessionId)
        let threadId = entry.stoppedThreadId ?? 1
        entry.expectedStopReason = ownPause
        let version = entry.stateVersion
        _ = try await entry.client.request(command, arguments: ThreadIdArgs(threadId: threadId))

        if wait == 0 {
            // Optimistic, unless the listener has already recorded what
            // happened; it overwrites this when the continued/stopped lands.
            if entry.stateVersion == version {
                entry.info.state = .running
                entry.info.stopReason = nil
            }
            return snapshot(entry)
        }
        try await awaitStop(entry, after: version, timeout: wait)
        return snapshot(entry)
    }

    /// Return once the listener has recorded a stop or exit newer than
    /// `version`. The check and the registration happen with no suspension
    /// in between, so a stop recorded meanwhile can't be missed.
    private func awaitStop(_ entry: SessionEntry, after version: Int, timeout: Double) async throws {
        if entry.stateVersion > version, entry.info.state != .running {
            return
        }
        let entryID = entry.id, waiterID = UUID()
        let timer = Task { [weak self] in
            guard await (try? Task.sleep(for: .seconds(timeout))) != nil else { return }
            await self?.expireStopWaiter(entryID: entryID, waiterID: waiterID, timeout: timeout)
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            entry.stopWaiters[waiterID] = StopWaiter(after: version, continuation: continuation)
        }
    }

    private func expireStopWaiter(entryID: String, waiterID: UUID, timeout: Double) {
        sessions[entryID]?.stopWaiters.removeValue(forKey: waiterID)?.continuation
            .resume(throwing: DAPError.timedOut(command: "waitForEvent", seconds: timeout))
    }

    /// Call after the listener changes `info.state`: bumps the version and,
    /// if the session has left `.running`, resumes the verbs waiting for it.
    private func recordStateChange(_ entry: SessionEntry) {
        entry.stateVersion += 1
        guard entry.info.state != .running else { return }
        for (id, waiter) in entry.stopWaiters where waiter.after < entry.stateVersion {
            entry.stopWaiters.removeValue(forKey: id)
            waiter.continuation.resume()
        }
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
        let frame = try await frame(entry, threadId: nil, index: frameIndex)
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
        return entry.breakpoints.values.map(\.breakpoint).sorted { $0.id < $1.id }
    }

    /// Delete a breakpoint by id. DAP has no per-id delete, so the file's
    /// remaining breakpoints are resent without it.
    func deleteBreakpoint(sessionId: String?, id: Int) async throws -> [Breakpoint] {
        let entry = try resolve(sessionId)
        guard let doomed = entry.breakpoints[id] else {
            throw LlmdbError.invalidArgument(
                name: "id",
                value: "\(id)",
                valid: entry.breakpoints.keys.sorted().map { String($0) }
            )
        }
        let remaining = trackedBreakpoints(entry, in: doomed.file).filter { $0.breakpoint.id != id }
        _ = try await syncBreakpoints(entry, file: doomed.file, lines: remaining.map(\.request))
        return entry.breakpoints.values.map(\.breakpoint).sorted { $0.id < $1.id }
    }

    func backtrace(
        sessionId: String?,
        threadId: Int? = nil,
        depth: Int? = nil
    ) async throws -> [Frame] {
        let entry = try resolve(sessionId)
        let tid = try stoppedThread(entry, threadId)
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
        let scopes = try await fetchScopes(entry, threadId: threadId, frameIndex: frameIndex)
        guard let ref = scopes.first(where: { $0.name == "Locals" })?.variablesReference else {
            return []
        }
        let varsResp = try await entry.client.request(
            "variables",
            arguments: VariablesArgs(variablesReference: ref)
        )
        return try varsResp.decodeBody(VariablesBody.self).variables.map(Local.init)
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

    /// Fetch the raw DAP scopes for a frame.
    private func fetchScopes(
        _ entry: SessionEntry,
        threadId: Int?,
        frameIndex: Int
    ) async throws -> [DAPScope] {
        let frame = try await frame(entry, threadId: threadId, index: frameIndex)
        let scopesResp = try await entry.client.request("scopes", arguments: ScopesArgs(frameId: frame.id))
        return try scopesResp.decodeBody(ScopesBody.self).scopes
    }

    /// `threadId`, else the thread of the most recent stop. Requires the
    /// session to be stopped: `stoppedThreadId` outlives the stop (continue
    /// reuses it), so it alone doesn't say the target is paused.
    private func stoppedThread(_ entry: SessionEntry, _ threadId: Int?) throws -> Int {
        guard entry.info.state == .stopped else {
            throw LlmdbError.notStopped(entry.info.state)
        }
        guard let tid = threadId ?? entry.stoppedThreadId else {
            throw LlmdbError.dapFailure("no stopped thread; is the session running?")
        }
        return tid
    }

    /// The frame at `index` on a stopped thread — fetched alone, not the full
    /// stack. Rejects an index outside the stack.
    private func frame(_ entry: SessionEntry, threadId: Int?, index: Int) async throws -> DAPFrame {
        let tid = try stoppedThread(entry, threadId)
        guard index >= 0 else {
            throw LlmdbError.invalidArgument(name: "frame", value: "\(index)", valid: ["0+"])
        }
        let frames = try await fetchFrames(entry, threadId: tid, startFrame: index, levels: 1)
        guard let frame = frames.first else {
            throw LlmdbError.invalidArgument(name: "frame", value: "\(index)", valid: ["0..<stack depth"])
        }
        return frame
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
        return try resp.decodeBody(VariablesBody.self).variables.map(Local.init)
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
    /// attached ones (the target keeps running). Returns what happened.
    @discardableResult
    func stop(sessionId: String?, mode: StopMode? = nil) async throws -> StopAction {
        let entry = try resolve(sessionId)
        sessions.removeValue(forKey: entry.id)
        entry.listener?.cancel()
        // The listener is gone, so nothing will resume these.
        for waiter in entry.stopWaiters.values {
            waiter.continuation.resume(throwing: DAPError.closed)
        }
        entry.stopWaiters.removeAll()

        let action: StopAction
        if entry.info.state == .terminated {
            action = .exited
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
        case .attached: .detach
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
            stopReason: entry.info.stopReason
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
        let version = entry.stateVersion
        // Subscribe to `initialized` before sending `initialize`: lldb-dap can
        // emit it right after the initialize response, before launch/attach
        // is sent.
        let initialized = await entry.client.waitForEvent(timeout: timeout) { $0.event == "initialized" }
        do {
            try await sendInitializeAndTarget(entry, target: target, timeout: timeout)
        } catch {
            initialized.cancel()
            throw error
        }
        _ = try await initialized.value

        // After `initialized`, send configurationDone; the stopOnEntry stop
        // arrives shortly after (or, on some targets, already has).
        _ = try await entry.client.request("configurationDone", timeout: timeout)
        try await awaitStop(entry, after: version, timeout: timeout)
    }

    private func sendInitializeAndTarget(
        _ entry: SessionEntry,
        target: Session.Target,
        timeout: Double
    ) async throws {
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
            entry.expectedStopReason = .entry
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
            entry.expectedStopReason = .attach
            _ = try await entry.client.request(
                "attach",
                arguments: AttachArgs(pid: Int(pid), stopOnEntry: true, initCommands: Self.initCommands),
                timeout: timeout
            )
        }
    }

    private func startListener(_ entry: SessionEntry) {
        // Captures only the entry's immutable, Sendable parts: the task runs
        // off the actor, and the entry's mutable state belongs to it.
        let client = entry.client, id = entry.id
        entry.listener = Task { [weak self] in
            let stream = await client.events()
            for await event in stream {
                await self?.handleEvent(event, entryID: id)
            }
            await self?.markTerminated(entryID: id)
        }
    }

    /// Apply an event to the session. Called only by the listener, in event
    /// order — the one writer of `info.state` from events.
    private func handleEvent(_ event: DAPEvent, entryID: String) {
        guard let entry = sessions[entryID] else { return }
        switch event.event {
        case "stopped":
            if let body = try? event.decodeBody(StoppedEventBody.self) {
                var reason = body.reason
                if let expected = entry.expectedStopReason, Self.isRequestedPause(body) {
                    reason = expected.rawValue
                }
                entry.info.state = .stopped
                entry.info.stopReason = StopReason(
                    reason: reason,
                    threadID: body.threadId ?? entry.stoppedThreadId ?? 1,
                    description: body.description,
                    hitBreakpointIDs: body.hitBreakpointIds
                )
                entry.stoppedThreadId = body.threadId ?? entry.stoppedThreadId
                recordStateChange(entry)
            }
        case "continued":
            entry.info.state = .running
            entry.info.stopReason = nil
            recordStateChange(entry)
        case "terminated", "exited":
            entry.info.state = .terminated
            recordStateChange(entry)
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
            // Only breakpoints we set are tracked; an update for an id we
            // haven't recorded yet is covered by the setBreakpoints reply.
            if let body = try? event.decodeBody(BreakpointEventBody.self),
               let bid = body.breakpoint.id,
               var tracked = entry.breakpoints[bid] {
                let existing = tracked.breakpoint
                tracked.breakpoint = Breakpoint(
                    id: bid,
                    verified: body.breakpoint.verified,
                    line: body.breakpoint.line ?? existing.line,
                    source: body.breakpoint.source?.path ?? existing.source,
                    message: body.breakpoint.message ?? (body.breakpoint.verified ? nil : existing.message),
                    condition: existing.condition,
                    hitCondition: existing.hitCondition
                )
                entry.breakpoints[bid] = tracked
            }
        default:
            break
        }
    }

    /// lldb-dap's event stream ended (it exited).
    private func markTerminated(entryID: String) {
        guard let entry = sessions[entryID] else { return }
        entry.info.state = .terminated
        recordStateChange(entry)
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

extension Local {
    init(_ variable: DAPVariable) {
        self.init(
            name: variable.name,
            type: variable.type,
            value: variable.value,
            variablesReference: variable.variablesReference
        )
    }
}
