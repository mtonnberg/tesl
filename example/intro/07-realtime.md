# Real-Time Push — One Port, No Proxy

Server-Sent Events run on the same HTTP port as your REST endpoints. No WebSocket server. No nginx WebSocket proxy configuration. No reconnection logic in your backend. The browser's native `EventSource` handles reconnection automatically.

---

## Declare a typed channel

```tesl
type RoomEvent
  = NewMessage msgId: String userId: String content: String createdAt: PosixMillis
  | UserJoined userId: String username: String
  | NotifyFailed senderName: String

channel RoomMessages(roomId: String) {
  database ChatDatabase
  payload  RoomEvent
}
```

The channel is typed — you can only publish `RoomEvent` values to it. Adding a new event type means adding a variant to the ADT, and every pattern match on `RoomEvent` becomes exhaustively checked by the compiler.

---

## Publish atomically with your DB write

```tesl
handler postMessage(session: SessionUser ::: Authenticated session,
                    roomId: String ::: ValidRoomId roomId,
                    req: PostMessageRequest)
  -> Message
  requires [chatWrite, chatPubSub] =
  with transaction {
    publish RoomMessages(roomId) NewMessage {
      msgId:     generatePrefixedId "msg",
      userId:    session.id,
      content:   req.content,
      createdAt: nowMillis()
    }
    insert Message { ... }
  }
```

Publish inside a transaction: if the DB write fails, the event is never published. No "event fired but the write didn't commit" race condition.

---

## Subscribe from an SSE endpoint

```tesl
sse "/events/rooms/:roomId"
  auth    session: SessionUser ::: Authenticated session via cookieAuth
  capture roomId:  String ::: ValidRoomId roomId via roomIdCapture
  subscribe RoomMessages(roomId)
```

Auth on SSE endpoints works exactly the same as on REST — same `auth` keyword, same proof system. No second auth mechanism to maintain.

---

## On the client — no library needed

```javascript
const events = new EventSource("/events/rooms/room-123")
events.onmessage = (e) => {
  const event = JSON.parse(e.data)
  // { "tag": "NewMessage", "fields": { "content": "hello", "userId": "usr-1", ... } }
  renderMessage(event)
}
// EventSource reconnects automatically on disconnect — no application code needed
```

The ADT encoding (`{"tag": "NewMessage", "fields": {...}}`) is the same format used for HTTP responses and database storage. One wire format across the stack.

---

## Horizontal scaling

PostgreSQL `LISTEN/NOTIFY` fans events out across instances. Add a second server process → events published by one instance reach subscribers on the other. No separate message broker, no Redis Pub/Sub, no Kafka.

---

*Next: [Testing built in →](08-testing.md)*
