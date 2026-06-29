# Lesson 24: Pub/Sub Channels and SSE Endpoints

> **Implemented — including horizontal scaling via LISTEN/NOTIFY.**
> - `publish` inside `transaction` writes to `tesl_pubsub_outbox` atomically and issues `NOTIFY tesl_pubsub` with the row ID (deferred to commit).
> - SSE connections receive events via the same in-memory listener mechanism. No separate port or nginx WebSocket proxy needed.
> - SSE clients in **any process** receive events published by any other process (via PostgreSQL LISTEN/NOTIFY + outbox).
> - `publish` outside a transaction calls listeners directly (at-most-once).
> - The in-memory fallback is active when no PostgreSQL context is present (unit tests).
>
> See `example/chat/chat-backend.tesl` and `example/learn/lesson33-sse-and-queue-tests.tesl` for complete working examples.

---

## Why SSE instead of WebSockets?

Tesl channels are **server→client only**: the server publishes events, clients receive them. Clients send messages via regular HTTP POST (the API). This is exactly what Server-Sent Events (SSE) is designed for.

| Feature | WebSockets (old) | SSE (current) |
|---|---|---|
| Direction | Bidirectional | Server→client (correct for Tesl channels) |
| Protocol | Custom `ws://` port | Standard HTTP — same port as the API |
| Reconnection | Manual | Automatic (built into EventSource) |
| Proxies | Special nginx config needed | Works through all HTTP proxies |
| HTTP/2 | No | Yes — multiplexed with API requests |
| Browser API | `new WebSocket(url)` | `new EventSource(url)` |

---

## QUICK START — just use it, no theory needed

### 1. Declare the event ADT first, then the channel

Events are typed — the `sseChannel` declaration's `payload` must be an ADT. The declaration is a folded record: `sseChannel Name(key) = SseChannel { database: D  payload: T }`.

```tesl
type UserEvent
  = ProfileUpdated bio: String
  | AvatarChanged  url: String
  | AccountDeleted

sseChannel UserEvents(userId: String ::: UserId userId) = SseChannel {
  database: MainDatabase
  payload: UserEvent
}
```

### 2. Publish events inside a handler

Use `publish ChannelName(key) VariantConstructor { fields }` to send an event. Use `transaction` for guaranteed delivery:

```tesl
handler updateProfile(userId: String ::: UserId userId, req: ProfileUpdateRequest)
  requires [dbWrite, pubsub] =
  transaction {
    update User in MainDatabase where Id == userId set { bio: req.bio }
    publish UserEvents(userId) ProfileUpdated { bio: req.bio }
  }
```

### 3. Declare an SSE endpoint

Use `sse` instead of an HTTP method in your `api` block. Use `subscribe` lines to declare which channel the connected client receives:

```tesl
api UserApi {
  sse "/events/user/:userId"
    auth    session: Session ::: Authenticated session && ChannelOwner session userId
            via sessionOwnerAuth
    capture userId: String ::: UserId userId via userIdCapture
    subscribe UserEvents(userId)
}
```

The `auth` line works exactly like HTTP endpoints. The `ChannelOwner session userId` proof prevents a user from subscribing to another user's event stream.

**No `server` binding needed** — SSE endpoints are automatically handled by the runtime.

### 4. The App root starts pub/sub automatically

No `startWebSocket ... on PORT` needed, and no explicit start call at all. Return an `App` from `main` and list your SSE channels in `App.sseChannels`:

```tesl
main() -> App requires [appService] =
  App {
    database: MainDatabase
    api: MyServer
    port: 8080
    queues: [EmailQueue]
    sseChannels: [UserEvents]
  }
```

When the App starts and SSE endpoints are registered, the runtime automatically:
1. Starts a PostgreSQL `LISTEN tesl_pubsub` connection for cross-process delivery.
2. Routes `GET /events/user/:userId` requests to the SSE handler.

Listing a channel in `App.sseChannels` activates its outbox delivery; listing a queue in `App.queues` activates its workers. Capabilities are granted at the App root, derived from `main.requires`.

### 5. Connect from the browser

Use the native `EventSource` API — no library needed:

```javascript
const events = new EventSource('/events/user/usr_123');

events.onopen = () => console.log('Connected');
events.onmessage = (e) => {
  const { channel, payload } = JSON.parse(e.data);
  if (payload.tag === 'ProfileUpdated') {
    updateBio(payload.bio);
  }
};
// Reconnects automatically on disconnect — no manual reconnect logic needed
```

### 6. No server entry needed for SSE endpoints

HTTP endpoints appear in both `api` and `server`. SSE endpoints appear only in `api` — the runtime handles routing automatically. Do not add SSE endpoints to `server`.

---

## Wire format

Each event arrives as a single SSE `data:` line containing JSON:

```
data: {"channel":"UserEvents","payload":{"tag":"ProfileUpdated","bio":"New bio"}}

```

The client dispatches on `payload.tag`:

```javascript
events.onmessage = (e) => {
  const { channel, payload } = JSON.parse(e.data);
  switch (payload.tag) {
    case 'ProfileUpdated': ...; break;
    case 'AvatarChanged':  ...; break;
    case 'AccountDeleted': ...; break;
  }
};
```

Every 10 seconds a `: heartbeat` comment line is sent to keep the connection alive through proxies. An initial `: ok` comment is sent immediately on connect so the browser fires `onopen` without waiting for the first heartbeat. The `EventSource` API ignores both automatically.

---

## UNDERSTANDING — what is actually happening

### The outbox pattern: durable event delivery

When `publish` runs inside `transaction`:

1. The event payload is serialized to JSON and inserted into `tesl_pubsub_outbox`.
2. `SELECT pg_notify('tesl_pubsub', row_id)` is issued. PostgreSQL defers this NOTIFY to commit.
3. If the transaction rolls back, both the outbox row and the NOTIFY are discarded.
4. On commit, PostgreSQL broadcasts the NOTIFY to all processes running `LISTEN tesl_pubsub`.
5. Each SSE server's LISTEN thread fetches the outbox row, delivers to in-memory listeners.
6. A 5-second fallback poller sweeps for rows where NOTIFY was dropped.

### Multiple `subscribe` lines

A single SSE endpoint can subscribe to multiple channels:

```tesl
sse "/events/user/:userId"
  auth    session: Session ::: Authenticated session && ChannelOwner session userId
          via sessionOwnerAuth
  capture userId: String ::: UserId userId via userIdCapture
  subscribe UserEvents(userId)
  subscribe SystemAlerts(userId)
```

Each message includes a `"channel"` discriminant so the client routes it correctly:

```json
{ "channel": "UserEvents",    "payload": { "tag": "ProfileUpdated", "bio": "..." } }
{ "channel": "SystemAlerts",  "payload": { "tag": "MaintenanceAlert", "message": "..." } }
```

### SSE path convention

The path before the `:capture` segment becomes the routing prefix. For:

```tesl
sse "/events/user/:userId"
```

The server matches `GET /events/user/<anything>` and uses `<anything>` as the channel key.

### Horizontal scaling

Ten thousand concurrent SSE clients across five backend processes means five LISTEN connections (one per process). PostgreSQL broadcasts each NOTIFY to all five. Each backend independently delivers to its ~2,000 local clients.

Outbox rows are shared (SELECT, not DELETE), so all backends read the same row. TTL-based cleanup (default 30 seconds) deletes rows after all backends have had time to deliver them.

---

## THEORY — SSE vs WebSockets

### Why SSE is better for Tesl channels

Tesl channels are **unidirectional** by design: the server publishes events, clients consume them. Clients send data via regular HTTP POST endpoints. This matches SSE exactly.

WebSockets provide bidirectional communication — but Tesl's architecture deliberately separates "client sends data" (HTTP POST) from "server sends events" (SSE). This separation is intentional:

- HTTP endpoints benefit from all standard middleware (auth, caching, rate limiting)
- SSE connections are simple long-lived GET requests — no custom protocol overhead
- The same nginx/caddy config that handles the API handles SSE with no changes

### Connection limit non-issue

HTTP/1.1 browsers limit SSE connections to 6 per domain. This is solved automatically by HTTP/2 multiplexing, which is standard in any modern reverse proxy (nginx, caddy, Cloudflare). A single HTTP/2 connection carries hundreds of simultaneous SSE streams.

### Automatic reconnection

`EventSource` reconnects automatically after any network interruption — with an exponential backoff. When it reconnects, the SSE stream resumes. The client receives the same `data:` events as before (any events published while disconnected will be delivered when the connection re-establishes and the fallback sweep runs).

---

## Capabilities

The `pubsub` capability from `Tesl.Queue` gates publishing:

- `publish` requires `pubsub`.
- SSE endpoint subscription requires `pubsub` (held by the runtime connection handler).

Application capabilities imply `pubsub` with `implies`:

```tesl
capability userEvents implies pubsub
```

---

See `example/learn/lesson23-queues-and-workers.md` for background job queues, and `example/chat/chat-backend.tesl` and `example/learn/lesson33-sse-and-queue-tests.tesl` for complete working examples.
