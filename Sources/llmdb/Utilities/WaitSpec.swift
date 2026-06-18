import ArgumentParser

/// `--wait` flag spec: a number of seconds, or "none" for fire-and-forget.
enum WaitSpec: ExpressibleByArgument {
    case fireAndForget
    case timeout(Double)

    init?(argument: String) {
        let lowered = argument.lowercased()
        if lowered == "none" {
            self = .fireAndForget
            return
        }
        guard let n = Double(argument), n >= 0 else { return nil }
        self = n == 0 ? .fireAndForget : .timeout(n)
    }

    /// Wire value: 0 for fire-and-forget, N for timeout.
    var wireValue: Double {
        switch self {
        case .fireAndForget: 0
        case .timeout(let n): n
        }
    }
}
