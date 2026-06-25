import Foundation

/// A chunk of program output captured from a DAP `output` event.
struct OutputChunk: Codable {
    /// The DAP output category, e.g. "stdout", "stderr", or "console".
    let category: String
    /// The text emitted; may be a partial line or several lines.
    let text: String
}
