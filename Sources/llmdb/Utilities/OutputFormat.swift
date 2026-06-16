import ArgumentParser

enum OutputFormat: String, ExpressibleByArgument {
    case json
    case toon
    case plain

    static let `default`: OutputFormat = .json
}
