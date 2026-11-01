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

    @Option(
        name: .long,
        help: "Seconds lldb-dap may take per setup step before giving up and releasing the target (default 60)"
    )
    var timeout: Double?

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
            RPC.attach,
            AttachParams(pid: pid, app: app, timeout: timeout)
        )
        try JSONOutput.print(snap)
    }
}
