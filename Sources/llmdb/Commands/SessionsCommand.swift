import ArgumentParser
import Foundation

struct SessionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sessions",
        abstract: "List active debug sessions"
    )

    @Option(name: .long, help: "Output format")
    var format: OutputFormat = .default

    func run() async throws {
        let sessions = try await DaemonClient.call(
            method: "sessions",
            as: [Session].self
        )
        try JSONOutput.print(sessions)
    }
}
