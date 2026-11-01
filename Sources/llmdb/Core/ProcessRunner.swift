import Subprocess
import System

/// Runs a short-lived command to completion and collects its stdout. stderr
/// is drained and discarded, so a chatty command can't block on a full pipe.
/// Long-lived children (lldb-dap, the daemon) use `Process` instead: their
/// lifetime isn't scoped to one call.
enum ProcessRunner {
    struct Output {
        let status: TerminationStatus
        let stdout: String
    }

    /// Generous: the largest output we read is `simctl list -j`.
    private static let outputLimit = 16 * 1024 * 1024

    /// Throws if `executable` can't be launched or its output exceeds the
    /// limit; a non-zero exit is reported in `status`, not thrown.
    static func run(_ executable: String, _ arguments: [String]) async throws -> Output {
        let result = try await Subprocess.run(
            .path(FilePath(executable)),
            arguments: Arguments(arguments),
            output: .string(limit: outputLimit),
            error: .discarded
        )
        return Output(status: result.terminationStatus, stdout: result.standardOutput)
    }
}
