import Foundation

/// Speaks Debug Adapter Protocol (Content-Length-framed JSON) to a child `lldb-dap` process.
///
/// TODO(M1): spawn `lldb-dap` via Subprocess, implement request/response correlation
/// by `seq`, surface `stopped`/`output`/`terminated`/`breakpoint` events as an
/// `AsyncStream<DAPEvent>`.
struct DAPClient {
    // Placeholder. The real client will hold the subprocess handle, an outbound
    // queue keyed by `seq`, and an inbound event stream.
}
