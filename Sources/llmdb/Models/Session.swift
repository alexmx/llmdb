import Foundation

/// A live debug session owned by `llmdbd`.
struct Session: Codable {
    let id: String
    let target: Target
    var state: State
    var stopReason: StopReason?

    enum Target: Codable {
        case launched(binary: String, args: [String])
        case attached(pid: Int32)
        case simulator(bundleID: String, deviceID: String, pid: Int32?)
    }

    enum State: String, Codable {
        case initializing
        case running
        case stopped
        case terminated
    }
}
