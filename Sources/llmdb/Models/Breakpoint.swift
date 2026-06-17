import Foundation

struct Breakpoint: Codable, Sendable {
    let id: Int
    let verified: Bool
    let line: Int?
    let source: String?
    let message: String?
}
