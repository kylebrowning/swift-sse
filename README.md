# vapor-sse

Server-Sent Events (SSE) for [Vapor](https://github.com/vapor/vapor) and [Hummingbird](https://github.com/hummingbird-project/hummingbird).

The core of the `SSE` module imports no web framework. A package trait adds the API for each framework.

| Trait | Framework | Default |
|-------|-----------|---------|
| `Vapor` | Vapor 5 | Yes |
| `Hummingbird` | Hummingbird 2 | No |

## Requirements

| vapor-sse | Vapor | Hummingbird | Swift | Platforms |
|-----------|-------|-------------|-------|-----------|
| 2.x | 5.0.0-beta.4+ | 2.0.0+ | 6.4 | macOS 26.2, iOS 26.2 |
| 1.x | 4.121.3+ | Not supported | 6.0 | macOS 10.15, iOS 13 |

The Vapor API is the same in 1.x and 2.x. Vapor code for 1.x compiles on 2.x with no changes.

Vapor 5 sets the platform minimums for 2.x. These minimums also apply when you enable only the `Hummingbird` trait.

## Installation

### Vapor

Add `vapor-sse` to your `Package.swift`. The `Vapor` trait is the default.

```swift
dependencies: [
    .package(url: "https://github.com/kylebrowning/vapor-sse.git", from: "2.0.0-beta"),
],
targets: [
    .target(name: "App", dependencies: [
        .product(name: "SSE", package: "vapor-sse"),
    ]),
]
```

### Hummingbird

Enable the `Hummingbird` trait. A trait list replaces the default trait, so SwiftPM does not resolve Vapor.

```swift
dependencies: [
    .package(
        url: "https://github.com/kylebrowning/vapor-sse.git",
        from: "2.0.0-beta",
        traits: ["Hummingbird"]
    ),
],
targets: [
    .target(name: "App", dependencies: [
        .product(name: "SSE", package: "vapor-sse"),
    ]),
]
```

## Usage

The handler closure and `SSEContext` are the same in the two frameworks. Only the call that creates the response is different.

### Vapor

```swift
import Vapor
import SSE

app.get("events") { req in
    req.sse { sse in
        for i in 0..<10 {
            try await sse.send("tick \(i)")
            try await Task.sleep(for: .seconds(1))
        }
    }
}
```

`Response.sse` does the same as `req.sse`:

```swift
app.get("events") { req in
    Response.sse { sse in
        try await sse.send("hello")
    }
}
```

### Hummingbird

```swift
import Hummingbird
import SSE

let router = Router()
router.get("events") { request, context in
    Response.sse { sse in
        for i in 0..<10 {
            try await sse.send("tick \(i)")
            try await Task.sleep(for: .seconds(1))
        }
    }
}
```

The Hummingbird response has no `Connection` header, because HTTP/2 does not permit that header.

The examples that follow use Vapor. For Hummingbird, replace `req.sse` with `Response.sse`.

### Named Events

```swift
app.get("events") { req in
    req.sse { sse in
        try await sse.send(event: "ping", data: "alive")
    }
}
```

### JSON Data

Send an `Encodable` value, and the context serializes the value to JSON:

```swift
struct Status: Codable, Sendable {
    var users: Int
    var uptime: Double
}

app.get("status") { req in
    req.sse { sse in
        try await sse.send(Status(users: 42, uptime: 99.9))
        try await sse.send(event: "update", data: Status(users: 43, uptime: 100.0))
    }
}
```

If you need a different `JSONEncoder`, pass it to `sse`:

```swift
let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601

app.get("events") { req in
    req.sse(encoder: encoder) { sse in
        try await sse.send(MyPayload())
    }
}
```

### Full Control

Use `ServerSentEvent` directly for id, retry, and comments:

```swift
app.get("events") { req in
    req.sse { sse in
        try await sse.send(ServerSentEvent(
            id: "1",
            event: "message",
            data: "{\"hello\": \"world\"}",
            retry: 5000
        ))
        try await sse.sendComment("keep-alive")
    }
}
```

### Reconnect Support

When a client connects again, it sends the `Last-Event-ID` header. Read the header from the request.

Vapor:

```swift
app.get("events") { req in
    let lastID = req.lastEventID
    return req.sse { sse in
        // Resume from lastID...
    }
}
```

Hummingbird:

```swift
router.get("events") { request, context in
    let lastID = request.lastEventID
    return Response.sse { sse in
        // Resume from lastID...
    }
}
```

### Sending from several tasks

`SSEContext` is `Sendable`, so a keep-alive task can run while the handler sends the events:

```swift
app.get("events") { req in
    req.sse { sse in
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while true {
                    try await Task.sleep(for: .seconds(15))
                    try await sse.sendComment("keep-alive")
                }
            }
            for await update in updates() {
                try await sse.send(update)
            }
            group.cancelAll()
        }
    }
}
```

The context writes each event as one unit, so concurrent sends cannot mix two events. Concurrent sends have no defined order. Send events that have an `id` from one task.

`send` returns after the context writes the event. If the client disconnects, `send` throws. That error tells a handler with a long loop to stop. If you send on a context after its handler returns, `send` throws `SSEStreamClosedError`.

## API

| Type | Framework | Description |
|------|-----------|-------------|
| `ServerSentEvent` | All | SSE event model with `id`, `event`, `data`, `retry`, `comment` |
| `SSEContext` | All | Handle that sends events through an active connection |
| `SSEStreamClosedError` | All | The error that `send` throws after the stream ends |
| `HTTPField.Name.lastEventID` | All | The `Last-Event-ID` header name |
| `JSONEncoder.sse` | All | The default encoder for JSON payloads |
| `Response.sse(_:)` | Vapor, Hummingbird | Creates an SSE response |
| `Request.lastEventID` | Vapor, Hummingbird | The `Last-Event-ID` header value, if the request has one |
| `Request.sse(_:)` | Vapor | Creates an SSE response from a route handler |

## Tests

Each trait has its own tests. Select the traits when you run the tests:

```sh
swift test                             # Vapor, the default trait
swift test --traits Hummingbird        # Hummingbird only
swift test --traits Vapor,Hummingbird  # The two frameworks
```

## License

MIT. See [LICENSE](LICENSE).
