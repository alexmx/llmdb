import ArgumentParser
import Foundation

struct DaemonCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Run the llmdbd background process (normally auto-spawned)"
    )

    @Flag(name: .long, help: "Stay attached to stderr instead of detaching")
    var foreground = false

    func run() async throws {
        // TODO(M1): bind the Unix socket at ~/Library/Caches/llmdb/llmdbd.sock,
        // accept JSON-RPC requests, route to SessionManager.
        throw LlmdbError.notImplemented("daemon")
    }
}
