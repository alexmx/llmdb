import Foundation

/// What every M1 verb returns: enough context that the caller knows where the
/// session is without a follow-up call.
struct SessionSnapshot: Codable, Sendable {
    let sessionId: String
    let state: Session.State
    let stopReason: StopReason?
    let topFrame: Frame?
}
