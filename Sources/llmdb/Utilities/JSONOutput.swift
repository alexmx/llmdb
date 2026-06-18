import Foundation

enum JSONOutput {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    static func print<T: Encodable>(_ value: T) throws {
        try Swift.print(encode(value))
    }
}
