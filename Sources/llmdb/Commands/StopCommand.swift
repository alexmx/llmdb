import ArgumentParser
import Foundation

struct StopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Detach or terminate a session"
    )

    @Option(name: .long, help: "Session ID (omit when only one is active)")
    var session: String?

    @Option(name: .long, help: "Output format")
    var format: OutputFormat = .default

    func run() async throws {
        let result = try await DaemonClient.call(
            method: "stop",
            params: SessionParams(sessionId: session),
            as: StopResult.self
        )
        try JSONOutput.print(result)
    }
}
