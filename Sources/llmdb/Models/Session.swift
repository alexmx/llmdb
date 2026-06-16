import Foundation

/// A live debug session owned by `llmdbd`.
struct Session: Codable, Sendable {
    let id: String
    let target: Target
    var state: State
    var stopReason: StopReason?

    enum Target: Codable, Sendable {
        case launched(binary: String, args: [String])
        case attached(pid: Int32)
        case simulator(bundleID: String, deviceID: String, pid: Int32?)
    }

    enum State: String, Codable, Sendable {
        case initializing
        case running
        case stopped
        case terminated
    }
}
