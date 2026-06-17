import Foundation

// llmdb fixture — a deterministic guinea-pig binary for exercising the debugger.
//
// Canonical breakpoint targets (line numbers are part of the fixture's contract;
// keep them stable or update the test that references them):
//
//   main.swift:34  BP1 — inside compute(), return statement, sum/product/diff/total bound
//   main.swift:41  BP2 — inside fibonacci(), after both recursive calls (a, b bound)
//   main.swift:48  BP3 — inside walkArray() loop body, index/item/upper/length bound
//   main.swift:55  BP4 — inside processOptional(), unwrapped value bound
//   main.swift:79  BP5 — final exit marker, all top-level locals still alive
//
// Run modes:
//   quick   — exits in <100ms; for `llmdb launch ... && break + continue` tests
//   attach  — sleeps 30s mid-run; for `llmdb attach --pid` tests

struct Point {
    var x: Int
    var y: Int
    var label: String
}

enum Mode: String {
    case quick
    case attach
}

func compute(x: Int, y: Int) -> Int {
    let sum = x + y
    let product = x * y
    let diff = abs(x - y)
    let total = sum + product + diff
    return total
}

func fibonacci(_ n: Int) -> Int {
    if n < 2 { return n }
    let a = fibonacci(n - 1)
    let b = fibonacci(n - 2)
    return a + b
}

func walkArray(_ items: [String]) {
    for (index, item) in items.enumerated() {
        let upper = item.uppercased()
        let length = item.count
        print("[\(index)] \(upper) (len=\(length))")
    }
}

func processOptional(_ value: Int?) -> String {
    guard let unwrapped = value else { return "nil" }
    let label = "value=\(unwrapped)"
    return label
}

let modeArg = CommandLine.arguments.dropFirst().first ?? "quick"
let mode = Mode(rawValue: modeArg) ?? .quick

let origin = Point(x: 3, y: 4, label: "origin")
let computed = compute(x: origin.x, y: origin.y)
print("compute(\(origin.x), \(origin.y)) = \(computed)")

let fib = fibonacci(8)
print("fib(8) = \(fib)")

walkArray(["alpha", "beta", "gamma"])

print(processOptional(42))
print(processOptional(nil))

if mode == .attach {
    let pid = getpid()
    print("Sleeping 30s — attach now with:  llmdb attach --pid \(pid)")
    Thread.sleep(forTimeInterval: 30)
}

print("done")
