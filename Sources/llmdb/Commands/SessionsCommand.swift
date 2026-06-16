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
        throw LlmdbError.notImplemented("sessions")
    }
}
