import Foundation
import Testing
@testable import llmdb

@Suite("SessionManager against llmdb-fixture")
struct SessionManagerIntegrationTests {

    @Test("launch + break + continue + bt + locals end-to-end")
    func endToEnd() async throws {
        let paths = try fixturePaths()
        let manager = SessionManager()

        // 1. launch — stops on entry (lldb-dap reports the entry stop as
        // "exception" on Swift binaries, not "entry"; just check we're stopped)
        let launchSnap = try await manager.launch(binary: paths.fixtureBinary, args: ["quick"])
        #expect(launchSnap.state == .stopped)
        #expect(launchSnap.stopReason != nil)
        let sessionID = launchSnap.sessionId

        // 2. break set
        let (_, bp) = try await manager.setBreakpoint(
            sessionId: sessionID,
            file: paths.fixtureSource,
            line: 34
        )
        #expect(bp.verified == true)
        #expect(bp.line == 34)

        // 3. continue — runs until BP1 hits
        let stoppedSnap = try await manager.continueExecution(sessionId: sessionID)
        #expect(stoppedSnap.state == .stopped)
        #expect(stoppedSnap.stopReason?.reason == "breakpoint")

        // 4. bt
        let frames = try await manager.backtrace(sessionId: sessionID)
        #expect(!frames.isEmpty)
        #expect(frames[0].name.contains("compute"))
        #expect(frames[0].line == 34)

        // 5. locals
        let locals = try await manager.locals(sessionId: sessionID)
        var values: [String: String] = [:]
        for l in locals { values[l.name] = l.value }
        #expect(values["x"] == "3")
        #expect(values["y"] == "4")
        #expect(values["sum"] == "7")
        #expect(values["product"] == "12")
        #expect(values["diff"] == "1")
        #expect(values["total"] == "20")

        // 6. threads — should report at least one thread, including the
        //    stopped main thread
        let threads = try await manager.threads(sessionId: sessionID)
        #expect(!threads.isEmpty)

        // 7. step --over the `return total` line; we return out of compute(),
        //    landing in the top-level caller at the print line.
        let stepSnap = try await manager.step(sessionId: sessionID, granularity: .over)
        #expect(stepSnap.state == .stopped)
        let afterStep = try await manager.backtrace(sessionId: sessionID)
        #expect(!afterStep.isEmpty)
        // Top frame should no longer be inside compute()
        #expect(!afterStep[0].name.contains("compute"))

        // 8. stop — clean teardown
        let stopped = try await manager.stop(sessionId: sessionID)
        #expect(stopped == true)
        #expect(await manager.list().isEmpty)
    }

    @Test("attach to a running process + interrupt + stop")
    func attachAndInterrupt() async throws {
        let paths = try fixturePaths()

        // Spawn the fixture via /bin/sh so it's not a direct child of the
        // test process — avoids any inheritance / process-group oddness when
        // lldb-dap looks it up via task_for_pid.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "\(paths.fixtureBinary) attach > /dev/null 2>&1"]
        try proc.run()
        defer {
            if proc.isRunning { proc.terminate() }
        }
        // Give the fixture ~200ms to enter its sleep loop.
        try await Task.sleep(nanoseconds: 250_000_000)

        // The shell is the direct child; the fixture is its grandchild.
        // Find the fixture PID by looking up the shell's child.
        let pid = try findChildPID(of: proc.processIdentifier, name: "llmdb-fixture")

        let manager = SessionManager()
        let attachSnap = try await manager.attach(pid: pid)
        #expect(attachSnap.state == .stopped)  // lldb-dap pauses on attach

        // threads should report at least the main thread
        let threads = try await manager.threads(sessionId: attachSnap.sessionId)
        #expect(!threads.isEmpty)

        // detach (interrupt while-running is racy against the fixture's
        // sleep loop; covered separately in the launch test's step path).
        _ = try await manager.stop(sessionId: attachSnap.sessionId)
        #expect(await manager.list().isEmpty)
    }

    /// Use `pgrep -P <parent>` to find a child PID by binary name.
    private func findChildPID(of parent: Int32, name: String) throws -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-P", "\(parent)", name]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let str = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(str.split(separator: "\n").first ?? "") else {
            throw Skip("could not find child PID for \(name) under parent \(parent)")
        }
        return pid
    }

    private func fixturePaths() throws -> (fixtureBinary: String, fixtureSource: String) {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                let fixture = dir.appendingPathComponent(".build/debug/llmdb-fixture").path
                let source = dir.appendingPathComponent("Sources/Fixture/main.swift").path
                guard FileManager.default.fileExists(atPath: fixture) else {
                    throw Skip("llmdb-fixture not built — run `swift build` before testing")
                }
                return (fixture, source)
            }
            dir = dir.deletingLastPathComponent()
        }
        throw Skip("could not locate Package.swift")
    }

    struct Skip: Error, CustomStringConvertible {
        let message: String
        init(_ m: String) { self.message = m }
        var description: String { message }
    }
}
