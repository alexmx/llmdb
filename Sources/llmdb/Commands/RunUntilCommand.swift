import ArgumentParser
import Foundation

struct RunUntilCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run-until",
        abstract: "Set a breakpoint at <file>:<line> and continue; returns when it hits (or the target terminates)"
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
            method: "run-until",
            params: RunUntilParams(sessionId: session, file: absolute, line: line),
            as: RunUntilResult.self
        )
        try JSONOutput.print(result)
    }

    private func parseLocation(_ loc: String) throws -> (String, Int) {
        guard let colon = loc.lastIndex(of: ":"),
              let line = Int(loc[loc.index(after: colon)...])
        else {
            throw LlmdbError.invalidArgument(name: "location", value: loc, valid: ["<file>:<line>"])
        }
        return (String(loc[..<colon]), line)
    }
}
