import ArgumentParser
import Foundation

struct ExpandCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "expand",
        abstract: "Expand a structured value into its children by variablesReference"
    )

    @Argument(help: "variablesReference from a locals/expand entry (must be non-zero)")
    var variablesReference: Int

    @Option(name: .long, help: "Session ID")
    var session: String?

    @Option(name: .long, help: "Output format")
    var format: OutputFormat = .default

    func run() async throws {
        let result = try await DaemonClient.call(
            method: "expand",
            params: ExpandParams(sessionId: session, variablesReference: variablesReference),
            as: ExpandResult.self
        )
        try JSONOutput.print(result)
    }
}
