import ArgumentParser
import Foundation

struct StepCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "step",
        abstract: "Step one source line; default --over"
    )

    /// `EnumerableFlag` exposes one CLI flag per case (`--over`, `--in`, `--out`)
    /// and enforces mutual exclusivity for free. Per-flag help text lives in
    /// the extension below so the conformance stays close to the CLI usage.
    @Flag(exclusivity: .exclusive)
    var granularity: StepGranularity = .over

    @Option(name: .long, help: "Session ID")
    var session: String?

    @Option(name: .long, help: "Output format")
    var format: OutputFormat = .default

    func run() async throws {
        let snap = try await DaemonClient.call(
            method: "step",
            params: StepParams(sessionId: session, granularity: granularity),
            as: SessionSnapshot.self
        )
        try JSONOutput.print(snap)
    }
}

extension StepGranularity {
    /// Per-flag descriptions shown in `llmdb step --help`.
    public static func help(for value: Self) -> ArgumentHelp? {
        switch value {
        case .over: "Step over a call (default)"
        case .in:   "Step into a call"
        case .out:  "Step out of the current frame"
        }
    }
}
