import ArgumentParser
import Foundation

struct ThreadsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "threads",
        abstract: "List threads in a stopped session"
    )

    @Option(name: .long, help: "Session ID")
    var session: String?

    func run() async throws {
        let result = try await DaemonClient.call(
            RPC.threads,
            SessionParams(sessionId: session)
        )
        try JSONOutput.print(result)
    }
}
