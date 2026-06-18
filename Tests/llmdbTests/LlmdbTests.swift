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
        let err = LlmdbError.notImplemented("foo")
        #expect(!err.description.isEmpty)
    }
}
