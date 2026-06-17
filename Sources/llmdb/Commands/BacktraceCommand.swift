import ArgumentParser
import Foundation

struct BacktraceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bt",
        abstract: "Print a structured backtrace for the current stopped thread"
    )

    @Option(name: .long, help: "Thread ID (defaults to the stopped thread)")
    var thread: Int?

    @Option(name: .long, help: "Maximum depth (default: full stack)")
    var depth: Int?

    @Option(name: .long, help: "Session ID")
    var session: String?

    @Option(name: .long, help: "Output format")
    var format: OutputFormat = .default

    func run() async throws {
        let result = try await DaemonClient.call(
            method: "bt",
            params: BtParams(sessionId: session, threadId: thread, depth: depth),
            as: BacktraceResult.self
        )
        try JSONOutput.print(result)
    }
}
