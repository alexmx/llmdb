import Foundation
@testable import llmdb
import Testing

@Suite("llmdb scaffold")
struct LlmdbScaffoldTests {
    @Test
    func versionExists() {
        #expect(!llmdbVersion.isEmpty)
    }

    @Test
    func errorDescriptions() {
        #expect(LlmdbError.sessionNotFound("abc123").description == "no session with id abc123")
    }
}

@Suite("Paths")
struct PathTests {
    @Test
    func locationKeepsRelativeFileAsTyped() throws {
        // lldb matches by suffix; making this absolute against the cwd
        // produced a path that never resolved.
        let (file, line) = try parseFileLineLocation("main.swift:56")
        #expect(file == "main.swift")
        #expect(line == 56)
    }

    @Test
    func locationSplitsOnLastColon() throws {
        let (file, line) = try parseFileLineLocation("/tmp/a:b/main.swift:7")
        #expect(file == "/tmp/a:b/main.swift")
        #expect(line == 7)
    }

    @Test
    func locationRejectsMissingLine() {
        #expect(throws: LlmdbError.self) { try parseFileLineLocation("main.swift") }
    }

    @Test
    func absolutePathResolvesRelativeAgainstCwd() {
        let cwd = FileManager.default.currentDirectoryPath
        #expect(absolutePath("bin/tool") == cwd + "/bin/tool")
        #expect(absolutePath("/usr/bin/tool") == "/usr/bin/tool")
    }
}
