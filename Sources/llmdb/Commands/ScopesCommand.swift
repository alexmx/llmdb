import ArgumentParser
import Foundation

struct ScopesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scopes",
        abstract: "List a frame's variable scopes (Locals, Globals, Registers); expand a ref to read it"
    )

    @Option(name: .long, help: "Frame index (default: 0, the top frame)")
    var frame: Int = 0

    @Option(name: .long, help: "Thread ID (defaults to the stopped thread)")
    var thread: Int?

    @Option(name: .long, help: "Session ID")
    var session: String?

    func run() async throws {
        let result = try await DaemonClient.call(
            RPC.scopes,
            ScopesParams(sessionId: session, threadId: thread, frame: frame)
        )
        try JSONOutput.print(result)
    }
}
