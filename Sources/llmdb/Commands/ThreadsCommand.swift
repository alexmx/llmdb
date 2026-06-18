import ArgumentParser
import Foundation

struct ThreadsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "threads",
        abstract: "List threads in a stopped session"
    )

    @Option(name: .long, help: "Session ID")
    var session: String?

    @Option(name: .long, help: "Output format")
    var format: OutputFormat = .default

    func run() async throws {
        let result = try await DaemonClient.call(
            method: "threads",
            params: SessionParams(sessionId: session),
            as: ThreadsResult.self
        )
        try JSONOutput.print(result)
    }
}
