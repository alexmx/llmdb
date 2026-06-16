import Foundation

/// Resolves iOS Simulator bundle IDs to host PIDs via `xcrun simctl`.
///
/// TODO(M2): shell out to `xcrun simctl list devices booted -j` to find a booted
/// device, then `xcrun simctl spawn <id> launchctl list` (or similar) to map a
/// bundle ID to the host-side PID that `lldb-dap` can attach to directly.
enum SimulatorResolver {
    static func resolvePID(bundleID _: String) async throws -> Int32 {
        throw LlmdbError.notImplemented("SimulatorResolver")
    }
}
