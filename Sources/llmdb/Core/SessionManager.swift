import Foundation

/// Owns the set of live `Session`s inside `llmdbd`. Routes daemon JSON-RPC
/// requests to the right `DAPClient`.
///
/// TODO(M1): wire to DAPClient, generate session IDs, persist nothing across daemon restarts.
actor SessionManager {
    private var sessions: [String: Session] = [:]

    func list() -> [Session] { Array(sessions.values) }

    func get(_ id: String) throws -> Session {
        guard let s = sessions[id] else { throw LlmdbError.sessionNotFound(id) }
        return s
    }
}
