import Foundation

/// Parse a `<file>:<line>` argument. The file is kept as typed: lldb matches
/// a relative path or bare file name by suffix against the debug info, so
/// resolving it against the cwd would only break it (`main.swift` from the
/// repo root would become a `/repo/main.swift` that doesn't exist).
func parseFileLineLocation(_ location: String) throws -> (file: String, line: Int) {
    guard let colon = location.lastIndex(of: ":"),
          let line = Int(location[location.index(after: colon)...])
    else {
        throw LlmdbError.invalidArgument(
            name: "location",
            value: location,
            valid: ["<file>:<line>"]
        )
    }
    return (String(location[..<colon]), line)
}

/// `path` resolved against this process's working directory. Use for paths
/// the daemon opens (e.g. the binary to launch): the daemon runs in whatever
/// directory first spawned it, not the caller's.
func absolutePath(_ path: String) -> String {
    (path as NSString).isAbsolutePath
        ? path
        : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(path)
}
