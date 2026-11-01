import Foundation
import SwiftMCP

enum LlmdbTools {
    /// MCP tool surface — mirrors the CLI 1:1. Each tool forwards to the
    /// daemon over the Unix socket via `DaemonClient`.
    static var all: [MCPTool] {
        [
            launch, attach, stop, sessions,
            breakSet, breakList, breakDelete, breakException,
            continueExec, runUntil, interrupt, step, wait,
            backtrace, locals, expand, scopes, threads, expr, output, setVar,
            doctor
        ]
    }

    struct DoctorToolArgs: MCPToolInput {}

    struct ExecToolArgs: MCPToolInput {
        @InputProperty("Session ID (omit when only one is active)")
        var session_id: String?
        @InputProperty(
            "Seconds to wait for next stop. Omit for default (60s continue / 10s interrupt / 30s step). 0 = fire-and-forget — pair with llmdb_wait."
        )
        var wait: Double?
    }

    struct WaitToolArgs: MCPToolInput {
        @InputProperty("Session ID (omit when only one is active)")
        var session_id: String?
        @InputProperty("Timeout in seconds (default 60)")
        var timeout: Double?
    }

    struct RunUntilToolArgs: MCPToolInput {
        @InputProperty("Source file: absolute, relative, or a bare name like main.swift (matched by path suffix)")
        var file: String
        @InputProperty("Line number")
        var line: Int
        @InputProperty("Session ID (omit when only one is active)")
        var session_id: String?
        @InputProperty("Seconds to wait for the BP to hit. Omit for 60s default; 0 = fire-and-forget.")
        var wait: Double?
    }

    // MARK: - Args

    struct LaunchToolArgs: MCPToolInput {
        @InputProperty("Path to the binary to debug (relative paths resolve against this server's working directory)")
        var binary: String
        @InputProperty("Arguments forwarded to the binary")
        var args: [String]?
        @InputProperty(
            "Seconds lldb-dap may take per setup step before giving up and releasing the target. Omit for 60s."
        )
        var timeout: Double?
    }

    struct AttachToolArgs: MCPToolInput {
        @InputProperty("Host PID. Mutually exclusive with `app`.")
        var pid: Int?
        @InputProperty(
            "iOS Simulator bundle ID (resolved via xcrun simctl in the booted sim). Mutually exclusive with `pid`."
        )
        var app: String?
        @InputProperty(
            "Seconds lldb-dap may take per setup step before giving up and releasing the target. Omit for 60s."
        )
        var timeout: Double?
    }

    struct SessionToolArgs: MCPToolInput {
        @InputProperty("Session ID (omit when only one is active)")
        var session_id: String?
    }

    struct BreakSetToolArgs: MCPToolInput {
        @InputProperty("Source file: absolute, relative, or a bare name like main.swift (matched by path suffix)")
        var file: String
        @InputProperty("Line number")
        var line: Int
        @InputProperty("Session ID (omit when only one is active)")
        var session_id: String?
        @InputProperty("Fire only when this expression is true in the target's language, e.g. `n > 100`")
        var condition: String?
        @InputProperty("Fire on a hit-count match, e.g. `>5` (every hit past 5) or `3` (the 3rd hit)")
        var hit_condition: String?
    }

    struct StepToolArgs: MCPToolInput {
        @InputProperty("over (default), in, or out")
        var granularity: String?
        @InputProperty("Session ID (omit when only one is active)")
        var session_id: String?
        @InputProperty("Seconds to wait for next stop. Omit for 30s default; 0 = fire-and-forget.")
        var wait: Double?
    }

    struct BtToolArgs: MCPToolInput {
        @InputProperty("Thread ID (defaults to the stopped thread)")
        var thread: Int?
        @InputProperty("Max frames (default: full stack)")
        var depth: Int?
        @InputProperty("Session ID (omit when only one is active)")
        var session_id: String?
    }

    struct LocalsToolArgs: MCPToolInput {
        @InputProperty("Frame index (default 0 = top frame)")
        var frame: Int?
        @InputProperty("Thread ID (defaults to the stopped thread)")
        var thread: Int?
        @InputProperty("Session ID (omit when only one is active)")
        var session_id: String?
    }

    struct ExpandToolArgs: MCPToolInput {
        @InputProperty("variablesReference from a locals/expand/scopes entry (must be non-zero)")
        var variables_reference: Int
        @InputProperty("Session ID (omit when only one is active)")
        var session_id: String?
    }

    struct ScopesToolArgs: MCPToolInput {
        @InputProperty("Frame index (default 0 = top frame)")
        var frame: Int?
        @InputProperty("Thread ID (defaults to the stopped thread)")
        var thread: Int?
        @InputProperty("Session ID (omit when only one is active)")
        var session_id: String?
    }

    struct StopToolArgs: MCPToolInput {
        @InputProperty(
            "detach (target keeps running) or terminate (kill it). Omit for the default: terminate launched, detach attached."
        )
        var mode: String?
        @InputProperty("Session ID (omit when only one is active)")
        var session_id: String?
    }

    struct OutputToolArgs: MCPToolInput {
        @InputProperty("Drain the buffer so the next call returns only output produced after this one")
        var clear: Bool?
        @InputProperty("Session ID (omit when only one is active)")
        var session_id: String?
    }

    struct SetVarToolArgs: MCPToolInput {
        @InputProperty("Assignable target: a local name, or an expression like `self.count` or `arr[0]`")
        var target: String
        @InputProperty("New value in the target's language, e.g. 42, true, \"hi\"")
        var value: String
        @InputProperty("Frame index (default 0 = top frame)")
        var frame: Int?
        @InputProperty("Session ID (omit when only one is active)")
        var session_id: String?
    }

    struct ExprToolArgs: MCPToolInput {
        @InputProperty("Expression to evaluate (e.g. `self.state.count` or `a + b`)")
        var expression: String
        @InputProperty("Frame index (default 0 = top frame)")
        var frame: Int?
        @InputProperty("Session ID (omit when only one is active)")
        var session_id: String?
    }

    struct BreakDeleteToolArgs: MCPToolInput {
        @InputProperty("Breakpoint id to delete")
        var id: Int
        @InputProperty("Session ID (omit when only one is active)")
        var session_id: String?
    }

    struct BreakExceptionToolArgs: MCPToolInput {
        @InputProperty(
            "Filter ids to enable (e.g. swift_throw, cpp_catch). Empty array clears them and lists what the adapter supports in `available`."
        )
        var filters: [String]
        @InputProperty("Session ID (omit when only one is active)")
        var session_id: String?
    }

    // MARK: - Tools

    static let launch = MCPTool(
        name: "llmdb_launch",
        description: "Launch a binary under lldb-dap; stops on entry. `.app` bundles (or paths inside one) route via LaunchServices so the app registers with AppKit — needed for accessibility / UI automation. Returns sessionId. Next: llmdb_break_set + llmdb_continue, or llmdb_run_until."
    ) { (args: LaunchToolArgs) in
        try await callJSON(
            RPC.launch,
            LaunchParams(binary: absolutePath(args.binary), args: args.args, timeout: args.timeout)
        )
    }

    static let attach = MCPTool(
        name: "llmdb_attach",
        description: "Attach to a running process by host PID, or to an iOS Simulator app by bundle ID (resolved via xcrun simctl in the booted sim). Pass exactly one of pid/app. Target pauses on attach."
    ) { (args: AttachToolArgs) in
        let pid = try args.pid.map { raw in
            // Int32(raw) would trap — and take the MCP server down — on an
            // out-of-range value.
            guard let pid = Int32(exactly: raw), pid > 0 else {
                throw LlmdbError.invalidArgument(name: "pid", value: "\(raw)", valid: ["1...\(Int32.max)"])
            }
            return pid
        }
        return try await callJSON(RPC.attach, AttachParams(pid: pid, app: args.app, timeout: args.timeout))
    }

    static let stop = MCPTool(
        name: "llmdb_stop",
        description: "End a session. Default: terminate launched targets, detach from attached ones (target keeps running); override with mode=detach|terminate. Reply's action says what happened: terminated, detached, or exited."
    ) { (args: StopToolArgs) in
        let mode = try args.mode.map { try parseChoice($0, as: StopMode.self, name: "mode") }
        return try await callJSON(RPC.stop, StopParams(sessionId: args.session_id, mode: mode))
    }

    static let sessions = MCPTool(
        name: "llmdb_sessions",
        description: "List active debug sessions. Use to find a sessionId or check state after llmdb_continue wait=0."
    ) { (_: SessionToolArgs) in
        try await callJSON(RPC.sessions, EmptyParams())
    }

    static let breakSet = MCPTool(
        name: "llmdb_break_set",
        description: "Set a source breakpoint at file:line. Optional condition / hit_condition fire it selectively. verified=false before module load is normal — flips true later; the message field explains."
    ) { (args: BreakSetToolArgs) in
        try await callJSON(
            RPC.breakSet,
            BreakSetParams(
                sessionId: args.session_id,
                file: args.file,
                line: args.line,
                condition: args.condition,
                hitCondition: args.hit_condition
            )
        )
    }

    static let continueExec = MCPTool(
        name: "llmdb_continue",
        description: "Resume execution. wait (seconds) blocks until next stop, default 60. wait=0 fires and returns immediately (state=running) — then call llmdb_wait or poll llmdb_sessions. Use wait=0 for interactive UI debugging where the next stop may take any amount of time."
    ) { (args: ExecToolArgs) in
        try await callJSON(RPC.continue, ExecParams(sessionId: args.session_id, wait: args.wait))
    }

    static let runUntil = MCPTool(
        name: "llmdb_run_until",
        description: "Set a breakpoint at file:line and continue, in one call. Use when the intent is `run until execution reaches here`. Same wait semantics as llmdb_continue."
    ) { (args: RunUntilToolArgs) in
        try await callJSON(
            RPC.runUntil,
            RunUntilParams(sessionId: args.session_id, file: args.file, line: args.line, wait: args.wait)
        )
    }

    static let interrupt = MCPTool(
        name: "llmdb_interrupt",
        description: "Pause a running session. wait default 10s; wait=0 returns immediately."
    ) { (args: ExecToolArgs) in
        try await callJSON(RPC.interrupt, ExecParams(sessionId: args.session_id, wait: args.wait))
    }

    static let step = MCPTool(
        name: "llmdb_step",
        description: "Step one source line. granularity: over (default), in, out. wait default 30s; wait=0 returns immediately."
    ) { (args: StepToolArgs) in
        let granularity = try args.granularity.map {
            try parseChoice($0, as: StepGranularity.self, name: "granularity")
        } ?? .over
        return try await callJSON(
            RPC.step,
            StepParams(sessionId: args.session_id, granularity: granularity, wait: args.wait)
        )
    }

    static let wait = MCPTool(
        name: "llmdb_wait",
        description: "Block until the session stops or terminates. Returns immediately if already stopped. Pair with continue/step/interrupt wait=0."
    ) { (args: WaitToolArgs) in
        try await callJSON(RPC.wait, WaitParams(sessionId: args.session_id, timeout: args.timeout))
    }

    static let backtrace = MCPTool(
        name: "llmdb_bt",
        description: "Structured backtrace for the stopped thread. Call after a stop event to see where execution is."
    ) { (args: BtToolArgs) in
        try await callJSON(
            RPC.backtrace,
            BtParams(sessionId: args.session_id, threadId: args.thread, depth: args.depth)
        )
    }

    static let locals = MCPTool(
        name: "llmdb_locals",
        description: "Typed locals for a stack frame (default frame=0, the top frame). Values are lldb-formatted strings — no extra parsing needed. An entry with a non-zero variablesReference is structured (struct/array/object) — drill into it with llmdb_expand."
    ) { (args: LocalsToolArgs) in
        try await callJSON(
            RPC.locals,
            LocalsParams(sessionId: args.session_id, threadId: args.thread, frame: args.frame)
        )
    }

    static let expand = MCPTool(
        name: "llmdb_expand",
        description: "Drill into a structured value by its variablesReference (from a llmdb_locals or prior llmdb_expand entry). Returns the children, each with its own variablesReference for deeper nesting."
    ) { (args: ExpandToolArgs) in
        try await callJSON(
            RPC.expand,
            ExpandParams(sessionId: args.session_id, variablesReference: args.variables_reference)
        )
    }

    static let scopes = MCPTool(
        name: "llmdb_scopes",
        description: "List a frame's variable scopes (Locals, Globals, Registers, …), each with a variablesReference. Pass that ref to llmdb_expand to read the scope — this is how you reach globals/statics and registers, which llmdb_locals (Locals only) doesn't return. `expensive: true` marks scopes costly to read."
    ) { (args: ScopesToolArgs) in
        try await callJSON(
            RPC.scopes,
            ScopesParams(sessionId: args.session_id, threadId: args.thread, frame: args.frame)
        )
    }

    static let threads = MCPTool(
        name: "llmdb_threads",
        description: "List threads in a stopped session."
    ) { (args: SessionToolArgs) in
        try await callJSON(RPC.threads, SessionParams(sessionId: args.session_id))
    }

    static let output = MCPTool(
        name: "llmdb_output",
        description: "The target's captured stdout/stderr/console output, oldest first, each chunk tagged with its category. Pass clear=true to drain so the next call returns only newer output."
    ) { (args: OutputToolArgs) in
        try await callJSON(RPC.output, OutputParams(sessionId: args.session_id, clear: args.clear))
    }

    static let setVar = MCPTool(
        name: "llmdb_set_variable",
        description: "Assign a new value to a variable during a stop, to test a hypothesis. `target` is any assignable expression — a local name, `self.count`, `arr[0]`, etc. Returns the variable's updated value and type."
    ) { (args: SetVarToolArgs) in
        try await callJSON(
            RPC.setVar,
            SetVarParams(
                sessionId: args.session_id,
                target: args.target,
                value: args.value,
                frame: args.frame
            )
        )
    }

    static let expr = MCPTool(
        name: "llmdb_expr",
        description: "Evaluate an expression in a stack frame (default frame=0). Use when llmdb_locals isn't enough — field access (self.state.count), method calls, arithmetic over locals. Void calls succeed with type \"void\" and an empty value. ObjC works without @import: Foundation and UIKit/AppKit are imported automatically if needed."
    ) { (args: ExprToolArgs) in
        try await callJSON(
            RPC.expr,
            ExprParams(sessionId: args.session_id, expression: args.expression, frame: args.frame)
        )
    }

    static let breakList = MCPTool(
        name: "llmdb_break_list",
        description: "List breakpoints in the session."
    ) { (args: SessionToolArgs) in
        try await callJSON(RPC.breakList, SessionParams(sessionId: args.session_id))
    }

    static let breakDelete = MCPTool(
        name: "llmdb_break_delete",
        description: "Delete a breakpoint by id. Returns the remaining breakpoints."
    ) { (args: BreakDeleteToolArgs) in
        try await callJSON(RPC.breakDelete, BreakDeleteParams(sessionId: args.session_id, id: args.id))
    }

    static let breakException = MCPTool(
        name: "llmdb_break_exception",
        description: "Stop when the target throws. Pass adapter filter ids (e.g. swift_throw) to enable; an empty array clears them. The reply lists `available` filters and the `enabled` set. Call with [] first to discover what the adapter supports."
    ) { (args: BreakExceptionToolArgs) in
        try await callJSON(RPC.breakException, BreakExceptionParams(sessionId: args.session_id, filters: args.filters))
    }

    static let doctor = MCPTool(
        name: "llmdb_doctor",
        description: "Diagnose the environment: lldb-dap path, socket dir writable, daemon reachable and the same llmdb version. Returns checks[]. Run when something seems off."
    ) { (_: DoctorToolArgs) in
        try await jsonText(Doctor.runChecks())
    }

    // MARK: - Helpers

    /// Parse a case-insensitive choice, rejecting unknown values with the
    /// list of valid ones rather than guessing.
    private static func parseChoice<E: CaseIterable & RawRepresentable>(
        _ raw: String,
        as _: E.Type,
        name: String
    ) throws -> E where E.RawValue == String {
        guard let value = E(rawValue: raw.lowercased()) else {
            throw LlmdbError.invalidArgument(name: name, value: raw, valid: E.allCases.map(\.rawValue))
        }
        return value
    }

    /// Call the daemon and encode the typed result as JSON for the MCP reply.
    private static func callJSON<P>(_ method: RPCMethod<P, some Any>, _ params: P) async throws -> MCPToolResult {
        try await jsonText(DaemonClient.call(method, params))
    }

    /// A tool reply carrying `value` as compact, key-sorted JSON.
    private static func jsonText(_ value: some Encodable) throws -> MCPToolResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try .text(String(decoding: encoder.encode(value), as: UTF8.self))
    }
}
