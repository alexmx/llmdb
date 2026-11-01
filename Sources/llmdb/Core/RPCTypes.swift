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

/// What `stop` does to the target. Omitted → terminate launched targets,
/// detach from attached ones.
enum StopMode: String, Codable, EnumerableFlag {
    case detach, terminate

    /// Past-tense label reported back to the caller.
    var action: String {
        switch self {
        case .detach: "detached"
        case .terminate: "terminated"
        }
    }

    static func help(for value: StopMode) -> ArgumentHelp? {
        switch value {
        case .detach: "Detach and leave the target running"
        case .terminate: "Kill the target"
        }
    }
}

// MARK: - Params

struct LaunchParams: Codable {
    let binary: String
    let args: [String]?
    /// Seconds each handshake step may take; nil → daemon default (60).
    var timeout: Double?
}

/// Attach by PID OR by iOS Simulator bundle ID. Exactly one must be set.
struct AttachParams: Codable {
    let pid: Int32?
    let app: String?
    /// Seconds each handshake step may take; nil → daemon default (60).
    var timeout: Double?
}

struct SessionParams: Codable {
    let sessionId: String?
}

/// nil → daemon default; 0 → fire-and-forget; >0 → wait N seconds.
struct ExecParams: Codable {
    let sessionId: String?
    let wait: Double?
}

struct WaitParams: Codable {
    let sessionId: String?
    let timeout: Double?
}

struct BreakSetParams: Codable {
    let sessionId: String?
    let file: String
    let line: Int
    var condition: String?
    var hitCondition: String?
}

struct RunUntilParams: Codable {
    let sessionId: String?
    let file: String
    let line: Int
    let wait: Double?
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

struct ExpandParams: Codable {
    let sessionId: String?
    let variablesReference: Int
}

struct ScopesParams: Codable {
    let sessionId: String?
    let threadId: Int?
    let frame: Int?
}

struct SetVarParams: Codable {
    let sessionId: String?
    let target: String
    let value: String
    let frame: Int?
}

struct StopParams: Codable {
    let sessionId: String?
    let mode: StopMode?
}

struct OutputParams: Codable {
    let sessionId: String?
    let clear: Bool?
}

struct StepParams: Codable {
    let sessionId: String?
    let granularity: StepGranularity
    let wait: Double?
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

struct BreakExceptionParams: Codable {
    let sessionId: String?
    let filters: [String]
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

struct ExpandResult: Codable {
    let children: [Local]
}

struct ScopesResult: Codable {
    let scopes: [Scope]
}

struct SetVarResult: Codable {
    let variable: Local
}

struct OutputResult: Codable {
    let output: [OutputChunk]
}

struct ThreadsResult: Codable {
    let threads: [Thread]
}

struct ExprResult: Codable {
    let value: String
    let type: String?
    let variablesReference: Int
}

struct BreakExceptionResult: Codable {
    let available: [ExceptionFilter]
    let enabled: [String]
}

struct BreakListResult: Codable {
    let breakpoints: [Breakpoint]
}

/// What `version` returns. Clients restart any daemon whose `build` differs
/// from their own `DaemonBuild.current`.
struct DaemonInfo: Codable {
    let version: String
    let build: String
}

enum DaemonBuild {
    /// Release builds are identified by version. Dev builds all say "dev", so
    /// the binary's mtime is appended — a rebuild then counts as a new build.
    /// Computed once; the daemon reads it at startup so a later rebuild of its
    /// binary on disk doesn't change what it reports.
    static let current: String = {
        guard llmdbVersion == "dev" else {
            return llmdbVersion
        }
        let mtime = Bundle.main.executablePath
            .flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }
            .map { String(Int($0.timeIntervalSince1970)) } ?? "unknown"
        return "dev+\(mtime)"
    }()
}

struct StopResult: Codable {
    let ok: Bool
    /// "detached" (target left running) or "terminated" (target killed).
    let action: String
}
