import Foundation

enum DAPError: Error, CustomStringConvertible {
    case parseFailed(String)
    case missingBody
    case unexpectedMessageType(String)
    case responseError(command: String, message: String)
    case closed
    case launchFailed(String)

    var description: String {
        switch self {
        case .parseFailed(let reason): "DAP parse failed: \(reason)"
        case .missingBody: "DAP message had no body"
        case .unexpectedMessageType(let t): "unexpected DAP message type: \(t)"
        case .responseError(let cmd, let msg): "DAP \(cmd) failed: \(msg)"
        case .closed: "DAP connection closed"
        case .launchFailed(let reason): "could not launch lldb-dap: \(reason)"
        }
    }
}

/// A parsed DAP response. The `body` field is retained as raw JSON so consumers
/// can decode it into typed shapes on demand without DAPClient needing to know
/// every command's response schema.
struct DAPResponse {
    let seq: Int
    let requestSeq: Int
    let success: Bool
    let command: String
    let message: String?
    let body: Data?

    func decodeBody<T: Decodable & Sendable>(_ type: T.Type) throws -> T {
        guard let body else { throw DAPError.missingBody }
        return try JSONDecoder().decode(T.self, from: body)
    }
}

/// A parsed DAP event (`stopped`, `output`, `terminated`, `breakpoint`,
/// `module`, etc.). Body is retained as raw JSON for the same reason as
/// `DAPResponse`.
struct DAPEvent {
    let seq: Int
    let event: String
    let body: Data?

    func decodeBody<T: Decodable & Sendable>(_ type: T.Type) throws -> T {
        guard let body else { throw DAPError.missingBody }
        return try JSONDecoder().decode(T.self, from: body)
    }
}

enum DAPMessage {
    case response(DAPResponse)
    case event(DAPEvent)

    static func parse(_ data: Data) throws -> DAPMessage {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else {
            throw DAPError.parseFailed("not a JSON object or missing `type`")
        }
        let seq = obj["seq"] as? Int ?? 0

        // Re-serialize the body field to bytes so consumers can JSONDecoder-decode it.
        let bodyData: Data? = if let bodyObj = obj["body"] {
            try? JSONSerialization.data(withJSONObject: bodyObj)
        } else {
            nil
        }

        switch type {
        case "response":
            return .response(DAPResponse(
                seq: seq,
                requestSeq: obj["request_seq"] as? Int ?? 0,
                success: obj["success"] as? Bool ?? false,
                command: obj["command"] as? String ?? "",
                message: obj["message"] as? String,
                body: bodyData
            ))
        case "event":
            return .event(DAPEvent(
                seq: seq,
                event: obj["event"] as? String ?? "",
                body: bodyData
            ))
        case "request":
            // lldb-dap can issue reverse requests (runInTerminal). Treat as event-like
            // for now; we don't service them in M1.
            throw DAPError.unexpectedMessageType("request (reverse — not handled in M1)")
        default:
            throw DAPError.unexpectedMessageType(type)
        }
    }
}
