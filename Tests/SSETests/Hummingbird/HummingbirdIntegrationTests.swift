#if Hummingbird
import Hummingbird
import HummingbirdTesting
import SSE
import Testing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Sends a GET request for `/events` to an app that has `route` on that path.
/// Returns the response that the app gives.
private func getEvents(
    headers: HTTPFields = [:],
    route: @escaping @Sendable (Request) -> Response
) async throws -> TestResponse {
    let router = Router()
    router.get("events") { request, _ in route(request) }
    return try await Application(router: router).test(.router) { client in
        try await client.execute(uri: "/events", method: .get, headers: headers)
    }
}

/// Returns the body of an SSE response that runs `handler`.
private func eventStream(
    _ handler: @escaping @Sendable (SSEContext) async throws -> Void
) async throws -> String {
    let response = try await getEvents { _ in Response.sse(handler) }
    return String(buffer: response.body)
}

@Suite("SSE integration with Hummingbird")
struct HummingbirdIntegrationTests {
    @Test func responseHeaders() async throws {
        let response = try await getEvents { _ in
            Response.sse { sse in
                try await sse.send("hello")
            }
        }

        #expect(response.status == .ok)
        #expect(response.headers[.contentType] == "text/event-stream")
        #expect(response.headers[.cacheControl] == "no-cache")
        // HTTP/2 does not permit the `Connection` header.
        #expect(response.headers[.connection] == nil)
    }

    @Test func stringSend() async throws {
        let body = try await eventStream { sse in
            try await sse.send("first")
            try await sse.send("second")
        }
        #expect(body == "data: first\n\ndata: second\n\n")
    }

    @Test func namedEvent() async throws {
        let body = try await eventStream { sse in
            try await sse.send(event: "ping", data: "alive")
        }
        #expect(body == "event: ping\ndata: alive\n\n")
    }

    @Test func jsonSend() async throws {
        struct Payload: Codable, Sendable {
            var count: Int
            var message: String
        }

        let body = try await eventStream { sse in
            try await sse.send(Payload(count: 42, message: "hello"))
        }
        // The default encoder sorts the keys, so the output has one possible order.
        #expect(body == "data: {\"count\":42,\"message\":\"hello\"}\n\n")
    }

    @Test func namedEventWithJSON() async throws {
        struct Update: Codable, Sendable {
            var status: String
        }

        let body = try await eventStream { sse in
            try await sse.send(event: "status", data: Update(status: "ok"))
        }
        #expect(body == "event: status\ndata: {\"status\":\"ok\"}\n\n")
    }

    @Test func customEncoder() async throws {
        struct Payload: Codable, Sendable {
            var userCount: Int
        }

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        let response = try await getEvents { _ in
            Response.sse(encoder: encoder) { sse in
                try await sse.send(Payload(userCount: 7))
            }
        }
        #expect(String(buffer: response.body) == "data: {\"user_count\":7}\n\n")
    }

    @Test func comment() async throws {
        let body = try await eventStream { sse in
            try await sse.sendComment("keep-alive")
        }
        #expect(body == ": keep-alive\n\n")
    }

    @Test func fullEvent() async throws {
        let body = try await eventStream { sse in
            try await sse.send(ServerSentEvent(
                id: "1",
                event: "message",
                data: "hello",
                retry: 3000
            ))
        }
        #expect(body == "id: 1\nevent: message\nretry: 3000\ndata: hello\n\n")
    }

    @Test func lastEventIDFromTheRequest() async throws {
        let response = try await getEvents(headers: [.lastEventID: "42"]) { request in
            let lastID = request.lastEventID ?? "none"
            return Response.sse { sse in
                try await sse.send("last-id: \(lastID)")
            }
        }
        #expect(String(buffer: response.body) == "data: last-id: 42\n\n")
    }

    @Test func lastEventIDIsNilWithoutTheHeader() async throws {
        let response = try await getEvents { request in
            let lastID = request.lastEventID ?? "none"
            return Response.sse { sse in
                try await sse.send("last-id: \(lastID)")
            }
        }
        #expect(String(buffer: response.body) == "data: last-id: none\n\n")
    }
}
#endif
