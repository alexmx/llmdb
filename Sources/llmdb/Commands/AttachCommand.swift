import ArgumentParser
import Foundation

struct AttachCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attach",
        abstract: "Attach to a running process or Simulator app"
    )

    @Option(name: .long, help: "Process ID to attach to")
    var pid: Int32?

    @Option(name: .long, help: "App bundle identifier (iOS Simulator)")
    var app: String?

    @Option(name: .long, help: "Output format")
    var format: OutputFormat = .default

    func run() async throws {
        // TODO(M1/M2): resolve via SimulatorResolver if --app set; else attach by PID.
        throw LlmdbError.notImplemented("attach")
    }
}
