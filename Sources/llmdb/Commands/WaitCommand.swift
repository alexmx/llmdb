import ArgumentParser
import Foundation

struct WaitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait",
        abstract: "Block until the session leaves `running` (stops or terminates). Pairs with `continue --wait none`."
    )

    @Option(name: .long, help: "Timeout in seconds (default 60)")
    var timeout: Double?

    @Option(name: .long, help: "Session ID")
    var session: String?

    @Option(name: .long, help: "Output format")
    var format: OutputFormat = .default

    func run() async throws {
        let snap = try await DaemonClient.call(
            method: "wait",
            params: WaitParams(sessionId: session, timeout: timeout),
            as: SessionSnapshot.self
        )
        try JSONOutput.print(snap)
    }
}
