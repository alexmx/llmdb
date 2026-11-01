import ArgumentParser
import Foundation

struct SessionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sessions",
        abstract: "List active debug sessions"
    )

    func run() async throws {
        let sessions = try await DaemonClient.call(RPC.sessions)
        try JSONOutput.print(sessions)
    }
}
