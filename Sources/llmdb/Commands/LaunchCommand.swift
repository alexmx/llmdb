import ArgumentParser
import Foundation

struct LaunchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch",
        abstract: "Launch a binary (or .app bundle) under lldb-dap; returns a sessionId. .app bundles route via LaunchServices so AppKit/AX-driven tools see the process."
    )

    @Argument(help: "Path to the binary to debug")
    var binary: String

    @Argument(parsing: .captureForPassthrough, help: "Arguments forwarded to the binary")
    var arguments: [String] = []

    @Option(
        name: .long,
        help: "Seconds lldb-dap may take per setup step before giving up and releasing the target (default 60)"
    )
    var timeout: Double?

    func run() async throws {
        let snap = try await DaemonClient.call(
            RPC.launch,
            LaunchParams(binary: absolutePath(binary), args: arguments, timeout: timeout)
        )
        try JSONOutput.print(snap)
    }
}
