import Foundation

/// A variable scope for a stack frame (e.g. Locals, Globals, Registers).
struct Scope: Codable {
    /// The scope name as reported by the adapter.
    let name: String
    /// Pass to `expand` to read this scope's variables.
    let variablesReference: Int
    /// True when reading the scope is costly (e.g. Registers).
    let expensive: Bool
}
