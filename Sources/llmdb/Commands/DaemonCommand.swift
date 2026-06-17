import ArgumentParser
import Foundation

struct DaemonCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Run the llmdbd background process (normally auto-spawned)"
    )

    @Flag(name: .long, help: "Stay attached to stderr instead of detaching")
    var foreground = false

    @Option(name: .long, help: "Override the socket path (default: ~/Library/Caches/llmdb/llmdbd.sock)")
    var socket: String?

    func run() async throws {
        let daemon = Daemon(socketPath: socket ?? Daemon.defaultSocketPath)
        try daemon.start()
        await daemon.runForever()
    }
}
