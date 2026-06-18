import ArgumentParser
import Foundation

struct InterruptCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "interrupt",
        abstract: "Pause a running session; returns once stopped"
    )

    @Option(name: .long, help: "Session ID (omit when only one is active)")
    var session: String?

    @Option(name: .long, help: "Output format")
    var format: OutputFormat = .default

    func run() async throws {
        let snap = try await DaemonClient.call(
            method: "interrupt",
            params: SessionParams(sessionId: session),
            as: SessionSnapshot.self
        )
        try JSONOutput.print(snap)
    }
}
