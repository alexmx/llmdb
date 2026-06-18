import Foundation

struct DoctorCheck: Codable, Sendable {
    let name: String
    let ok: Bool
    let detail: String?
}

struct DoctorReport: Codable, Sendable {
    let checks: [DoctorCheck]
    var allOK: Bool { checks.allSatisfy(\.ok) }
}
