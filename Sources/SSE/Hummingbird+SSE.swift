#if Hummingbird
public import Hummingbird

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

extension Request {
    /// The value of the `Last-Event-ID` header that the client sends when it connects again.
    public var lastEventID: String? {
        headers[.lastEventID]
    }
}

extension Response {
    /// Creates an SSE streaming response.
    ///
    /// The `handler` closure receives an ``SSEContext``. Use the context to send events.
    /// The connection stays open until the handler returns.
    ///
    /// ```swift
    /// router.get("events") { request, context in
    ///     Response.sse { sse in
    ///         try await sse.send(MyPayload(count: 42))
    ///         try await sse.send(event: "update", data: "done")
    ///     }
    /// }
    /// ```
    ///
    /// The response has no `Connection` header, because HTTP/2 does not permit that header.
    ///
    /// - Parameters:
    ///   - encoder: The `JSONEncoder` for `Encodable` values. The default encoder does not escape slashes.
    ///   - handler: A closure that receives an ``SSEContext`` and sends the events.
    public static func sse(
        encoder: JSONEncoder = .sse,
        _ handler: @Sendable @escaping (SSEContext) async throws -> Void
    ) -> Response {
        Response(
            status: .ok,
            headers: [
                .contentType: "text/event-stream",
                .cacheControl: "no-cache",
            ],
            body: ResponseBody { writer in
                try await SSEContext.run(encoder: encoder, handler: handler) { text in
                    try await writer.write(ByteBuffer(string: text))
                }
                try await writer.finish(nil)
            }
        )
    }
}
#endif
