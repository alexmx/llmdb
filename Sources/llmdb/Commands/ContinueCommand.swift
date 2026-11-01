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

    func run() async throws {
        let snap = try await DaemonClient.call(
            RPC.continue,
            ExecParams(sessionId: session, wait: wait?.wireValue)
        )
        try JSONOutput.print(snap)
    }
}
