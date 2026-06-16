import Foundation

struct Frame: Codable, Sendable {
    let id: Int
    let name: String
    let source: String?
    let line: Int?
    let column: Int?
}

struct Local: Codable, Sendable {
    let name: String
    let type: String?
    let value: String
    let variablesReference: Int?
}
