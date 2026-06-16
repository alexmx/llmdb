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
            abstract: "Set a breakpoint by file:line, symbol, or regex"
        )

        @Argument(help: "Location: `<file>:<line>` (omit for --symbol or --regex)")
        var location: String?

        @Option(name: .long, help: "Set a symbol breakpoint")
        var symbol: String?

        @Option(name: .long, help: "Set a regex breakpoint")
        var regex: String?

        @Option(name: .long, help: "Session ID")
        var session: String?

        @Option(name: .long, help: "Output format")
        var format: OutputFormat = .default

        func run() async throws {
            throw LlmdbError.notImplemented("break set")
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
            throw LlmdbError.notImplemented("break list")
        }
    }

    struct DeleteSub: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete a breakpoint by ID"
        )

        @Argument(help: "Breakpoint ID")
        var id: Int

        @Option(name: .long, help: "Session ID")
        var session: String?

        func run() async throws {
            throw LlmdbError.notImplemented("break delete")
        }
    }
}
