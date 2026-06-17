import Foundation

// DAP wire types — request `arguments` payloads we send, response `body` and
// event `body` payloads we decode. Mirrors the subset of Debug Adapter Protocol
// we actually use; intentionally not a full DAP schema.
//
// Shared between SessionManager (uses these to build requests) and the
// DAPClient tests (drive lldb-dap directly). M2 adds threads/step/evaluate/etc.

// MARK: - Initialize

struct InitializeArgs: Encodable, Sendable {
    let clientID: String
    let clientName: String
    let adapterID: String
    let linesStartAt1: Bool
    let columnsStartAt1: Bool
    let pathFormat: String
    let supportsRunInTerminalRequest: Bool
}

// MARK: - Launch / Attach

struct LaunchArgs: Encodable, Sendable {
    let program: String
    let args: [String]
    let stopOnEntry: Bool
}

struct AttachArgs: Encodable, Sendable {
    let pid: Int
}

// MARK: - Breakpoints

struct SourceArg: Encodable, Decodable, Sendable {
    let path: String?
    let name: String?
    init(path: String) { self.path = path; self.name = nil }
}

struct BPLine: Encodable, Sendable {
    let line: Int
}

struct SetBreakpointsArgs: Encodable, Sendable {
    let source: SourceArg
    let breakpoints: [BPLine]
}

struct SetBreakpointsBody: Decodable, Sendable {
    let breakpoints: [DAPBreakpointInfo]
}

struct DAPBreakpointInfo: Decodable, Sendable {
    let id: Int?
    let verified: Bool
    let line: Int?
    let source: SourceArg?
    let message: String?
}

struct BreakpointEventBody: Decodable, Sendable {
    let reason: String
    let breakpoint: DAPBreakpointInfo
}

// MARK: - Execution

struct ContinueArgs: Encodable, Sendable {
    let threadId: Int
}

struct StoppedEventBody: Decodable, Sendable {
    let reason: String
    let threadId: Int?
    let description: String?
    let hitBreakpointIds: [Int]?
}

// MARK: - Stack / Scopes / Variables

struct StackTraceArgs: Encodable, Sendable {
    let threadId: Int
    let startFrame: Int
    let levels: Int
}

struct StackTraceBody: Decodable, Sendable {
    let stackFrames: [DAPFrame]
}

struct DAPFrame: Decodable, Sendable {
    let id: Int
    let name: String
    let source: SourceArg?
    let line: Int?
    let column: Int?
}

struct ScopesArgs: Encodable, Sendable {
    let frameId: Int
}

struct ScopesBody: Decodable, Sendable {
    let scopes: [DAPScope]
}

struct DAPScope: Decodable, Sendable {
    let name: String
    let variablesReference: Int
}

struct VariablesArgs: Encodable, Sendable {
    let variablesReference: Int
}

struct VariablesBody: Decodable, Sendable {
    let variables: [DAPVariable]
}

struct DAPVariable: Decodable, Sendable {
    let name: String
    let value: String
    let type: String?
    let variablesReference: Int
}
