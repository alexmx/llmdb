import Foundation

/// Why execution stopped — propagated from DAP `stopped` events.
struct StopReason: Codable {
    let reason: String // breakpoint, step, exception, pause, entry, ...
    let threadID: Int
    let description: String?
    let hitBreakpointIDs: [Int]?
}
