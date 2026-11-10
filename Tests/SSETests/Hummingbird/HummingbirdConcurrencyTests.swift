#if Hummingbird
import AsyncHTTPClient
import Hummingbird
import HummingbirdTesting
import Synchronization
import Testing
@testable import SSE

/// One call that a response body makes on its writer.
private enum WriterCall: Equatable {
    case write(String)
    case finish
}

private struct ClientWentAway: Error {}

/// The calls that a response body makes on its writer, in order.
private final class CallLog: Sendable {
    private let storage = Mutex<[WriterCall]>([])

    var calls: [WriterCall] { storage.withLock { $0 } }

    /// Adds `call` and returns the new number of calls.
    @discardableResult
    func append(_ call: WriterCall) -> Int {
        storage.withLock { calls in
            calls.append(call)
            return calls.count
        }
    }
}

/// A body writer that records each call in a ``CallLog``.
///
/// `failAfter` makes `write` throw after the writer accepts that number of chunks.
/// This simulates a client that disconnects during the stream.
private struct RecordingWriter: ResponseBodyWriter {
    let log: CallLog
    let failAfter: Int?

    mutating func write(_ buffer: ByteBuffer) async throws {
        let count = log.append(.write(String(buffer: buffer)))
        if let failAfter, count > failAfter { throw ClientWentAway() }
    }

    consuming func finish(_ trailingHeaders: HTTPFields?) async throws {
        log.append(.finish)
    }
}

/// Runs the body of `response` and returns the calls that the body makes on its writer.
///
/// If the body throws, `log` still holds the calls that the body made before the error.
@discardableResult
private func record(
    _ response: Response,
    into log: CallLog = CallLog(),
    failAfter: Int? = nil
) async throws -> [WriterCall] {
    try await response.body.write(RecordingWriter(log: log, failAfter: failAfter))
    return log.calls
}

/// `SSEContext` is `Sendable`, so a handler can send from more than one task.
/// That is safe only if each event is one write, and the writes occur one at a time.
///
/// These tests hold that rule for the Hummingbird adapter. If a change splits an
/// event into more than one write, the assertions on the recorded calls fail.
@Suite("SSE concurrency guarantees with Hummingbird")
struct HummingbirdConcurrencyTests {
    @Test func eachSendPerformsExactlyOneWrite() async throws {
        struct Payload: Codable, Sendable { var status: String }

        let response = Response.sse { sse in
            try await sse.send("plain")
            try await sse.send(event: "named", data: "value")
            try await sse.send(Payload(status: "ok"))
            try await sse.send(event: "typed", data: Payload(status: "ok"))
            try await sse.sendComment("keep-alive")
            try await sse.send(ServerSentEvent(id: "1", event: "full", data: "body", retry: 3000))
        }

        #expect(try await record(response) == [
            .write("data: plain\n\n"),
            .write("event: named\ndata: value\n\n"),
            .write("data: {\"status\":\"ok\"}\n\n"),
            .write("event: typed\ndata: {\"status\":\"ok\"}\n\n"),
            .write(": keep-alive\n\n"),
            .write("id: 1\nevent: full\nretry: 3000\ndata: body\n\n"),
            .finish,
        ])
    }

    /// A payload with more than one line becomes more than one `data:` line.
    /// The lines must go out as one write. If they do not, a second sender can
    /// put its event between the lines.
    @Test func multiLinePayloadIsASingleWrite() async throws {
        let response = Response.sse { sse in
            try await sse.send("first\nsecond\nthird")
        }

        #expect(try await record(response) == [
            .write("data: first\ndata: second\ndata: third\n\n"),
            .finish,
        ])
    }

    /// A large payload must also go out as one write.
    @Test func largePayloadIsASingleWrite() async throws {
        let payload = String(repeating: "x", count: 512 * 1024)
        let response = Response.sse { sse in
            try await sse.send(payload)
        }

        let calls = try await record(response)
        #expect(calls.count == 2)
        #expect(calls.first == .write("data: \(payload)\n\n"))
        #expect(calls.last == .finish)
    }

    /// The body must finish the stream one time, after the last event.
    /// A stream that the body does not finish stays open on a real connection.
    @Test func handlerReturnFinishesTheStreamOnce() async throws {
        let response = Response.sse { _ in }

        #expect(try await record(response) == [.finish])
    }

    /// A send returns only after the writer has the event.
    /// Thus a handler that returns has no event in flight.
    @Test func sendWaitsForTheWrite() async throws {
        let log = CallLog()
        let writesSeenAfterEachSend = Mutex<[Int]>([])
        let response = Response.sse { sse in
            for i in 0..<5 {
                try await sse.send("\(i)")
                let writes = log.calls.count
                writesSeenAfterEachSend.withLock { $0.append(writes) }
            }
        }

        try await record(response, into: log)
        #expect(writesSeenAfterEachSend.withLock { $0 } == [1, 2, 3, 4, 5])
    }

    /// When the client disconnects, the write error comes out of `send`.
    /// That error is how a handler with a long loop knows that it must stop.
    @Test func writeFailureFailsTheSendAndEndsTheHandler() async throws {
        let log = CallLog()
        let sendErrors = Mutex<[any Error]>([])
        let response = Response.sse { sse in
            for i in 0..<100 {
                do {
                    try await sse.send("\(i)")
                } catch {
                    sendErrors.withLock { $0.append(error) }
                    return
                }
            }
        }

        await #expect(throws: ClientWentAway.self) {
            try await record(response, into: log, failAfter: 2)
        }
        let errors = sendErrors.withLock { $0 }
        #expect(errors.count == 1)
        #expect(errors.first is ClientWentAway)
        // The body does not write after the failure and does not finish the stream.
        #expect(log.calls == [.write("data: 0\n\n"), .write("data: 1\n\n"), .write("data: 2\n\n")])
    }

    /// A write failure also cancels a handler that does not send at that time.
    @Test func writeFailureCancelsAnIdleHandler() async throws {
        let log = CallLog()
        let response = Response.sse { sse in
            try await sse.send("only")
            try await Task.sleep(for: .seconds(60))
        }

        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: ClientWentAway.self) {
            try await record(response, into: log, failAfter: 0)
        }
        #expect(clock.now - start < .seconds(5))
    }

    /// An error from the handler fails the response.
    /// The body does not finish the stream, so the client sees a failed stream.
    @Test func handlerErrorPropagates() async throws {
        struct HandlerFailed: Error {}
        let log = CallLog()
        let response = Response.sse { sse in
            try await sse.send("before")
            throw HandlerFailed()
        }

        await #expect(throws: HandlerFailed.self) {
            try await record(response, into: log)
        }
        #expect(log.calls == [.write("data: before\n\n")])
    }

    /// A context that outlives its handler has no connection.
    /// A send on that context must throw. It must not wait.
    @Test func sendAfterStreamEndsThrows() async throws {
        let escaped = Mutex<SSEContext?>(nil)
        let response = Response.sse { sse in
            escaped.withLock { $0 = sse }
            try await sse.send("hello")
        }

        _ = try await record(response)
        let sse = try #require(escaped.withLock { $0 })
        await #expect(throws: SSEStreamClosedError.self) {
            try await sse.send("too late")
        }
    }

    /// Through a real server, each event must get to the client when the handler sends it.
    /// A body that holds the events until the stream ends passes each other test in this suite.
    @Test func eventsArriveWhileTheStreamIsOpen() async throws {
        let router = Router()
        router.get("events") { _, _ in
            Response.sse { sse in
                try await sse.send("first")
                try await Task.sleep(for: .seconds(2))
                try await sse.send("second")
            }
        }

        try await Application(router: router).test(.live) { client in
            let port = try #require(client.port)
            let clock = ContinuousClock()
            let start = clock.now
            var arrivals: [Duration] = []

            let request = HTTPClientRequest(url: "http://localhost:\(port)/events")
            let response = try await HTTPClient.shared.execute(request, timeout: .seconds(30))
            for try await _ in response.body {
                arrivals.append(clock.now - start)
            }

            let first = try #require(arrivals.first)
            let last = try #require(arrivals.last)
            #expect(first < .seconds(1))
            #expect(last >= .seconds(2))
        }
    }

    /// Through a real server, many tasks that send at the same time must give complete events.
    /// No event can have a part of a different event in it, and no event can be absent.
    @Test func concurrentSendsDoNotInterleave() async throws {
        let eventCount = 200
        let repeats = 50

        let router = Router()
        router.get("events") { _, _ in
            Response.sse { sse in
                await withTaskGroup(of: Void.self) { group in
                    for i in 0..<eventCount {
                        group.addTask {
                            // Each part of one event has the same number.
                            // Thus the test can find an event that has parts of two events.
                            let payload = Array(repeating: "\(i)", count: repeats)
                                .joined(separator: "-")
                            try? await sse.send(payload)
                        }
                    }
                }
            }
        }

        try await Application(router: router).test(.live) { client in
            let response = try await client.execute(uri: "/events", method: .get)
            let events = String(buffer: response.body)
                .split(separator: "\n\n", omittingEmptySubsequences: true)

            #expect(events.count == eventCount)

            var seen = Set<Int>()
            for event in events {
                guard event.hasPrefix("data: ") else {
                    Issue.record("Event has no data prefix: \(event.prefix(80))")
                    continue
                }
                let parts = event.dropFirst("data: ".count).split(separator: "-")
                let unique = Set(parts)
                guard unique.count == 1, parts.count == repeats,
                      let value = unique.first.flatMap({ Int($0) }) else {
                    Issue.record("Event has parts of two events: \(event.prefix(80))")
                    continue
                }
                seen.insert(value)
            }

            // Each event arrived one time and is complete.
            #expect(seen.count == eventCount)
        }
    }

    /// The heartbeat pattern from the documentation: a keep-alive task runs while a second task sends events.
    @Test func heartbeatAlongsideEventsStaysIntact() async throws {
        let count = 100

        let router = Router()
        router.get("events") { _, _ in
            Response.sse { sse in
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for _ in 0..<count { try? await sse.sendComment("keep-alive") }
                    }
                    group.addTask {
                        for i in 0..<count { try? await sse.send(event: "tick", data: "\(i)") }
                    }
                }
            }
        }

        try await Application(router: router).test(.live) { client in
            let response = try await client.execute(uri: "/events", method: .get)
            let events = String(buffer: response.body)
                .split(separator: "\n\n", omittingEmptySubsequences: true)

            let comments = events.filter { $0 == ": keep-alive" }.count
            let ticks = events.filter { $0.hasPrefix("event: tick\ndata: ") }.count

            #expect(comments == count)
            #expect(ticks == count)
            // The body has no other text, so each event is complete.
            #expect(events.count == comments + ticks)
        }
    }
}
#endif
