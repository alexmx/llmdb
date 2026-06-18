import Foundation
import SwiftMCP

enum LlmdbTools {
    /// MCP tool surface — mirrors the CLI 1:1. Each tool forwards to the
    /// daemon over the Unix socket via `DaemonClient`.
    static var all: [MCPTool] {
        [
            launch, attach, stop, sessions,
            breakSet, breakList, breakDelete,
            continueExec, interrupt, step,
            backtrace, locals, threads, expr
        ]
    }

    // MARK: - Args

    struct LaunchToolArgs: MCPToolInput {
        @InputProperty("Path to the binary to debug")
        var binary: String
        @InputProperty("Arguments forwarded to the binary")
        var args: [String]?
    }

    struct AttachToolArgs: MCPToolInput {
        @InputProperty("Process ID to attach to")
        var pid: Int
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
        @InputProperty("Session ID")
        var session_id: String?
    }

    struct StepToolArgs: MCPToolInput {
        @InputProperty("Granularity: over (default), in, or out")
        var granularity: String?
        @InputProperty("Session ID")
        var session_id: String?
    }

    struct BtToolArgs: MCPToolInput {
        @InputProperty("Thread ID (defaults to the stopped thread)")
        var thread: Int?
        @InputProperty("Maximum depth (default: full stack)")
        var depth: Int?
        @InputProperty("Session ID")
        var session_id: String?
    }

    struct LocalsToolArgs: MCPToolInput {
        @InputProperty("Frame index (default 0)")
        var frame: Int?
        @InputProperty("Thread ID (defaults to the stopped thread)")
        var thread: Int?
        @InputProperty("Session ID")
        var session_id: String?
    }

    struct ExprToolArgs: MCPToolInput {
        @InputProperty("Expression to evaluate (e.g. `self.state.count` or `a + b`)")
        var expression: String
        @InputProperty("Frame index (default 0, the top frame)")
        var frame: Int?
        @InputProperty("Session ID")
        var session_id: String?
    }

    struct BreakDeleteToolArgs: MCPToolInput {
        @InputProperty("Breakpoint id to delete")
        var id: Int
        @InputProperty("Session ID")
        var session_id: String?
    }

    // MARK: - Tools

    static let launch = MCPTool(
        name: "llmdb_launch",
        description: "Launch a binary under lldb-dap. Stops on entry; returns {sessionId, state, stopReason}."
    ) { (args: LaunchToolArgs) in
        try await callJSON("launch", LaunchParams(binary: args.binary, args: args.args), SessionSnapshot.self)
    }

    static let attach = MCPTool(
        name: "llmdb_attach",
        description: "Attach to a running process by PID. lldb-dap pauses the target on attach; returns {sessionId, state, stopReason}."
    ) { (args: AttachToolArgs) in
        try await callJSON("attach", AttachParams(pid: Int32(args.pid)), SessionSnapshot.self)
    }

    static let stop = MCPTool(
        name: "llmdb_stop",
        description: "Detach or terminate a session."
    ) { (args: SessionToolArgs) in
        try await callJSON("stop", SessionParams(sessionId: args.session_id), StopResult.self)
    }

    static let sessions = MCPTool(
        name: "llmdb_sessions",
        description: "List active debug sessions."
    ) { (_: SessionToolArgs) in
        try await callJSON("sessions", EmptyParams(), [Session].self)
    }

    static let breakSet = MCPTool(
        name: "llmdb_break_set",
        description: "Set a source breakpoint by file:line. Returns the verified breakpoint and a session snapshot."
    ) { (args: BreakSetToolArgs) in
        try await callJSON(
            "break.set",
            BreakSetParams(sessionId: args.session_id, file: args.file, line: args.line),
            BreakSetResult.self
        )
    }

    static let continueExec = MCPTool(
        name: "llmdb_continue",
        description: "Continue execution; returns when the target stops again, with stopReason."
    ) { (args: SessionToolArgs) in
        try await callJSON("continue", SessionParams(sessionId: args.session_id), SessionSnapshot.self)
    }

    static let interrupt = MCPTool(
        name: "llmdb_interrupt",
        description: "Pause a running session; returns once stopped."
    ) { (args: SessionToolArgs) in
        try await callJSON("interrupt", SessionParams(sessionId: args.session_id), SessionSnapshot.self)
    }

    static let step = MCPTool(
        name: "llmdb_step",
        description: "Step one source line. granularity = over (default) | in | out. Returns when the target stops again."
    ) { (args: StepToolArgs) in
        let g = StepGranularity(rawValue: (args.granularity ?? "over").lowercased()) ?? .over
        return try await callJSON(
            "step",
            StepParams(sessionId: args.session_id, granularity: g),
            SessionSnapshot.self
        )
    }

    static let backtrace = MCPTool(
        name: "llmdb_bt",
        description: "Structured backtrace for the stopped thread."
    ) { (args: BtToolArgs) in
        try await callJSON(
            "bt",
            BtParams(sessionId: args.session_id, threadId: args.thread, depth: args.depth),
            BacktraceResult.self
        )
    }

    static let locals = MCPTool(
        name: "llmdb_locals",
        description: "Typed locals for a stack frame (default: top frame)."
    ) { (args: LocalsToolArgs) in
        try await callJSON(
            "locals",
            LocalsParams(sessionId: args.session_id, threadId: args.thread, frame: args.frame),
            LocalsResult.self
        )
    }

    static let threads = MCPTool(
        name: "llmdb_threads",
        description: "List threads in a stopped session."
    ) { (args: SessionToolArgs) in
        try await callJSON("threads", SessionParams(sessionId: args.session_id), ThreadsResult.self)
    }

    static let expr = MCPTool(
        name: "llmdb_expr",
        description: "Evaluate an expression in the context of a stack frame (default: top frame). Returns {value, type, variablesReference}. Use after `llmdb_locals` when you need to read a field or call expression that's not in locals."
    ) { (args: ExprToolArgs) in
        try await callJSON(
            "expr",
            ExprParams(sessionId: args.session_id, expression: args.expression, frame: args.frame),
            ExprResult.self
        )
    }

    static let breakList = MCPTool(
        name: "llmdb_break_list",
        description: "List all breakpoints in a session."
    ) { (args: SessionToolArgs) in
        try await callJSON("break.list", SessionParams(sessionId: args.session_id), BreakListResult.self)
    }

    static let breakDelete = MCPTool(
        name: "llmdb_break_delete",
        description: "Delete a breakpoint by id. Returns the surviving breakpoints."
    ) { (args: BreakDeleteToolArgs) in
        try await callJSON(
            "break.delete",
            BreakDeleteParams(sessionId: args.session_id, id: args.id),
            BreakListResult.self
        )
    }

    // MARK: - Helpers

    /// Call the daemon and encode the typed result as JSON for the MCP reply.
    private static func callJSON<P: Encodable & Sendable, R: Codable & Sendable>(
        _ method: String,
        _ params: P,
        _ resultType: R.Type
    ) async throws -> MCPToolResult {
        let result = try await DaemonClient.call(method: method, params: params, as: R.self)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(result)
        return .text(String(decoding: data, as: UTF8.self))
    }
}
