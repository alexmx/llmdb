import ArgumentParser
import Foundation

struct LaunchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch",
        abstract: "Launch a binary under lldb-dap and return a session_id"
    )

    @Argument(help: "Path to the binary to debug")
    var binary: String

    @Argument(parsing: .captureForPassthrough, help: "Arguments forwarded to the binary")
    var arguments: [String] = []

    @Option(name: .long, help: "Output format")
    var format: OutputFormat = .default

    func run() async throws {
        let resolved = (binary as NSString).isAbsolutePath
            ? binary
            : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(binary)
        let snap = try await DaemonClient.call(
            method: "launch",
            params: LaunchParams(binary: resolved, args: arguments),
            as: SessionSnapshot.self
        )
        try JSONOutput.print(snap)
    }
}
