import AppKit
import Foundation

/// Routes `.app` bundle launches through LaunchServices (`NSWorkspace.openApplication`)
/// so the launched process is registered with WindowServer/AppKit — required by
/// accessibility / UI-automation tools that look at `NSWorkspace.runningApplications`
/// and expect a normal foreground app. lldb-dap's native launch path `exec`s the
/// binary directly, which leaves the process unregistered.
enum AppBundleLauncher {
    /// Returns the `.app` bundle URL if `path` points to one (or to a binary
    /// inside one), else nil.
    static func appBundleURL(for path: String) -> URL? {
        let absolute = (path as NSString).isAbsolutePath
            ? path
            : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(path)
        let url = URL(fileURLWithPath: absolute)
        let components = url.pathComponents
        guard let appIndex = components.firstIndex(where: { $0.hasSuffix(".app") }) else {
            return nil
        }
        let appPath = "/" + components[1...appIndex].joined(separator: "/")
        return URL(fileURLWithPath: appPath)
    }

    /// Open a `.app` via LaunchServices and return the host PID. Reuses an
    /// existing instance if the app is already running.
    static func openApplication(at url: URL, args: [String]) async throws -> Int32 {
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = args
        config.createsNewApplicationInstance = false
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
                if let error {
                    cont.resume(throwing: LlmdbError.dapFailure("LaunchServices openApplication failed: \(error.localizedDescription)"))
                } else if let app {
                    cont.resume(returning: app.processIdentifier)
                } else {
                    cont.resume(throwing: LlmdbError.dapFailure("openApplication returned neither app nor error"))
                }
            }
        }
    }
}
