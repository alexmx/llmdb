import Foundation

// llmdb-throw-fixture — auxiliary binary for behaviors that would perturb
// llmdb-fixture's pinned breakpoint line numbers if added there:
//   * a Swift throw, for exception-breakpoint tests
//   * a mutable local, for set-var tests (llmdb-fixture's locals are all `let`)

enum FixtureError: Error { case boom(Int) }

func throwingWork() throws -> Int {
    throw FixtureError.boom(7)
}

func mutableLocal() -> Int {
    var counter = 1
    let doubled = counter * 2
    counter += doubled // line 17 — breakpoint target; `counter` (var) is mutable here
    return counter
}

print("throw-fixture start")
_ = mutableLocal()
// `try?` swallows the error so the process exits cleanly when run without a
// debugger; the swift_throw breakpoint still stops at the throw site.
_ = try? throwingWork()
print("throw-fixture done")
