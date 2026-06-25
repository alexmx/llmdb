import Foundation

/// An exception-breakpoint filter the adapter supports, e.g. swift_throw.
struct ExceptionFilter: Codable {
    /// The filter id passed to `break exception` to enable it.
    let id: String
    /// Human-readable description from the adapter, if provided.
    let label: String?
    /// Whether the adapter enables this filter by default.
    let isDefault: Bool
}
