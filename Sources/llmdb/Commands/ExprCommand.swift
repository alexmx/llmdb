import ArgumentParser
import Foundation

struct ExprCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "expr",
        abstract: "Evaluate an expression in the current frame"
    )

    @Argument(help: "Expression to evaluate (e.g. `self.state.count` or `a + b`)")
    var expression: String

    @Option(name: .long, help: "Frame index (default: 0, the top frame)")
    var frame: Int = 0

    @Option(name: .long, help: "Session ID")
    var session: String?

    @Option(name: .long, help: "Output format")
    var format: OutputFormat = .default

    func run() async throws {
        let result = try await DaemonClient.call(
            method: "expr",
            params: ExprParams(sessionId: session, expression: expression, frame: frame),
            as: ExprResult.self
        )
        try JSONOutput.print(result)
    }
}
