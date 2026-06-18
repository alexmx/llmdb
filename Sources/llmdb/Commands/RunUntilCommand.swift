import ArgumentParser
import Foundation

struct RunUntilCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run-until",
        abstract: "Set a breakpoint at <file>:<line> and continue; returns when it hits (or the target terminates)"
    )

    @Argument(help: "Location: `<file>:<line>`")
    var location: String

    @Option(name: .long, help: "Session ID")
    var session: String?

    @Option(name: .long, help: "Output format")
    var format: OutputFormat = .default

    func run() async throws {
        let (file, line) = try parseFileLineLocation(location)
        let result = try await DaemonClient.call(
            method: "run-until",
            params: BreakSetParams(sessionId: session, file: file, line: line),
            as: BreakSetResult.self
        )
        try JSONOutput.print(result)
    }
}
