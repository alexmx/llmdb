import ArgumentParser
import Foundation

// JSON-RPC wire types for `llmdbd`: the envelope (request/response) and the
// per-verb parameter and result shapes. Shared between the daemon (server side
// encodes results) and DaemonClient callers (client side encodes params,
// decodes results). Field names ARE the wire contract — agents depend on them.

// MARK: - Envelope

struct RPCRequest<P: Encodable & Sendable>: Encodable {
    let id: Int
    let method: String
    let params: P
}

struct RPCResponse<T: Decodable & Sendable>: Decodable {
    let id: Int
    let result: T?
    let error: String?
}

struct EmptyParams: Codable {}

/// Server-side success envelope. Generic so we can encode any verb's result.
struct RPCResult<T: Encodable>: Encodable {
    let id: Int
    let result: T
}

/// Server-side error envelope.
struct RPCError: Encodable {
    let id: Int
    let error: String
}

// MARK: - Step granularity

/// Single source-line step direction. Codable as a lowercase string so the
/// wire shape stays human-friendly; `EnumerableFlag` so the CLI exposes
/// `--over` / `--in` / `--out` without a manual three-flag dance.
enum StepGranularity: String, Codable, EnumerableFlag {
    case over, `in`, out

    var dapCommand: String {
        switch self {
        case .over: "next"
        case .in: "stepIn"
        case .out: "stepOut"
        }
    }
}

// MARK: - Params

struct LaunchParams: Codable {
    let binary: String
    let args: [String]?
}

/// Attach by PID OR by iOS Simulator bundle ID. Exactly one must be set.
struct AttachParams: Codable {
    let pid: Int32?
    let app: String?
}

struct SessionParams: Codable {
    let sessionId: String?
}

/// Used by both `break.set` and `run-until` (the latter = set BP + continue).
struct BreakSetParams: Codable {
    let sessionId: String?
    let file: String
    let line: Int
}

struct BtParams: Codable {
    let sessionId: String?
    let threadId: Int?
    let depth: Int?
}

struct LocalsParams: Codable {
    let sessionId: String?
    let threadId: Int?
    let frame: Int?
}

struct StepParams: Codable {
    let sessionId: String?
    let granularity: StepGranularity
}

struct ExprParams: Codable {
    let sessionId: String?
    let expression: String
    let frame: Int?
}

struct BreakDeleteParams: Codable {
    let sessionId: String?
    let id: Int
}

// MARK: - Results

struct BreakSetResult: Codable {
    let snapshot: SessionSnapshot
    let breakpoint: Breakpoint
}

struct BacktraceResult: Codable {
    let frames: [Frame]
}

struct LocalsResult: Codable {
    let locals: [Local]
}

struct ThreadsResult: Codable {
    let threads: [Thread]
}

struct ExprResult: Codable {
    let value: String
    let type: String?
    let variablesReference: Int
}

struct BreakListResult: Codable {
    let breakpoints: [Breakpoint]
}

struct StopResult: Codable {
    let ok: Bool
}
