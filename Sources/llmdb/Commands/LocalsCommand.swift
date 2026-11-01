import ArgumentParser
import Foundation

struct LocalsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "locals",
        abstract: "Print typed locals for a stack frame"
    )

    @Option(name: .long, help: "Frame index (default: 0, the top frame)")
    var frame: Int = 0

    @Option(name: .long, help: "Thread ID (defaults to the stopped thread)")
    var thread: Int?

    @Option(name: .long, help: "Session ID")
    var session: String?

    func run() async throws {
        let result = try await DaemonClient.call(
            RPC.locals,
            LocalsParams(sessionId: session, threadId: thread, frame: frame)
        )
        try JSONOutput.print(result)
    }
}
