import Foundation

/// Parse a `<file>:<line>` argument into an absolute file path + line number.
/// Relative paths are resolved against the current working directory so the
/// daemon (in a different cwd) gets a path it can open.
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
    let file = String(location[..<colon])
    let absolute = (file as NSString).isAbsolutePath
        ? file
        : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(file)
    return (absolute, line)
}
