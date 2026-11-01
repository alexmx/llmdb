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

    func run() async throws {
        let result = try await DaemonClient.call(
            RPC.stop,
            StopParams(sessionId: session, mode: mode)
        )
        try JSONOutput.print(result)
    }
}
