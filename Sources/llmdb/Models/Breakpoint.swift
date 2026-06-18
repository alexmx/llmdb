import Foundation

struct Breakpoint: Codable {
    let id: Int
    let verified: Bool
    let line: Int?
    let source: String?
    let message: String?
}
