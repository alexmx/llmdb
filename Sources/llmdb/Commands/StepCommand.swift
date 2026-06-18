import ArgumentParser
import Foundation

struct StepCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "step",
        abstract: "Step one source line; default --over"
    )

    @Flag(name: .long, help: "Step into a call")
    var `in` = false

    @Flag(name: .long, help: "Step over a call (default)")
    var over = false

    @Flag(name: .long, help: "Step out of the current frame")
    var out = false

    @Option(name: .long, help: "Session ID")
    var session: String?

    @Option(name: .long, help: "Output format")
    var format: OutputFormat = .default

    func validate() throws {
        let count = [`in`, over, out].filter { $0 }.count
        if count > 1 {
            throw ValidationError("pass at most one of --in / --over / --out")
        }
    }

    func run() async throws {
        let granularity: StepGranularity
        if `in` {
            granularity = .in
        } else if out {
            granularity = .out
        } else {
            granularity = .over  // default
        }
        let snap = try await DaemonClient.call(
            method: "step",
            params: StepParams(sessionId: session, granularity: granularity),
            as: SessionSnapshot.self
        )
        try JSONOutput.print(snap)
    }
}
