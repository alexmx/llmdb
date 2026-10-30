import ArgumentParser
import Foundation

struct StopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "End a session: terminates launched targets, detaches from attached ones",
        discussion: "Reports what happened in `action`: terminated, detached, or exited (target had already ended)."
    )

    @Flag(exclusivity: .exclusive)
    var mode: StopMode?

    @Option(name: .long, help: "Session ID (omit when only one is active)")
    var session: String?

    @Option(name: .long, help: "Output format")
    var format: OutputFormat = .default

    func run() async throws {
        let result = try await DaemonClient.call(
            method: "stop",
            params: StopParams(sessionId: session, mode: mode),
            as: StopResult.self
        )
        try JSONOutput.print(result)
    }
}
