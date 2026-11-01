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

    func run() async throws {
        let result = try await DaemonClient.call(
            RPC.expand,
            ExpandParams(sessionId: session, variablesReference: variablesReference)
        )
        try JSONOutput.print(result)
    }
}
