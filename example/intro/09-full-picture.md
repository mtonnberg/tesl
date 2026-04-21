# A Complete Tesl API

Here is what a full Tesl API looks like end-to-end. This is the chat API from `example/chat/backend.tesl` — auth, database, queues, real-time events, and tests, in one coherent file.

---

## The architecture at a glance

```
ChatApi
├── Capabilities:   chatRead, chatWrite, chatPubSub, chatQueue, notifyCap
│
├── Entities:       ChatUser, Room, Message  →  PostgreSQL tables (auto-schema)
├── Database:       ChatDatabase (PostgreSQL via env vars)
│
├── Auth:           cookieAuth  →  SessionUser ::: Authenticated session
├── Validation:     checkNonEmptyString  →  String ::: NonEmpty
│                   checkRoomId          →  String ::: ValidRoomId
│
├── Queue:          NotificationQueue (PostgreSQL-backed, 3 retries, exponential backoff)
├── Channel:        RoomMessages(roomId)  →  payload RoomEvent (ADT)
│
├── Handlers:       login, listRooms, createRoom, getMessages, postMessage
├── Worker:         notifyWorker  (3 concurrent threads)
├── Dead worker:    handleDeadNotify  →  publishes NotifyFailed event on exhaustion
│
├── API endpoints:  POST /users, POST /login, GET /rooms, POST /rooms,
│                   GET /rooms/:roomId/messages, POST /rooms/:roomId/messages,
│                   SSE /events/rooms/:roomId
│
└── api-test:       auth gate, full chat flow, SSE streaming, dead-letter handling
```

---

## A handler: all the guarantees visible in the signature

```tesl
handler postMessage(
  session: SessionUser ::: Authenticated session,   # auth: proven by cookieAuth
  roomId:  String ::: ValidRoomId roomId,           # URL capture: proven by checkRoomId
  req:     PostMessageRequest                        # body: validated by codec
)
  -> exists msgId: String => Message ? FromDb (Id == msgId)
  requires [chatWrite, chatPubSub, chatQueue] =
  let msgId = generatePrefixedId "msg"
  with transaction {
    publish RoomMessages(roomId) NewMessage {
      msgId: msgId, userId: session.id,
      content: req.content, createdAt: nowMillis()
    }
    enqueue NotifyJob { senderName: session.username, roomName: roomId, content: req.content }
    exists msgId =>
      insert Message { id: msgId, roomId: roomId, userId: session.id,
                       username: session.username, content: req.content, createdAt: nowMillis() }
  }
```

The return type `exists msgId => Message ? FromDb (Id == msgId)` says: "I created a new Message and I can prove it came from a real insert." The publish, enqueue, and insert are all inside one transaction — they all commit or all roll back.

---

## The API declaration: the contract in one place

```tesl
api ChatApi {
  post "/rooms/:roomId/messages"
    auth session: SessionUser ::: Authenticated session via cookieAuth
    capture roomId: String ::: ValidRoomId roomId via roomIdCapture
    body req: PostMessageRequest
    -> exists msgId: String => Message ? FromDb (Id == msgId)

  sse "/events/rooms/:roomId"
    auth session: SessionUser ::: Authenticated session via cookieAuth
    capture roomId: String ::: ValidRoomId roomId via roomIdCapture
    subscribe RoomMessages(roomId)
}
```

Reading the API declaration tells you everything: what auth is required, what URL segments are validated and how, what the request body looks like, what the response type is. The compiler verifies every handler satisfies its declared contract.

---

## Testing the full stack in one block

```tesl
api-test "message reaches the room stream and the notification queue" for ChatServer
  requires [chatRead, chatWrite, chatPubSub, chatQueue, notifyCap] {

  seed {
    insert ChatUser { id: "usr-alice", username: "alice" }
    insert ChatUser { id: "usr-bob",   username: "bob"   }
    insert Room     { id: "room-live", name: "Live room", createdAt: 0 }
  }

  let stream = subscribe "/events/rooms/room-live" cookie "chatUserId=usr-alice"
  let _ = post "/rooms/room-live/messages"
            cookie "chatUserId=usr-bob"
            body { "content": "Hello from Bob" }

  expect pendingJobCount NotificationQueue == 1
  let job = expectJobOk (processNextJob NotificationQueue)
  expect job.senderName == "bob"

  let events = collect stream count 1 timeout 1500ms
  expect includesWhere { "tag": "NewMessage", "fields": { "content": "Hello from Bob" } } events
}
```

---

## What you get for free by writing in Tesl

| Concern | How Tesl handles it |
|---|---|
| Validation | Runs once at the boundary; proof travels with the value |
| Authentication | Compiler-enforced; missing auth is a type error |
| Side effects | Declared in `requires`, checked at every call site |
| SQL field references | Checked at compile time; SQL injection structurally impossible |
| Background jobs | Declared, PostgreSQL-backed, retry + dead-letter built in |
| Real-time events | Typed channels, atomic with DB writes, SSE on same port |
| Testing | Full HTTP boundary tests + mutation testing, no framework |
| Telemetry | Ambient; no capability needed; zero cost when not sampling |

---

*Next: [Status and what's coming →](10-status.md)*
