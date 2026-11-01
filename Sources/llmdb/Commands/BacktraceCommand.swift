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

    func run() async throws {
        let result = try await DaemonClient.call(
            RPC.backtrace,
            BtParams(sessionId: session, threadId: thread, depth: depth)
        )
        try JSONOutput.print(result)
    }
}
