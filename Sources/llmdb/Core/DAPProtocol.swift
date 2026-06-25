import Foundation

// DAP wire types — request `arguments` payloads we send, response `body` and
// event `body` payloads we decode. Mirrors the subset of Debug Adapter Protocol
// we actually use; intentionally not a full DAP schema.
//
// Shared between SessionManager (uses these to build requests) and the
// DAPClient tests (drive lldb-dap directly).

// MARK: - Initialize

struct InitializeArgs: Encodable {
    let clientID: String
    let clientName: String
    let adapterID: String
    let linesStartAt1: Bool
    let columnsStartAt1: Bool
    let pathFormat: String
    let supportsRunInTerminalRequest: Bool
}

/// `initialize` response body — we only decode the exception-breakpoint
/// filters the adapter advertises (e.g. swift_throw, cpp_catch).
struct InitializeResponseBody: Decodable {
    let exceptionBreakpointFilters: [DAPExceptionFilter]?
}

struct DAPExceptionFilter: Decodable {
    let filter: String
    let label: String?
    let `default`: Bool?
}

// MARK: - Exception breakpoints

struct SetExceptionBreakpointsArgs: Encodable {
    let filters: [String]
}

// MARK: - Launch / Attach

struct LaunchArgs: Encodable {
    let program: String
    let args: [String]
    let stopOnEntry: Bool
}

struct AttachArgs: Encodable {
    let pid: Int
    /// Pause the target on attach. Without this, lldb-dap may detach almost
    /// immediately after `configurationDone` (it considers the session
    /// "complete" with nothing to do).
    let stopOnEntry: Bool
}

// MARK: - Breakpoints

struct SourceArg: Encodable, Decodable {
    let path: String?
    let name: String?
    init(path: String) {
        self.path = path; self.name = nil
    }
}

struct BPLine: Encodable {
    let line: Int
    /// Expression that must be true for the breakpoint to fire.
    var condition: String?
    /// lldb hit-count expression, e.g. ">5" or "3" — fires once the count matches.
    var hitCondition: String?
}

struct SetBreakpointsArgs: Encodable {
    let source: SourceArg
    let breakpoints: [BPLine]
}

struct SetBreakpointsBody: Decodable {
    let breakpoints: [DAPBreakpointInfo]
}

struct DAPBreakpointInfo: Decodable {
    let id: Int?
    let verified: Bool
    let line: Int?
    let source: SourceArg?
    let message: String?
}

struct BreakpointEventBody: Decodable {
    let reason: String
    let breakpoint: DAPBreakpointInfo
}

// MARK: - Execution

/// Used by `continue`, `pause`, `next`, `stepIn`, `stepOut` — all DAP commands
/// that target a single thread with no other parameters.
struct ThreadIdArgs: Encodable {
    let threadId: Int
}

/// Alias for readability at call sites. (Same shape.)
typealias ContinueArgs = ThreadIdArgs

struct StoppedEventBody: Decodable {
    let reason: String
    let threadId: Int?
    let description: String?
    let hitBreakpointIds: [Int]?
}

/// `output` event: a chunk of text the target (or adapter) wrote. `category`
/// is stdout/stderr/console/telemetry/important; absent means console.
struct OutputEventBody: Decodable {
    let category: String?
    let output: String
}

// MARK: - Threads

struct ThreadsBody: Decodable {
    let threads: [DAPThread]
}

struct DAPThread: Decodable {
    let id: Int
    let name: String
}

// MARK: - Evaluate

struct EvaluateArgs: Encodable {
    let expression: String
    let frameId: Int?
    /// "watch" | "repl" | "hover" | "clipboard" | "variables" — affects how
    /// lldb-dap formats the result. "repl" matches what a user would type.
    let context: String?
}

struct EvaluateBody: Decodable {
    let result: String
    let type: String?
    let variablesReference: Int
}

// MARK: - Stack / Scopes / Variables

struct StackTraceArgs: Encodable {
    let threadId: Int
    let startFrame: Int
    let levels: Int
}

struct StackTraceBody: Decodable {
    let stackFrames: [DAPFrame]
}

struct DAPFrame: Decodable {
    let id: Int
    let name: String
    let source: SourceArg?
    let line: Int?
    let column: Int?
}

struct ScopesArgs: Encodable {
    let frameId: Int
}

struct ScopesBody: Decodable {
    let scopes: [DAPScope]
}

struct DAPScope: Decodable {
    let name: String
    let variablesReference: Int
}

struct VariablesArgs: Encodable {
    let variablesReference: Int
}

struct VariablesBody: Decodable {
    let variables: [DAPVariable]
}

struct DAPVariable: Decodable {
    let name: String
    let value: String
    let type: String?
    let variablesReference: Int
}
