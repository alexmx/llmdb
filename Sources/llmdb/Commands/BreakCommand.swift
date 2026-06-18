import ArgumentParser
import Foundation

struct BreakCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "break",
        abstract: "Manage breakpoints",
        subcommands: [SetSub.self, ListSub.self, DeleteSub.self]
    )

    struct SetSub: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Set a breakpoint by file:line (M1) or symbol/regex (M2)"
        )

        @Argument(help: "Location: `<file>:<line>`")
        var location: String

        @Option(name: .long, help: "Session ID")
        var session: String?

        @Option(name: .long, help: "Output format")
        var format: OutputFormat = .default

        func run() async throws {
            let (file, line) = try parseLocation(location)
            let absolute = (file as NSString).isAbsolutePath
                ? file
                : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(file)
            let result = try await DaemonClient.call(
                method: "break.set",
                params: BreakSetParams(sessionId: session, file: absolute, line: line),
                as: BreakSetResult.self
            )
            try JSONOutput.print(result)
        }

        private func parseLocation(_ loc: String) throws -> (String, Int) {
            guard let colon = loc.lastIndex(of: ":"),
                  let line = Int(loc[loc.index(after: colon)...])
            else {
                throw LlmdbError.invalidArgument(
                    name: "location",
                    value: loc,
                    valid: ["<file>:<line>"]
                )
            }
            return (String(loc[..<colon]), line)
        }
    }

    struct ListSub: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List breakpoints in a session"
        )

        @Option(name: .long, help: "Session ID")
        var session: String?

        @Option(name: .long, help: "Output format")
        var format: OutputFormat = .default

        func run() async throws {
            let result = try await DaemonClient.call(
                method: "break.list",
                params: SessionParams(sessionId: session),
                as: BreakListResult.self
            )
            try JSONOutput.print(result)
        }
    }

    struct DeleteSub: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete a breakpoint by ID; returns the remaining breakpoints"
        )

        @Argument(help: "Breakpoint ID")
        var id: Int

        @Option(name: .long, help: "Session ID")
        var session: String?

        @Option(name: .long, help: "Output format")
        var format: OutputFormat = .default

        func run() async throws {
            let result = try await DaemonClient.call(
                method: "break.delete",
                params: BreakDeleteParams(sessionId: session, id: id),
                as: BreakListResult.self
            )
            try JSONOutput.print(result)
        }
    }
}
