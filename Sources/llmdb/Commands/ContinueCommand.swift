import ArgumentParser
import Foundation

struct ContinueCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "continue",
        abstract: "Continue execution; returns when the target stops again"
    )

    @Option(name: .long, help: "Session ID")
    var session: String?

    @Option(name: .long, help: "Output format")
    var format: OutputFormat = .default

    func run() async throws {
        let snap = try await DaemonClient.call(
            method: "continue",
            params: SessionParams(sessionId: session),
            as: SessionSnapshot.self
        )
        try JSONOutput.print(snap)
    }
}
