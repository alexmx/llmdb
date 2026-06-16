import ArgumentParser
import Foundation

struct StopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Detach or terminate a session"
    )

    @Option(name: .long, help: "Session ID (omit when only one is active)")
    var session: String?

    @Flag(name: .long, help: "Force-terminate instead of detaching")
    var terminate = false

    @Option(name: .long, help: "Output format")
    var format: OutputFormat = .default

    func run() async throws {
        throw LlmdbError.notImplemented("stop")
    }
}
