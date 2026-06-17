import Foundation

// Parameter and result shapes for `llmdbd`'s JSON-RPC verbs.
// Shared between the daemon (encodes) and DaemonClient callers (decode).
// Field names ARE the wire contract — agents depend on them.

// MARK: - Params

struct LaunchParams: Codable, Sendable {
    let binary: String
    let args: [String]?
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

struct StopResult: Codable, Sendable {
    let ok: Bool
}
