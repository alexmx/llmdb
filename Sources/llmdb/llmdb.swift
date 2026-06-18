import ArgumentParser

@main
struct Llmdb: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "llmdb",
        abstract: "Debug macOS and iOS Simulator apps from the terminal or an AI agent.",
        subcommands: [
            // Lifecycle
            LaunchCommand.self,
            AttachCommand.self,
            StopCommand.self,
            SessionsCommand.self,
            // Breakpoints
            BreakCommand.self,
            // Execution
            ContinueCommand.self,
            RunUntilCommand.self,
            StepCommand.self,
            InterruptCommand.self,
            // Inspection
            BacktraceCommand.self,
            LocalsCommand.self,
            ThreadsCommand.self,
            ExprCommand.self,
            // System
            DaemonCommand.self,
            DoctorCommand.self,
            MCPServerCommand.self
        ]
    )

    @Flag(name: .shortAndLong, help: "Show version")
    var version = false

    mutating func run() throws {
        if version {
            print(llmdbVersion)
        } else {
            throw CleanExit.helpRequest(self)
        }
    }
}
