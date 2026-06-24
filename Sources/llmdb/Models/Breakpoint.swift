import Foundation

struct Breakpoint: Codable {
    let id: Int
    let verified: Bool
    let line: Int?
    let source: String?
    let message: String?
    /// The condition that must hold for the breakpoint to fire, if any.
    var condition: String?
    /// The lldb hit-count expression gating the breakpoint, if any.
    var hitCondition: String?
}
