import Foundation

enum JSONOutput {
    static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    static func print(_ value: some Encodable) throws {
        try Swift.print(encode(value))
    }
}
