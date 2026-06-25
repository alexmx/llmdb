import ArgumentParser
import Foundation

struct OutputCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "output",
        abstract: "Print the target's captured stdout/stderr/console output"
    )

    @Flag(name: .long, help: "Drain the buffer so the next call returns only newer output")
    var clear = false

    @Option(name: .long, help: "Session ID")
    var session: String?

    @Option(name: .long, help: "Output format")
    var format: OutputFormat = .default

    func run() async throws {
        let result = try await DaemonClient.call(
            method: "output",
            params: OutputParams(sessionId: session, clear: clear),
            as: OutputResult.self
        )
        try JSONOutput.print(result)
    }
}
