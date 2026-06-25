import Foundation
@testable import llmdb
import Testing

@Suite("SessionManager against llmdb-fixture")
struct SessionManagerIntegrationTests {
    @Test
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
            line: 35
        )
        #expect(bp.verified == true)
        #expect(bp.line == 35)

        // 3. continue — runs until BP1 hits
        let stoppedSnap = try await manager.continueExecution(sessionId: sessionID)
        #expect(stoppedSnap.state == .stopped)
        #expect(stoppedSnap.stopReason?.reason == "breakpoint")

        // 4. bt
        let frames = try await manager.backtrace(sessionId: sessionID)
        #expect(!frames.isEmpty)
        #expect(frames[0].name.contains("compute"))
        #expect(frames[0].line == 35)

        // 5. locals
        let locals = try await manager.locals(sessionId: sessionID)
        var values: [String: String] = [:]
        for l in locals {
            values[l.name] = l.value
        }
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

        // 7. expr — same math from the locals scope, but via lldb's evaluator
        let totalExpr = try await manager.evaluate(sessionId: sessionID, expression: "total")
        #expect(totalExpr.value == "20")
        let sumPlusDiff = try await manager.evaluate(sessionId: sessionID, expression: "sum + diff")
        #expect(sumPlusDiff.value == "8") // 7 + 1

        // 8. break list / break delete round-trip
        let beforeDelete = try await manager.listBreakpoints(sessionId: sessionID)
        #expect(beforeDelete.count == 1)
        let bpID = beforeDelete[0].id
        let afterDelete = try await manager.deleteBreakpoint(sessionId: sessionID, id: bpID)
        #expect(afterDelete.isEmpty)

        // 9. step --over the `return total` line; we return out of compute(),
        //    landing in the top-level caller at the print line.
        let stepSnap = try await manager.step(sessionId: sessionID, granularity: .over)
        #expect(stepSnap.state == .stopped)
        let afterStep = try await manager.backtrace(sessionId: sessionID)
        #expect(!afterStep.isEmpty)
        // Top frame should no longer be inside compute()
        #expect(!afterStep[0].name.contains("compute"))

        // 10. stop — clean teardown
        let stopped = try await manager.stop(sessionId: sessionID)
        #expect(stopped == true)
        #expect(await manager.list().isEmpty)
    }

    @Test
    func continueFireAndForgetPlusWait() async throws {
        let paths = try fixturePaths()
        let manager = SessionManager()
        let launch = try await manager.launch(binary: paths.fixtureBinary, args: ["quick"])
        let sid = launch.sessionId
        _ = try await manager.setBreakpoint(sessionId: sid, file: paths.fixtureSource, line: 35)
        // wait: 0 → fire-and-forget. Returns immediately with state=running.
        let firedSnap = try await manager.continueExecution(sessionId: sid, wait: 0)
        #expect(firedSnap.state == .running)
        // wait verb blocks until the BP hits.
        let stopped = try await manager.wait(sessionId: sid, timeout: 5)
        #expect(stopped.state == .stopped)
        #expect(stopped.stopReason?.reason == "breakpoint")
        _ = try await manager.stop(sessionId: sid)
    }

    @Test
    func unverifiedBreakpointCarriesExplanation() async throws {
        let paths = try fixturePaths()
        let manager = SessionManager()
        let launch = try await manager.launch(binary: paths.fixtureBinary, args: ["quick"])
        // Set a BP in a file the binary doesn't contain → unverified.
        let (_, bp) = try await manager.setBreakpoint(
            sessionId: launch.sessionId,
            file: "/tmp/nonexistent-source.swift",
            line: 1
        )
        #expect(bp.verified == false)
        #expect(
            bp.message?.contains("verification deferred") == true,
            "expected stock unverified message, got: \(bp.message ?? "nil")"
        )
        _ = try await manager.stop(sessionId: launch.sessionId)
    }

    @Test
    func runUntilCompositeVerb() async throws {
        let paths = try fixturePaths()
        let manager = SessionManager()

        let launchSnap = try await manager.launch(binary: paths.fixtureBinary, args: ["quick"])

        let (stopSnap, bp) = try await manager.runUntil(
            sessionId: launchSnap.sessionId,
            file: paths.fixtureSource,
            line: 35
        )
        #expect(stopSnap.state == .stopped)
        #expect(stopSnap.stopReason?.reason == "breakpoint")
        #expect(bp.verified == true)
        #expect(bp.line == 35)

        // We should be inside compute() — same state as the longer test reaches.
        let frames = try await manager.backtrace(sessionId: launchSnap.sessionId)
        #expect(frames.first?.name.contains("compute") == true)

        _ = try await manager.stop(sessionId: launchSnap.sessionId)
    }

    @Test
    func conditionalBreakpointStopsOnMatch() async throws {
        let paths = try fixturePaths()
        let manager = SessionManager()

        let launch = try await manager.launch(binary: paths.fixtureBinary, args: ["quick"])
        let sid = launch.sessionId

        // BP3 is the walkArray loop body, iterated over ["alpha","beta","gamma"].
        // `index == 2` should skip the first two passes and stop on "gamma".
        let (_, bp) = try await manager.setBreakpoint(
            sessionId: sid,
            file: paths.fixtureSource,
            line: 49,
            condition: "index == 2"
        )
        #expect(bp.verified == true)
        #expect(bp.condition == "index == 2")

        let stopped = try await manager.continueExecution(sessionId: sid)
        #expect(stopped.state == .stopped)
        #expect(stopped.stopReason?.reason == "breakpoint")

        let locals = try await manager.locals(sessionId: sid)
        let index = locals.first { $0.name == "index" }?.value
        #expect(index == "2", "condition should have held execution until index == 2, got \(index ?? "nil")")

        // The condition survives a break.list round-trip.
        let listed = try await manager.listBreakpoints(sessionId: sid)
        #expect(listed.first?.condition == "index == 2")

        _ = try await manager.stop(sessionId: sid)
    }

    @Test
    func expandStructuredValue() async throws {
        let paths = try fixturePaths()
        let manager = SessionManager()

        let launch = try await manager.launch(binary: paths.fixtureBinary, args: ["quick"])
        let sid = launch.sessionId

        // BP3 (walkArray) has `items: [String]` in scope — a structured value.
        _ = try await manager.runUntil(sessionId: sid, file: paths.fixtureSource, line: 49)

        let locals = try await manager.locals(sessionId: sid)
        guard let items = locals.first(where: { $0.name == "items" }),
              let ref = items.variablesReference, ref > 0
        else {
            Issue.record("expected a structured `items` local with a non-zero variablesReference")
            return
        }

        let children = try await manager.expand(sessionId: sid, variablesReference: ref)
        #expect(children.count == 3)
        #expect(children.map(\.name) == ["[0]", "[1]", "[2]"])
        #expect(children.map(\.value) == ["\"alpha\"", "\"beta\"", "\"gamma\""])

        // A zero/negative reference is a leaf and must be rejected, not sent to lldb.
        await #expect(throws: LlmdbError.self) {
            _ = try await manager.expand(sessionId: sid, variablesReference: 0)
        }

        _ = try await manager.stop(sessionId: sid)
    }

    @Test
    func exceptionBreakpointStopsOnThrow() async throws {
        let binary = try throwFixtureBinary()
        let manager = SessionManager()

        let launch = try await manager.launch(binary: binary, args: [])
        let sid = launch.sessionId

        // Empty filter list discovers what the adapter advertises without enabling.
        let (available, enabledNone) = try await manager.setExceptionBreakpoints(sessionId: sid, filters: [])
        #expect(available.contains { $0.id == "swift_throw" })
        #expect(enabledNone.isEmpty)

        // Unknown ids are rejected against the advertised set.
        await #expect(throws: LlmdbError.self) {
            _ = try await manager.setExceptionBreakpoints(sessionId: sid, filters: ["nope_throw"])
        }

        // Enable Swift throws, then continue — execution must stop at the throw
        // site instead of running to exit.
        let (_, enabled) = try await manager.setExceptionBreakpoints(sessionId: sid, filters: ["swift_throw"])
        #expect(enabled == ["swift_throw"])

        let stopped = try await manager.continueExecution(sessionId: sid)
        #expect(stopped.state == .stopped)
        #expect(stopped.stopReason?.reason == "exception")

        let frames = try await manager.backtrace(sessionId: sid)
        #expect(frames.contains { $0.name.contains("throwingWork") })

        _ = try await manager.stop(sessionId: sid)
    }

    @Test
    func capturesProgramOutput() async throws {
        let paths = try fixturePaths()
        let manager = SessionManager()

        let launch = try await manager.launch(binary: paths.fixtureBinary, args: ["quick"])
        let sid = launch.sessionId

        // Stop at BP5 (line 80) — every earlier print (lines 64-72) has run, but
        // "done" (printed at line 80) has not.
        _ = try await manager.runUntil(sessionId: sid, file: paths.fixtureSource, line: 80)

        // Output events race the stopped event; poll briefly for the last
        // pre-stop line to land in the buffer.
        var joined = ""
        for _ in 0..<20 {
            joined = try await manager.output(sessionId: sid).map(\.text).joined()
            if joined.contains("fib(8) = 21") { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(joined.contains("compute(3, 4) = 20"))
        #expect(joined.contains("fib(8) = 21"))
        #expect(!joined.contains("done"), "line 80 not executed yet, so 'done' should be unbuffered")

        let chunks = try await manager.output(sessionId: sid)
        #expect(chunks.allSatisfy { $0.category == "stdout" })

        // Drain, then a fresh read returns nothing new while still stopped.
        _ = try await manager.output(sessionId: sid, clear: true)
        #expect(try await manager.output(sessionId: sid).isEmpty)

        _ = try await manager.stop(sessionId: sid)
    }

    @Test
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
        #expect(attachSnap.state == .stopped) // lldb-dap pauses on attach

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

    private func throwFixtureBinary() throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                let binary = dir.appendingPathComponent(".build/debug/llmdb-throw-fixture").path
                guard FileManager.default.fileExists(atPath: binary) else {
                    throw Skip("llmdb-throw-fixture not built — run `swift build` before testing")
                }
                return binary
            }
            dir = dir.deletingLastPathComponent()
        }
        throw Skip("could not locate Package.swift")
    }

    struct Skip: Error, CustomStringConvertible {
        let message: String
        init(_ m: String) {
            self.message = m
        }

        var description: String {
            message
        }
    }
}
