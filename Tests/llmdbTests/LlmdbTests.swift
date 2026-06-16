import Testing
@testable import llmdb

@Suite("llmdb scaffold")
struct LlmdbScaffoldTests {
    @Test("version is non-empty")
    func versionExists() {
        #expect(!llmdbVersion.isEmpty)
    }

    @Test("error descriptions are non-empty")
    func errorDescriptions() {
        let err = LlmdbError.notImplemented("foo")
        #expect(!err.description.isEmpty)
    }
}
