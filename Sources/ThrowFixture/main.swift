import Foundation

// llmdb-throw-fixture — a minimal binary that throws a Swift error, used to
// exercise exception breakpoints (the swift_throw filter). Kept separate from
// llmdb-fixture so that fixture's pinned breakpoint line numbers stay stable.

enum FixtureError: Error { case boom(Int) }

func throwingWork() throws -> Int {
    throw FixtureError.boom(7)
}

print("throw-fixture start")
// `try?` swallows the error so the process exits cleanly when run without a
// debugger; the swift_throw breakpoint still stops at the throw site.
_ = try? throwingWork()
print("throw-fixture done")
