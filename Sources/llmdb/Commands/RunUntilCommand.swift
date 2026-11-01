import ArgumentParser
import Foundation

struct RunUntilCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run-until",
        abstract: "Set a breakpoint at <file>:<line> and continue; returns when it hits (or the target terminates)"
    )

    @Argument(help: "Location: `<file>:<line>`")
    var location: String

    @Option(name: .long, help: "Wait seconds (default 60), or 'none' for fire-and-forget")
    var wait: WaitSpec?

    @Option(name: .long, help: "Session ID")
    var session: String?

    func run() async throws {
        let (file, line) = try parseFileLineLocation(location)
        let result = try await DaemonClient.call(
            RPC.runUntil,
            RunUntilParams(sessionId: session, file: file, line: line, wait: wait?.wireValue)
        )
        try JSONOutput.print(result)
    }
}
