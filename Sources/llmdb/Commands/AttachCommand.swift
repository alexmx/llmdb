import ArgumentParser
import Foundation

struct AttachCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attach",
        abstract: "Attach to a running process by PID, or to an app in the booted iOS Simulator by bundle ID"
    )

    @Option(name: .long, help: "Process ID to attach to")
    var pid: Int32?

    @Option(name: .long, help: "Bundle ID of an app running in the booted iOS Simulator (resolved via xcrun simctl)")
    var app: String?

    @Option(name: .long, help: "Output format")
    var format: OutputFormat = .default

    func validate() throws {
        switch (pid, app) {
        case (nil, nil):
            throw ValidationError("pass --pid <N> or --app <bundle-id>")
        case (.some, .some):
            throw ValidationError("pass --pid or --app, not both")
        default:
            break
        }
    }

    func run() async throws {
        let snap = try await DaemonClient.call(
            method: "attach",
            params: AttachParams(pid: pid, app: app),
            as: SessionSnapshot.self
        )
        try JSONOutput.print(snap)
    }
}
