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

    /// One SSE response in progress.
    ///
    /// A session connects the handler task to the task that writes to the connection.
    /// A web framework lends its body writer to one task only, so that task runs the write loop.
    /// The handler runs in a child task.
    ///
    /// Each framework adapter runs the write loop in this pattern:
    ///
    /// ```swift
    /// let session = SSEContext.Session(encoder: encoder)
    /// async let handlerDone: Void = session.run(handler)
    /// for await event in session.events {
    ///     do {
    ///         try await writer.write(event.text)
    ///         event.written.resume()
    ///     } catch {
    ///         await session.fail(event, with: error)
    ///         throw error
    ///     }
    /// }
    /// try await handlerDone
    /// ```
    ///
    /// If the write loop throws, the `async let` cancels the handler and waits for it.
    ///
    /// The loop is in each adapter and not in one shared function. The Vapor writer needs a
    /// `nonisolated(nonsending)` caller, and Swift 6.2 cannot call the Hummingbird writer from
    /// that type of function.
    struct Session: Sendable {
        /// The events that the handler sends. The adapter must write them in this order.
        let events: AsyncStream<Outgoing>

        private let outbox: AsyncStream<Outgoing>.Continuation
        private let context: SSEContext

        /// - Parameter encoder: The `JSONEncoder` for the `Encodable` values that the handler sends.
        init(encoder: JSONEncoder) {
            let (events, outbox) = AsyncStream<Outgoing>.makeStream()
            self.events = events
            self.outbox = outbox
            self.context = SSEContext(outbox: outbox, encoder: encoder)
        }

        /// Runs `handler` with the context of this session.
        ///
        /// When the handler returns or throws, this function closes the outbox.
        /// The write loop then stops after it writes the events that the outbox already has.
        func run(_ handler: @Sendable (SSEContext) async throws -> Void) async throws {
            defer { outbox.finish() }
            try await handler(context)
        }

        /// Fails `event` and each event in the queue. Call this function when a write throws `error`.
        ///
        /// This function closes the outbox, so each later send throws immediately.
        /// Thus no send waits for a write that cannot occur.
        func fail(_ event: Outgoing, with error: any Error) async {
            event.written.resume(throwing: error)
            outbox.finish()
            for await queued in events {
                queued.written.resume(throwing: error)
            }
        }
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
