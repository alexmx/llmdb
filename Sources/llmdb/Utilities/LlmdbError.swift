import Foundation

enum LlmdbError: Error, CustomStringConvertible {
    case daemonUnreachable(String)
    /// The daemon answered, but not in the shape this CLI expects.
    case daemonMismatch(String)
    /// Error message returned by the daemon — passed through verbatim so we
    /// don't double-prefix on the client side.
    case remote(String)
    case sessionNotFound(String)
    /// An inspection verb needs a stopped session.
    case notStopped(Session.State)
    /// iOS Simulator lookup failed (none booted, app not installed / running).
    case simulator(String)
    case invalidArgument(name: String, value: String, valid: [String])
    case dapFailure(String)

    var description: String {
        switch self {
        case .daemonUnreachable(let reason):
            "llmdbd unreachable: \(reason)"
        case .daemonMismatch(let reason):
            reason
        case .remote(let message):
            message
        case .sessionNotFound(let id):
            "no session with id \(id)"
        case .notStopped(.terminated):
            "session has exited; nothing to inspect"
        case .notStopped(let state):
            "session is \(state.rawValue); interrupt it or wait for a stop first"
        case .simulator(let message):
            message
        case .invalidArgument(let name, let value, let valid):
            "invalid value for --\(name): \(value). valid: \(valid.joined(separator: ", "))"
        case .dapFailure(let message):
            "lldb-dap error: \(message)"
        }
    }
}
