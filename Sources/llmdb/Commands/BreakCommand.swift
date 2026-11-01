import ArgumentParser
import Foundation

struct BreakCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "break",
        abstract: "Manage breakpoints",
        subcommands: [SetSub.self, ListSub.self, DeleteSub.self, ExceptionSub.self]
    )

    struct SetSub: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Set a breakpoint by file:line"
        )

        @Argument(help: "Location: `<file>:<line>`")
        var location: String

        @Option(name: .long, help: "Session ID")
        var session: String?

        @Option(name: .long, help: "Fire only when this expression is true, e.g. `n > 100`")
        var condition: String?

        @Option(name: .long, help: "Fire on a hit-count match, e.g. `>5` or `3`")
        var hitCondition: String?

        func run() async throws {
            let (file, line) = try parseFileLineLocation(location)
            let result = try await DaemonClient.call(
                RPC.breakSet,
                BreakSetParams(
                    sessionId: session,
                    file: file,
                    line: line,
                    condition: condition,
                    hitCondition: hitCondition
                )
            )
            try JSONOutput.print(result)
        }
    }

    struct ListSub: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List breakpoints in a session"
        )

        @Option(name: .long, help: "Session ID")
        var session: String?

        func run() async throws {
            let result = try await DaemonClient.call(
                RPC.breakList,
                SessionParams(sessionId: session)
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

        func run() async throws {
            let result = try await DaemonClient.call(
                RPC.breakDelete,
                BreakDeleteParams(sessionId: session, id: id)
            )
            try JSONOutput.print(result)
        }
    }

    struct ExceptionSub: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "exception",
            abstract: "Stop on thrown exceptions; pass filter ids to enable, none to clear"
        )

        @Argument(help: "Filter ids to enable (e.g. swift_throw). Omit to clear and list what's available.")
        var filters: [String] = []

        @Option(name: .long, help: "Session ID")
        var session: String?

        func run() async throws {
            let result = try await DaemonClient.call(
                RPC.breakException,
                BreakExceptionParams(sessionId: session, filters: filters)
            )
            try JSONOutput.print(result)
        }
    }
}
