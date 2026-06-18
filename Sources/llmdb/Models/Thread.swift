import Foundation

/// A live thread reported by lldb-dap. `id` is the DAP/OS thread id —
/// large opaque integer, treat as a handle.
struct Thread: Codable {
    let id: Int
    let name: String?
}
