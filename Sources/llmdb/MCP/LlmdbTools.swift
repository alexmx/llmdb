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
            backtrace, locals, expand, threads, expr, output,
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
        @InputProperty("Source file path")
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
        @InputProperty("Path to the binary to debug")
        var binary: String
        @InputProperty("Arguments forwarded to the binary")
        var args: [String]?
    }

    struct AttachToolArgs: MCPToolInput {
        @InputProperty("Host PID. Mutually exclusive with `app`.")
        var pid: Int?
        @InputProperty(
            "iOS Simulator bundle ID (resolved via xcrun simctl in the booted sim). Mutually exclusive with `pid`."
        )
        var app: String?
    }

    struct SessionToolArgs: MCPToolInput {
        @InputProperty("Session ID (omit when only one is active)")
        var session_id: String?
    }

    struct BreakSetToolArgs: MCPToolInput {
        @InputProperty("Source file path")
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
        @InputProperty("variablesReference from a locals/expand entry (must be non-zero)")
        var variables_reference: Int
        @InputProperty("Session ID (omit when only one is active)")
        var session_id: String?
    }

    struct OutputToolArgs: MCPToolInput {
        @InputProperty("Drain the buffer so the next call returns only output produced after this one")
        var clear: Bool?
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
        try await callJSON("launch", LaunchParams(binary: args.binary, args: args.args), SessionSnapshot.self)
    }

    static let attach = MCPTool(
        name: "llmdb_attach",
        description: "Attach to a running process by host PID, or to an iOS Simulator app by bundle ID (resolved via xcrun simctl in the booted sim). Pass exactly one of pid/app. Target pauses on attach."
    ) { (args: AttachToolArgs) in
        try await callJSON(
            "attach",
            AttachParams(pid: args.pid.map { Int32($0) }, app: args.app),
            SessionSnapshot.self
        )
    }

    static let stop = MCPTool(
        name: "llmdb_stop",
        description: "Detach or terminate a session."
    ) { (args: SessionToolArgs) in
        try await callJSON("stop", SessionParams(sessionId: args.session_id), StopResult.self)
    }

    static let sessions = MCPTool(
        name: "llmdb_sessions",
        description: "List active debug sessions. Use to find a sessionId or check state after llmdb_continue wait=0."
    ) { (_: SessionToolArgs) in
        try await callJSON("sessions", EmptyParams(), [Session].self)
    }

    static let breakSet = MCPTool(
        name: "llmdb_break_set",
        description: "Set a source breakpoint at file:line. Optional condition / hit_condition fire it selectively. verified=false before module load is normal — flips true later; the message field explains."
    ) { (args: BreakSetToolArgs) in
        try await callJSON(
            "break.set",
            BreakSetParams(
                sessionId: args.session_id,
                file: args.file,
                line: args.line,
                condition: args.condition,
                hitCondition: args.hit_condition
            ),
            BreakSetResult.self
        )
    }

    static let continueExec = MCPTool(
        name: "llmdb_continue",
        description: "Resume execution. wait (seconds) blocks until next stop, default 60. wait=0 fires and returns immediately (state=running) — then call llmdb_wait or poll llmdb_sessions. Use wait=0 for interactive UI debugging where the next stop may take any amount of time."
    ) { (args: ExecToolArgs) in
        try await callJSON(
            "continue",
            ExecParams(sessionId: args.session_id, wait: args.wait),
            SessionSnapshot.self
        )
    }

    static let runUntil = MCPTool(
        name: "llmdb_run_until",
        description: "Set a breakpoint at file:line and continue, in one call. Use when the intent is `run until execution reaches here`. Same wait semantics as llmdb_continue."
    ) { (args: RunUntilToolArgs) in
        try await callJSON(
            "run-until",
            RunUntilParams(sessionId: args.session_id, file: args.file, line: args.line, wait: args.wait),
            BreakSetResult.self
        )
    }

    static let interrupt = MCPTool(
        name: "llmdb_interrupt",
        description: "Pause a running session. wait default 10s; wait=0 returns immediately."
    ) { (args: ExecToolArgs) in
        try await callJSON(
            "interrupt",
            ExecParams(sessionId: args.session_id, wait: args.wait),
            SessionSnapshot.self
        )
    }

    static let step = MCPTool(
        name: "llmdb_step",
        description: "Step one source line. granularity: over (default), in, out. wait default 30s; wait=0 returns immediately."
    ) { (args: StepToolArgs) in
        let g = StepGranularity(rawValue: (args.granularity ?? "over").lowercased()) ?? .over
        return try await callJSON(
            "step",
            StepParams(sessionId: args.session_id, granularity: g, wait: args.wait),
            SessionSnapshot.self
        )
    }

    static let wait = MCPTool(
        name: "llmdb_wait",
        description: "Block until the session stops or terminates. Returns immediately if already stopped. Pair with continue/step/interrupt wait=0."
    ) { (args: WaitToolArgs) in
        try await callJSON(
            "wait",
            WaitParams(sessionId: args.session_id, timeout: args.timeout),
            SessionSnapshot.self
        )
    }

    static let backtrace = MCPTool(
        name: "llmdb_bt",
        description: "Structured backtrace for the stopped thread. Call after a stop event to see where execution is."
    ) { (args: BtToolArgs) in
        try await callJSON(
            "bt",
            BtParams(sessionId: args.session_id, threadId: args.thread, depth: args.depth),
            BacktraceResult.self
        )
    }

    static let locals = MCPTool(
        name: "llmdb_locals",
        description: "Typed locals for a stack frame (default frame=0, the top frame). Values are lldb-formatted strings — no extra parsing needed. An entry with a non-zero variablesReference is structured (struct/array/object) — drill into it with llmdb_expand."
    ) { (args: LocalsToolArgs) in
        try await callJSON(
            "locals",
            LocalsParams(sessionId: args.session_id, threadId: args.thread, frame: args.frame),
            LocalsResult.self
        )
    }

    static let expand = MCPTool(
        name: "llmdb_expand",
        description: "Drill into a structured value by its variablesReference (from a llmdb_locals or prior llmdb_expand entry). Returns the children, each with its own variablesReference for deeper nesting."
    ) { (args: ExpandToolArgs) in
        try await callJSON(
            "expand",
            ExpandParams(sessionId: args.session_id, variablesReference: args.variables_reference),
            ExpandResult.self
        )
    }

    static let threads = MCPTool(
        name: "llmdb_threads",
        description: "List threads in a stopped session."
    ) { (args: SessionToolArgs) in
        try await callJSON("threads", SessionParams(sessionId: args.session_id), ThreadsResult.self)
    }

    static let output = MCPTool(
        name: "llmdb_output",
        description: "The target's captured stdout/stderr/console output, oldest first, each chunk tagged with its category. Pass clear=true to drain so the next call returns only newer output."
    ) { (args: OutputToolArgs) in
        try await callJSON("output", OutputParams(sessionId: args.session_id, clear: args.clear), OutputResult.self)
    }

    static let expr = MCPTool(
        name: "llmdb_expr",
        description: "Evaluate an expression in a stack frame (default frame=0). Use when llmdb_locals isn't enough — field access (self.state.count), method calls, arithmetic over locals."
    ) { (args: ExprToolArgs) in
        try await callJSON(
            "expr",
            ExprParams(sessionId: args.session_id, expression: args.expression, frame: args.frame),
            ExprResult.self
        )
    }

    static let breakList = MCPTool(
        name: "llmdb_break_list",
        description: "List breakpoints in the session."
    ) { (args: SessionToolArgs) in
        try await callJSON("break.list", SessionParams(sessionId: args.session_id), BreakListResult.self)
    }

    static let breakDelete = MCPTool(
        name: "llmdb_break_delete",
        description: "Delete a breakpoint by id. Returns the remaining breakpoints."
    ) { (args: BreakDeleteToolArgs) in
        try await callJSON(
            "break.delete",
            BreakDeleteParams(sessionId: args.session_id, id: args.id),
            BreakListResult.self
        )
    }

    static let breakException = MCPTool(
        name: "llmdb_break_exception",
        description: "Stop when the target throws. Pass adapter filter ids (e.g. swift_throw) to enable; an empty array clears them. The reply lists `available` filters and the `enabled` set. Call with [] first to discover what the adapter supports."
    ) { (args: BreakExceptionToolArgs) in
        try await callJSON(
            "break.exception",
            BreakExceptionParams(sessionId: args.session_id, filters: args.filters),
            BreakExceptionResult.self
        )
    }

    static let doctor = MCPTool(
        name: "llmdb_doctor",
        description: "Diagnose the environment: lldb-dap path, socket dir writable, daemon reachable. Returns checks[]. Run when something seems off."
    ) { (_: DoctorToolArgs) in
        let report = await Doctor.runChecks()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        return .text(String(decoding: data, as: UTF8.self))
    }

    // MARK: - Helpers

    /// Call the daemon and encode the typed result as JSON for the MCP reply.
    private static func callJSON<R: Codable & Sendable>(
        _ method: String,
        _ params: some Encodable & Sendable,
        _ resultType: R.Type
    ) async throws -> MCPToolResult {
        let result = try await DaemonClient.call(method: method, params: params, as: R.self)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(result)
        return .text(String(decoding: data, as: UTF8.self))
    }
}
