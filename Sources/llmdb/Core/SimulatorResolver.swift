import Foundation
import Subprocess

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
        let result = try await run("/usr/bin/xcrun", ["simctl", "list", "devices", "booted", "-j"])
        guard result.status.isSuccess else {
            throw failure("xcrun simctl list", result.status)
        }
        return try parseBootedUDID(json: Data(result.stdout.utf8))
    }

    /// `simctl list devices -j`: runtime identifier → devices.
    private struct DeviceList: Decodable {
        struct Device: Decodable {
            let udid: String
            let state: String
        }

        let devices: [String: [Device]]
    }

    /// Pure: pull the first booted device's UDID from a `simctl list -j` blob.
    static func parseBootedUDID(json: Data) throws -> String {
        guard let list = try? JSONDecoder().decode(DeviceList.self, from: json) else {
            throw LlmdbError.simulator("simctl list returned unexpected JSON shape")
        }
        for devices in list.devices.values {
            if let booted = devices.first(where: { $0.state == "Booted" }) {
                return booted.udid
            }
        }
        throw LlmdbError.simulator(
            "no booted iOS Simulator — boot one with `xcrun simctl boot <udid>` or via Xcode"
        )
    }

    static func appBundlePath(udid: String, bundleID: String) async throws -> String {
        let result = try await run("/usr/bin/xcrun", ["simctl", "get_app_container", udid, bundleID, "app"])
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // simctl exits non-zero when the app isn't installed.
        guard result.status.isSuccess, !path.isEmpty else {
            throw LlmdbError.simulator("`\(bundleID)` not installed in simulator \(udid)")
        }
        return path
    }

    /// Pure: read `CFBundleExecutable` from an .app bundle's Info.plist.
    static func readBundleExecutable(appBundlePath: String) throws -> String {
        let plistPath = "\(appBundlePath)/Info.plist"
        guard let data = FileManager.default.contents(atPath: plistPath) else {
            throw LlmdbError.simulator("could not read \(plistPath)")
        }
        return try parseBundleExecutable(plist: data, path: plistPath)
    }

    /// Pure: extract `CFBundleExecutable` from raw plist bytes.
    static func parseBundleExecutable(plist: Data, path: String = "Info.plist") throws -> String {
        let obj = try PropertyListSerialization.propertyList(from: plist, format: nil)
        guard let dict = obj as? [String: Any], let exe = dict["CFBundleExecutable"] as? String else {
            throw LlmdbError.simulator("CFBundleExecutable not found in \(path)")
        }
        return exe
    }

    /// Find the host PID for a process whose command line contains both the
    /// simulator UDID (Simulator app paths embed it) and the app binary name.
    static func pgrepHostPID(udid: String, binaryName: String) async throws -> Int32 {
        let result = try await run("/usr/bin/pgrep", ["-f", "\(udid).*\(binaryName)"])
        switch result.status {
        case .exited(0):
            if let pid = result.stdout.split(separator: "\n").lazy.compactMap({ Int32($0) }).first {
                return pid
            }
        case .exited(1):
            break // pgrep: no match
        default:
            throw failure("pgrep", result.status)
        }
        throw LlmdbError.simulator("`\(binaryName)` not running in simulator \(udid)")
    }

    // MARK: - Subprocess helpers

    private static func run(_ executable: String, _ arguments: [String]) async throws -> ProcessRunner.Output {
        do {
            return try await ProcessRunner.run(executable, arguments)
        } catch {
            throw LlmdbError.simulator("\(executable) failed to spawn: \(error)")
        }
    }

    private static func failure(_ command: String, _ status: TerminationStatus) -> LlmdbError {
        switch status {
        case .exited(let code):
            .simulator("\(command) exited \(code)")
        case .signaled(let signal):
            .simulator("\(command) killed by signal \(signal)")
        }
    }
}
