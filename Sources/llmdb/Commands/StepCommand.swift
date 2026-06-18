import ArgumentParser
import Foundation

struct StepCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "step",
        abstract: "Step one source line; default --over"
    )

    @Flag(exclusivity: .exclusive)
    var granularity: StepGranularity = .over

    @Option(name: .long, help: "Wait seconds (default 30), or 'none' for fire-and-forget")
    var wait: WaitSpec?

    @Option(name: .long, help: "Session ID")
    var session: String?

    @Option(name: .long, help: "Output format")
    var format: OutputFormat = .default

    func run() async throws {
        let snap = try await DaemonClient.call(
            method: "step",
            params: StepParams(sessionId: session, granularity: granularity, wait: wait?.wireValue),
            as: SessionSnapshot.self
        )
        try JSONOutput.print(snap)
    }
}

extension StepGranularity {
    public static func help(for value: Self) -> ArgumentHelp? {
        switch value {
        case .over: "Step over a call (default)"
        case .in: "Step into a call"
        case .out: "Step out of the current frame"
        }
    }
}
