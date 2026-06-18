import Foundation

struct DoctorCheck: Codable {
    let name: String
    let ok: Bool
    let detail: String?
}

struct DoctorReport: Codable {
    let checks: [DoctorCheck]
    var allOK: Bool {
        checks.allSatisfy(\.ok)
    }
}
