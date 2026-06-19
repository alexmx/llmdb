import Foundation
@testable import llmdb
import Testing

@Suite("AppBundleLauncher")
struct AppBundleLauncherTests {
    @Test
    func detectsDirectAppBundle() {
        let url = AppBundleLauncher.appBundleURL(for: "/Applications/MyApp.app")
        #expect(url?.path == "/Applications/MyApp.app")
    }

    @Test
    func detectsBinaryInsideAppBundle() {
        let url = AppBundleLauncher.appBundleURL(for: "/Applications/MyApp.app/Contents/MacOS/MyApp")
        #expect(url?.path == "/Applications/MyApp.app")
    }

    @Test
    func ignoresPlainBinary() {
        let url = AppBundleLauncher.appBundleURL(for: "/usr/local/bin/llmdb")
        #expect(url == nil)
    }

    @Test
    func picksOuterAppForNestedBundles() {
        // Some apps embed helper .app bundles inside Resources; the outer one
        // is what LaunchServices manages.
        let url = AppBundleLauncher.appBundleURL(
            for: "/Applications/Outer.app/Contents/Resources/Helper.app/Contents/MacOS/Helper"
        )
        #expect(url?.path == "/Applications/Outer.app")
    }
}

@Suite("SimulatorResolver")
struct SimulatorResolverTests {
    // MARK: - parseBootedUDID

    @Test
    func picksBootedDevice() throws {
        let json = #"""
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-17-0": [
              { "udid": "OLD-OFF", "state": "Shutdown", "name": "iPhone 14" },
              { "udid": "ACTIVE-1", "state": "Booted",   "name": "iPhone 15" }
            ]
          }
        }
        """#.data(using: .utf8)!
        let udid = try SimulatorResolver.parseBootedUDID(json: json)
        #expect(udid == "ACTIVE-1")
    }

    @Test
    func throwsWhenNoneBooted() {
        let json = #"""
        { "devices": { "com.apple.CoreSimulator.SimRuntime.iOS-17-0": [] } }
        """#.data(using: .utf8)!
        #expect(throws: LlmdbError.self) {
            try SimulatorResolver.parseBootedUDID(json: json)
        }
    }

    @Test
    func throwsOnShapeMismatch() {
        let json = #"{ "wrong": true }"#.data(using: .utf8)!
        #expect(throws: LlmdbError.self) {
            try SimulatorResolver.parseBootedUDID(json: json)
        }
    }

    // MARK: - parseBundleExecutable

    @Test
    func readsCFBundleExecutable() throws {
        let plist: [String: Any] = [
            "CFBundleExecutable": "MyApp",
            "CFBundleIdentifier": "com.example.MyApp"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .binary, options: 0
        )
        let exe = try SimulatorResolver.parseBundleExecutable(plist: data)
        #expect(exe == "MyApp")
    }

    @Test
    func throwsOnMissingKey() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "x"], format: .binary, options: 0
        )
        #expect(throws: LlmdbError.self) {
            try SimulatorResolver.parseBundleExecutable(plist: data)
        }
    }

    // MARK: - Integration (skips when no sim is booted)

    @Test
    func bootedDeviceUDIDOrSkip() async throws {
        do {
            let udid = try await SimulatorResolver.bootedDeviceUDID()
            #expect(!udid.isEmpty)
            // Loose shape: ABCDEF12-3456-... UUIDs are 36 chars with dashes,
            // but don't be too strict — Simulator UDIDs are real UUIDs.
            #expect(udid.contains("-"))
        } catch let LlmdbError.daemonUnreachable(msg) where msg.contains("no booted") {
            // Acceptable: no simulator booted on this machine. Test environment
            // doesn't require one.
        }
    }
}
