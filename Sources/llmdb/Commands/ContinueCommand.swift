import ArgumentParser
import Foundation

struct ContinueCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "continue",
        abstract: "Continue execution; returns when the target stops again (default 60s) or with --wait none for fire-and-forget"
    )

    @Option(name: .long, help: "Wait seconds (default 60), or 'none' for fire-and-forget")
    var wait: WaitSpec?

    @Option(name: .long, help: "Session ID")
    var session: String?

    @Option(name: .long, help: "Output format")
    var format: OutputFormat = .default

    func run() async throws {
        let snap = try await DaemonClient.call(
            method: "continue",
            params: ExecParams(sessionId: session, wait: wait?.wireValue),
            as: SessionSnapshot.self
        )
        try JSONOutput.print(snap)
    }
}
