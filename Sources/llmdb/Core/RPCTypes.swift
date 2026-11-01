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

/// Server-side view of a request before its params are decoded. Lenient
/// like a JSON-RPC server should be: a missing or non-integer `id` reads as 0.
struct RPCRequestHeader: Decodable {
    let id: Int
    let method: String?

    private enum CodingKeys: String, CodingKey {
        case id, method
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? container.decode(Int.self, forKey: .id)) ?? 0
        self.method = try? container.decode(String.self, forKey: .method)
    }
}

/// Server-side: the params of a request, decoded as the method's own type.
/// nil when the request has no `params` (treated as `{}`).
struct RPCParamsEnvelope<P: Decodable>: Decodable {
    let params: P?
}

struct EmptyParams: Codable {}

// MARK: - Methods

/// A daemon method: its wire name plus the params it takes and the result it
/// returns. Binding the three together means a caller can't pair a method
/// with the wrong types, and each name is spelled exactly once.
struct RPCMethod<Params: Codable & Sendable, Result: Codable & Sendable>: Sendable {
    let name: String

    init(_ name: String) {
        self.name = name
    }
}

/// Every method `llmdbd` serves.
enum RPC {
    /// Clients restart a daemon whose build differs from theirs.
    static let version = RPCMethod<EmptyParams, DaemonInfo>("version")
    static let launch = RPCMethod<LaunchParams, SessionSnapshot>("launch")
    /// Exactly one of pid/app; `app` resolves a bundle ID in the booted iOS
    /// Simulator to a host PID via simctl.
    static let attach = RPCMethod<AttachParams, SessionSnapshot>("attach")
    static let sessions = RPCMethod<EmptyParams, [Session]>("sessions")
    static let breakSet = RPCMethod<BreakSetParams, BreakSetResult>("break.set")
    static let breakList = RPCMethod<SessionParams, BreakListResult>("break.list")
    static let breakDelete = RPCMethod<BreakDeleteParams, BreakListResult>("break.delete")
    static let breakException = RPCMethod<BreakExceptionParams, BreakExceptionResult>("break.exception")
    static let `continue` = RPCMethod<ExecParams, SessionSnapshot>("continue")
    static let runUntil = RPCMethod<RunUntilParams, BreakSetResult>("run-until")
    static let interrupt = RPCMethod<ExecParams, SessionSnapshot>("interrupt")
    static let step = RPCMethod<StepParams, SessionSnapshot>("step")
    static let wait = RPCMethod<WaitParams, SessionSnapshot>("wait")
    static let backtrace = RPCMethod<BtParams, BacktraceResult>("bt")
    static let locals = RPCMethod<LocalsParams, LocalsResult>("locals")
    static let expand = RPCMethod<ExpandParams, ExpandResult>("expand")
    static let scopes = RPCMethod<ScopesParams, ScopesResult>("scopes")
    static let output = RPCMethod<OutputParams, OutputResult>("output")
    static let setVar = RPCMethod<SetVarParams, SetVarResult>("set-var")
    static let threads = RPCMethod<SessionParams, ThreadsResult>("threads")
    static let expr = RPCMethod<ExprParams, ExprResult>("expr")
    static let stop = RPCMethod<StopParams, StopResult>("stop")
}

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

    /// What doing this to a live target is reported as.
    var action: StopAction {
        switch self {
        case .detach: .detached
        case .terminate: .terminated
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

/// What `stop` did to the target.
enum StopAction: String, Codable {
    /// Killed.
    case terminated
    /// Left running.
    case detached
    /// Had already ended; nothing to do.
    case exited
}

struct StopResult: Codable {
    let ok: Bool
    let action: StopAction
}
