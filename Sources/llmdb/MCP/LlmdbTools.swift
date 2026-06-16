import Foundation
import SwiftMCP

enum LlmdbTools {
    /// MCP tool surface — mirrors the CLI 1:1. Stubs throw `notImplemented`
    /// until the corresponding command is wired to `DaemonClient`.
    static var all: [MCPTool] {
        [launch, attach, stop, sessions, breakSet, continueExec, backtrace, locals]
    }

    // MARK: - Args

    struct LaunchArgs: MCPToolInput {
        @InputProperty("Path to the binary to debug")
        var binary: String
        @InputProperty("Arguments forwarded to the binary")
        var args: [String]?
    }

    struct AttachArgs: MCPToolInput {
        @InputProperty("Process ID to attach to")
        var pid: Int?
        @InputProperty("App bundle identifier (iOS Simulator)")
        var app: String?
    }

    struct SessionArgs: MCPToolInput {
        @InputProperty("Session ID (omit when only one is active)")
        var session_id: String?
    }

    struct StopArgs: MCPToolInput {
        @InputProperty("Session ID (omit when only one is active)")
        var session_id: String?
        @InputProperty("Force-terminate instead of detaching")
        var terminate: Bool?
    }

    struct BreakSetArgs: MCPToolInput {
        @InputProperty("Location: `<file>:<line>`")
        var location: String?
        @InputProperty("Set a symbol breakpoint")
        var symbol: String?
        @InputProperty("Set a regex breakpoint")
        var regex: String?
        @InputProperty("Session ID")
        var session_id: String?
    }

    struct FrameArgs: MCPToolInput {
        @InputProperty("Thread ID (defaults to the stopped thread)")
        var thread: Int?
        @InputProperty("Maximum depth (default: full stack)")
        var depth: Int?
        @InputProperty("Session ID")
        var session_id: String?
    }

    struct LocalsArgs: MCPToolInput {
        @InputProperty("Frame index (default 0)")
        var frame: Int?
        @InputProperty("Thread ID (defaults to the stopped thread)")
        var thread: Int?
        @InputProperty("Session ID")
        var session_id: String?
    }

    // MARK: - Tools (stubs)

    static let launch = MCPTool(
        name: "llmdb_launch",
        description: "Launch a binary under lldb-dap. Returns {session_id, state}."
    ) { (_: LaunchArgs) in
        throw LlmdbError.notImplemented("llmdb_launch")
    }

    static let attach = MCPTool(
        name: "llmdb_attach",
        description: "Attach to a running process (--pid) or Simulator app (--app)."
    ) { (_: AttachArgs) in
        throw LlmdbError.notImplemented("llmdb_attach")
    }

    static let stop = MCPTool(
        name: "llmdb_stop",
        description: "Detach (default) or terminate a session."
    ) { (_: StopArgs) in
        throw LlmdbError.notImplemented("llmdb_stop")
    }

    static let sessions = MCPTool(
        name: "llmdb_sessions",
        description: "List active debug sessions."
    ) { (_: SessionArgs) in
        throw LlmdbError.notImplemented("llmdb_sessions")
    }

    static let breakSet = MCPTool(
        name: "llmdb_break_set",
        description: "Set a breakpoint by file:line, symbol, or regex."
    ) { (_: BreakSetArgs) in
        throw LlmdbError.notImplemented("llmdb_break_set")
    }

    static let continueExec = MCPTool(
        name: "llmdb_continue",
        description: "Continue execution; returns when the target stops again with stop_reason."
    ) { (_: SessionArgs) in
        throw LlmdbError.notImplemented("llmdb_continue")
    }

    static let backtrace = MCPTool(
        name: "llmdb_bt",
        description: "Structured backtrace for the stopped thread."
    ) { (_: FrameArgs) in
        throw LlmdbError.notImplemented("llmdb_bt")
    }

    static let locals = MCPTool(
        name: "llmdb_locals",
        description: "Typed locals for a stack frame (default: top frame)."
    ) { (_: LocalsArgs) in
        throw LlmdbError.notImplemented("llmdb_locals")
    }
}
