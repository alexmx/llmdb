import Darwin
import Foundation

/// Shared POSIX bits for `llmdbd`'s newline-delimited JSON socket.
/// Used by both the daemon (server side) and DaemonClient (client side).
enum UnixSocketIO {

    /// Run `body` against a populated `sockaddr_un` for `path`. Throws if the
    /// path is too long for `sun_path`.
    static func withSockaddr<R>(
        path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> R
    ) throws -> R {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        try withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
            let dst = rawPtr.bindMemory(to: Int8.self)
            if pathBytes.count > dst.count {
                throw LlmdbError.daemonUnreachable(
                    "socket path too long (\(pathBytes.count) > \(dst.count)): \(path)"
                )
            }
            for (i, b) in pathBytes.enumerated() { dst[i] = Int8(bitPattern: b) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        return try withUnsafePointer(to: &addr) { ptr in
            try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                try body(sptr, len)
            }
        }
    }

    /// Write all of `data` to `fd`, retrying on EINTR. Throws on hard error
    /// or unexpected zero-byte writes (peer closed).
    static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let n = Darwin.write(fd, base.advanced(by: written), raw.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw LlmdbError.daemonUnreachable("write failed (errno \(errno))")
                }
                if n == 0 {
                    throw LlmdbError.daemonUnreachable("socket closed mid-write")
                }
                written += n
            }
        }
    }
}
