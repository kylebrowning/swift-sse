#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

extension JSONEncoder {
    /// The default encoder for SSE JSON payloads. The encoder writes compact JSON on one line.
    public static var sse: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
