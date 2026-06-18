import Foundation

// JSON-RPC wire types for `llmdbd`: the envelope (request/response) and the
// per-verb parameter and result shapes. Shared between the daemon (server side
// encodes results) and DaemonClient callers (client side encodes params,
// decodes results). Field names ARE the wire contract — agents depend on them.

// MARK: - Envelope

struct RPCRequest<P: Encodable & Sendable>: Encodable, Sendable {
    let id: Int
    let method: String
    let params: P
}

struct RPCResponse<T: Decodable & Sendable>: Decodable, Sendable {
    let id: Int
    let result: T?
    let error: String?
}

struct EmptyParams: Codable, Sendable {}

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
/// wire shape stays human-friendly.
enum StepGranularity: String, Codable, Sendable {
    case over, `in`, out

    var dapCommand: String {
        switch self {
        case .over: "next"
        case .in:   "stepIn"
        case .out:  "stepOut"
        }
    }
}

// MARK: - Params

struct LaunchParams: Codable, Sendable {
    let binary: String
    let args: [String]?
}

struct AttachParams: Codable, Sendable {
    let pid: Int32
}

struct SessionParams: Codable, Sendable {
    let sessionId: String?
}

struct BreakSetParams: Codable, Sendable {
    let sessionId: String?
    let file: String
    let line: Int
}

struct BtParams: Codable, Sendable {
    let sessionId: String?
    let threadId: Int?
    let depth: Int?
}

struct LocalsParams: Codable, Sendable {
    let sessionId: String?
    let threadId: Int?
    let frame: Int?
}

struct StepParams: Codable, Sendable {
    let sessionId: String?
    let granularity: StepGranularity
}

// MARK: - Results

struct BreakSetResult: Codable, Sendable {
    let snapshot: SessionSnapshot
    let breakpoint: Breakpoint
}

struct BacktraceResult: Codable, Sendable {
    let frames: [Frame]
}

struct LocalsResult: Codable, Sendable {
    let locals: [Local]
}

struct ThreadsResult: Codable, Sendable {
    let threads: [Thread]
}

struct StopResult: Codable, Sendable {
    let ok: Bool
}
