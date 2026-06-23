import Foundation

/// What every verb returns: enough context that the caller knows where the
/// session is without a follow-up call.
struct SessionSnapshot: Codable {
    let sessionId: String
    let state: Session.State
    let stopReason: StopReason?
    let topFrame: Frame?
}
