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

    @Option(name: .long, help: "Output format")
    var format: OutputFormat = .default

    func run() async throws {
        let result = try await DaemonClient.call(
            method: "scopes",
            params: ScopesParams(sessionId: session, threadId: thread, frame: frame),
            as: ScopesResult.self
        )
        try JSONOutput.print(result)
    }
}
