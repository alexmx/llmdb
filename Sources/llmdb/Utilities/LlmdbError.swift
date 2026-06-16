import Foundation

enum LlmdbError: Error, CustomStringConvertible {
    case notImplemented(String)
    case daemonUnreachable(String)
    case sessionNotFound(String)
    case invalidArgument(name: String, value: String, valid: [String])
    case dapFailure(String)

    var description: String {
        switch self {
        case .notImplemented(let what):
            "not implemented yet: \(what)"
        case .daemonUnreachable(let reason):
            "llmdbd unreachable: \(reason)"
        case .sessionNotFound(let id):
            "no session with id \(id)"
        case .invalidArgument(let name, let value, let valid):
            "invalid value for --\(name): \(value). valid: \(valid.joined(separator: ", "))"
        case .dapFailure(let message):
            "lldb-dap error: \(message)"
        }
    }
}
