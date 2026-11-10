#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Thrown by ``SSEContext`` sends once the stream they belong to has ended.
///
/// The usual cause is keeping a reference to the context and sending after the
/// handler has returned. The stream ends when the handler does, so there is no
/// connection left to write to.
public struct SSEStreamClosedError: Error, Sendable, Equatable {
    public init() {}
}

/// A handle for an active SSE connection. Use it to send events to the client.
///
/// ## Concurrency
///
/// `SSEContext` is `Sendable`, and it is safe to send from more than one task at the same time.
/// A common example is a keep-alive task that runs while a second task sends the events:
///
/// ```swift
/// Response.sse { sse in
///     await withTaskGroup(of: Void.self) { group in
///         group.addTask { for await event in stream { try? await sse.send(event) } }
///         group.addTask { while true { try? await sse.sendComment("keep-alive") } }
///     }
/// }
/// ```
///
/// The web framework lends the response body writer to one task for the life of the stream.
/// Thus a send does not use the connection directly. A send gives its serialized event to
/// that task and waits until the task writes the event. The task writes one event at a time,
/// and each event is one write. Two tasks that send at the same time cannot put one event
/// into the middle of a different event.
///
/// - Important: Concurrent sends have no defined order. If you set `id` values for
///   `Last-Event-ID` resume, send those events from one task. Sequential `await`s from one
///   task always keep their order, because each send completes before the next send starts.
public final class SSEContext: Sendable {
    /// A serialized event waiting to be written, and the send waiting on it.
    struct Outgoing: Sendable {
        let text: String
        let written: CheckedContinuation<Void, any Error>
    }

    private let outbox: AsyncStream<Outgoing>.Continuation
    private let encoder: JSONEncoder

    init(outbox: AsyncStream<Outgoing>.Continuation, encoder: JSONEncoder) {
        self.outbox = outbox
        self.encoder = encoder
    }

    /// Runs `handler` with a new context and gives each event that the handler sends to `write`.
    ///
    /// The handler runs in a child task. The task that calls this function calls `write`,
    /// because a web framework lends its body writer to that task only.
    ///
    /// This function returns after the handler returns and `write` has each event.
    /// If the handler throws, this function throws the same error.
    /// If `write` throws, this function cancels the handler and waits for it.
    /// Then this function throws the write error.
    ///
    /// - Parameters:
    ///   - encoder: The `JSONEncoder` for the `Encodable` values that the handler sends.
    ///   - handler: The closure that sends the events.
    ///   - write: An operation that writes one serialized event to the connection.
    nonisolated(nonsending) static func run(
        encoder: JSONEncoder,
        handler: @Sendable @escaping (SSEContext) async throws -> Void,
        write: nonisolated(nonsending) (String) async throws -> Void
    ) async throws {
        let (events, outbox) = AsyncStream<Outgoing>.makeStream()
        let context = SSEContext(outbox: outbox, encoder: encoder)

        // The handler runs in a child task, so this task is free to run the write loop.
        // If this scope throws, the `async let` cancels the handler and waits for it.
        async let handlerDone: Void = {
            // The end of the outbox stops the write loop below.
            // The loop first writes the events that the outbox already has.
            defer { outbox.finish() }
            try await handler(context)
        }()

        for await event in events {
            do {
                try await write(event.text)
                event.written.resume()
            } catch {
                event.written.resume(throwing: error)
                // The connection is closed. Close the outbox so that each later send
                // throws immediately. Then fail each event in the queue, so that no
                // send waits for a write that cannot occur.
                outbox.finish()
                for await queued in events {
                    queued.written.resume(throwing: error)
                }
                throw error
            }
        }

        try await handlerDone
    }

    /// Sends a ``ServerSentEvent`` to the client.
    ///
    /// Returns once the event has been written to the connection.
    ///
    /// - Throws: The write error if the client has gone away, or
    ///   ``SSEStreamClosedError`` if the stream has already ended.
    public func send(_ event: ServerSentEvent) async throws {
        let text = event.serialize()
        try await withCheckedThrowingContinuation { (written: CheckedContinuation<Void, any Error>) in
            if case .terminated = outbox.yield(Outgoing(text: text, written: written)) {
                written.resume(throwing: SSEStreamClosedError())
            }
        }
    }

    /// Sends a data-only event with a raw string.
    public func send(_ data: String) async throws {
        try await send(ServerSentEvent(data: data))
    }

    /// Sends a data-only event with an `Encodable` value as JSON.
    public func send<T: Encodable & Sendable>(_ value: T) async throws {
        let json = try encoder.encode(value)
        try await send(ServerSentEvent(data: String(decoding: json, as: UTF8.self)))
    }

    /// Sends a named event with a raw string.
    public func send(event: String, data: String) async throws {
        try await send(ServerSentEvent(event: event, data: data))
    }

    /// Sends a named event with an `Encodable` value as JSON.
    public func send<T: Encodable & Sendable>(event: String, data value: T) async throws {
        let json = try encoder.encode(value)
        try await send(ServerSentEvent(event: event, data: String(decoding: json, as: UTF8.self)))
    }

    /// Sends a comment line. Useful as a keep-alive.
    public func sendComment(_ comment: String) async throws {
        try await send(ServerSentEvent(comment: comment))
    }
}
