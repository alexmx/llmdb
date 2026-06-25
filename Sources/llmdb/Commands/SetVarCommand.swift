import ArgumentParser
import Foundation

struct SetVarCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-var",
        abstract: "Assign a new value to a variable during a stop"
    )

    @Argument(help: "Assignable target: a local name, or an expression like `self.count` or `arr[0]`")
    var target: String

    @Argument(help: "New value, in the target's language (e.g. 42, true, \"hi\")")
    var value: String

    @Option(name: .long, help: "Frame index (default: 0, the top frame)")
    var frame: Int = 0

    @Option(name: .long, help: "Session ID")
    var session: String?

    @Option(name: .long, help: "Output format")
    var format: OutputFormat = .default

    func run() async throws {
        let result = try await DaemonClient.call(
            method: "set-var",
            params: SetVarParams(sessionId: session, target: target, value: value, frame: frame),
            as: SetVarResult.self
        )
        try JSONOutput.print(result)
    }
}
