import ArgumentParser
import Foundation

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Verify lldb-dap is available and the socket directory is writable"
    )

    @Option(name: .long, help: "Output format")
    var format: OutputFormat = .default

    func run() async throws {
        // TODO(M1): check `xcrun --find lldb-dap`, check socket dir, report status.
        throw LlmdbError.notImplemented("doctor")
    }
}
