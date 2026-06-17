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

        // 6. stop — clean teardown
        let stopped = try await manager.stop(sessionId: sessionID)
        #expect(stopped == true)
        #expect(await manager.list().isEmpty)
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
