import ArgumentParser
import Foundation

struct InterruptCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "interrupt",
        abstract: "Pause a running session; returns once stopped (default 10s) or with --wait none for fire-and-forget"
    )

    @Option(name: .long, help: "Wait seconds (default 10), or 'none' for fire-and-forget")
    var wait: WaitSpec?

    @Option(name: .long, help: "Session ID (omit when only one is active)")
    var session: String?

    func run() async throws {
        let snap = try await DaemonClient.call(
            RPC.interrupt,
            ExecParams(sessionId: session, wait: wait?.wireValue)
        )
        try JSONOutput.print(snap)
    }
}
