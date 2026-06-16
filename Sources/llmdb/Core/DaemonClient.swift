import Foundation

/// CLI-side client that talks to `llmdbd` over a Unix socket.
/// Auto-spawns the daemon on first use when the socket is absent.
///
/// TODO(M1): implement Unix socket connect, JSON-RPC framing, daemon auto-spawn
/// (`Process` launching `llmdb daemon` detached).
struct DaemonClient {
    static var socketPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Caches/llmdb/llmdbd.sock").path
    }

    static func send(_ method: String, _ params: [String: Any] = [:]) async throws -> Data {
        throw LlmdbError.daemonUnreachable("DaemonClient not yet implemented (method=\(method))")
    }
}
