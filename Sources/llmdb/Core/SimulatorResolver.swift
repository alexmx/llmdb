import Foundation

/// Resolves a bundle identifier of an app running in the booted iOS Simulator
/// to its host-side PID, so the existing attach-by-PID path can take it from
/// there.
///
/// Pipeline:
/// 1. `xcrun simctl list devices booted -j` → first booted device UDID
/// 2. `xcrun simctl get_app_container <UDID> <bundleID> app` → .app bundle path
/// 3. read `CFBundleExecutable` from the bundle's Info.plist → binary name
/// 4. `pgrep -f "<UDID>.*<binaryName>"` → host PID
enum SimulatorResolver {
    /// Resolve a bundle ID to a host PID. Throws clear, actionable errors
    /// when no sim is booted / the app isn't installed / the app isn't running.
    static func resolvePID(bundleID: String) async throws -> Int32 {
        let udid = try await bootedDeviceUDID()
        let appPath = try await appBundlePath(udid: udid, bundleID: bundleID)
        let binary = try readBundleExecutable(appBundlePath: appPath)
        return try await pgrepHostPID(udid: udid, binaryName: binary)
    }

    // MARK: - Pipeline steps (each independently testable)

    static func bootedDeviceUDID() async throws -> String {
        let json = try await runStdout(["/usr/bin/xcrun", "simctl", "list", "devices", "booted", "-j"])
        return try parseBootedUDID(json: json)
    }

    /// Pure: pull the first booted device's UDID from a `simctl list -j` blob.
    static func parseBootedUDID(json: Data) throws -> String {
        guard let obj = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let devices = obj["devices"] as? [String: Any]
        else {
            throw LlmdbError.daemonUnreachable("simctl list returned unexpected JSON shape")
        }
        for (_, value) in devices {
            guard let list = value as? [[String: Any]] else { continue }
            if let first = list.first(where: { ($0["state"] as? String) == "Booted" }),
               let udid = first["udid"] as? String {
                return udid
            }
        }
        throw LlmdbError.daemonUnreachable(
            "no booted iOS Simulator — boot one with `xcrun simctl boot <udid>` or via Xcode"
        )
    }

    static func appBundlePath(udid: String, bundleID: String) async throws -> String {
        do {
            let data = try await runStdout([
                "/usr/bin/xcrun", "simctl", "get_app_container", udid, bundleID, "app"
            ])
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if path.isEmpty {
                throw LlmdbError.daemonUnreachable("`\(bundleID)` not installed in simulator \(udid)")
            }
            return path
        } catch let LlmdbError.daemonUnreachable(msg) where msg.contains("exited") {
            throw LlmdbError.daemonUnreachable("`\(bundleID)` not installed in simulator \(udid)")
        }
    }

    /// Pure: read `CFBundleExecutable` from an .app bundle's Info.plist.
    static func readBundleExecutable(appBundlePath: String) throws -> String {
        let plistPath = "\(appBundlePath)/Info.plist"
        guard let data = FileManager.default.contents(atPath: plistPath) else {
            throw LlmdbError.daemonUnreachable("could not read \(plistPath)")
        }
        return try parseBundleExecutable(plist: data, path: plistPath)
    }

    /// Pure: extract `CFBundleExecutable` from raw plist bytes.
    static func parseBundleExecutable(plist: Data, path: String = "Info.plist") throws -> String {
        let obj = try PropertyListSerialization.propertyList(from: plist, format: nil)
        guard let dict = obj as? [String: Any], let exe = dict["CFBundleExecutable"] as? String else {
            throw LlmdbError.daemonUnreachable("CFBundleExecutable not found in \(path)")
        }
        return exe
    }

    /// Find the host PID for a process whose command line contains both the
    /// simulator UDID (Simulator app paths embed it) and the app binary name.
    static func pgrepHostPID(udid: String, binaryName: String) async throws -> Int32 {
        do {
            let data = try await runStdout(["/usr/bin/pgrep", "-f", "\(udid).*\(binaryName)"])
            let str = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            for line in str.split(separator: "\n") {
                if let pid = Int32(line) { return pid }
            }
            throw LlmdbError.daemonUnreachable("`\(binaryName)` not running in simulator \(udid)")
        } catch let LlmdbError.daemonUnreachable(msg) where msg.contains("exited 1") {
            // pgrep exits 1 when no match.
            throw LlmdbError.daemonUnreachable("`\(binaryName)` not running in simulator \(udid)")
        }
    }

    // MARK: - Subprocess helper

    /// Run a command and return its stdout. Throws on non-zero exit.
    /// Detached so the blocking `Process` doesn't park an actor's executor.
    ///
    /// Note: `standardError` is wired to a `Pipe()` but never drained. If a
    /// callee ever started writing more than ~64 KiB to stderr it could block
    /// on the full pipe. All current callees (`xcrun simctl`, `pgrep`) are
    /// nearly silent on stderr, so we don't pay the cost of a second read loop.
    /// If we add a chattier callee, drain stderr alongside stdout.
    private static func runStdout(_ command: [String]) async throws -> Data {
        try await Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: command[0])
            proc.arguments = Array(command.dropFirst())
            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = Pipe()
            do {
                try proc.run()
            } catch {
                throw LlmdbError.daemonUnreachable("\(command[0]) failed to spawn: \(error)")
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                throw LlmdbError.daemonUnreachable("\(command[0]) exited \(proc.terminationStatus)")
            }
            return data
        }.value
    }
}
