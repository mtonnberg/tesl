# Tesl Chat Example

A real-time chat application demonstrating Tesl's REST API, Server-Sent Events (SSE), and
queue capabilities. Two browser tabs can exchange live messages through a
SSE subscription backed by a PostgreSQL pub/sub channel, while a
background worker processes notification jobs from an atomic queue.

## Quick start

Open two terminals in the repository root:

**Terminal - a cluster of backends and frontend:**
```bash
bash example/chat/run-cluster.sh
```

Then open **two browser tabs** at `http://localhost:8080` and chat in real time.

Both scripts are self-contained — they use `nix-shell` internally, so no manual
install of Racket, Elm, nginx, or PostgreSQL is needed beyond the Nix package
manager. The nginx proxy makes frontend and API appear on the same origin
(port 8080), so the `chatUserId` cookie is sent on every request.

---

## Demo flow

1. **Open two browser tabs** at `http://localhost:8080`
2. **Tab A** — type `alice`, click **Create user** (calls `POST /users`, sets cookie)
3. **Tab B** — type `bob`, click **Create user**
4. In both tabs, click **Create room** (e.g. `general`)
5. In both tabs, enter the `general` room — the frontend connects to
   `the SSE endpoint at `http://localhost:8080/events/rooms/<id>` (proxied by nginx)
6. Type a message in Tab A and press **Send**
7. The message appears instantly in Tab B via the live SSE push

---

## Architecture

```
Browser (Elm)                          Tesl Backend                PostgreSQL
──────────────────────────────────────────────────────────────────────────────
POST /users              ──►  seedUser handler     ──►  INSERT ChatUser
POST /login              ──►  login handler        ──►  SELECT ChatUser
GET  /rooms              ──►  listRooms handler    ──►  SELECT Room
POST /rooms              ──►  createRoom handler   ──►  INSERT Room

POST /rooms/:id/messages ──►  postMessage handler
                                ├─ with transaction ─►  INSERT Message
                                ├─ publish           ──►  NOTIFY (outbox)
                                └─ enqueue           ──►  INSERT tesl_jobs

SSE /events/rooms/:id  ◄── RoomMessages channel (fan-out via LISTEN thread)

                          NotificationWorkers
                              └─► notifyWorker  ──►  SKIP LOCKED dequeue
```

**The atomic transaction in `postMessage`** ensures that if the message insert
fails, neither the pub/sub event nor the queue job will be visible. All three
operations commit together or roll back together.

---

## Key Tesl features demonstrated

| Feature | Location in backend.tesl |
|---|---|
| REST endpoints (GET/POST) | `api ChatApi { ... }` |
| Cookie authentication | `auth cookieAuth` — reads `chatUserId` cookie |
| URL capture with validation | `capture roomIdCapture` |
| Atomic transaction | `with transaction { ... }` in `postMessage` |
| Pub/sub event | `publish RoomMessages(roomId) NewMessage { ... }` |
| Background queue | `enqueue NotifyJob { ... }` |
| SSE subscription | `sse "/events/rooms/:roomId" subscribe RoomMessages(roomId)` |
| Worker function | `worker notifyWorker` + `workers NotificationWorkers` |
| GDP proof chain | `SessionUser ::: Authenticated session` flows auth → handler |
| Named DB result | `-> Room ? FromDb (Id == roomId)` — entity subject bound at callsite |
| Horizontal scaling | workers use `FOR UPDATE SKIP LOCKED`; pub/sub uses outbox + `NOTIFY` fan-out to all backends |
| LISTEN/NOTIFY | worker LISTEN thread wakes on commit; SSE LISTEN delivers to all connected clients |
| Outbox pattern | `publish` inside `with transaction` writes to `tesl_pubsub_outbox` atomically; TTL cleanup after 30 s |
| Stuck-job recovery | fallback poller resets `processing` jobs older than 10 min (handles crashed workers) |

---

## Horizontal scaling

The chat backend is designed to run as multiple identical processes behind a load balancer (e.g., in a Kubernetes cluster):

- **Messages** are handled by whichever backend receives the HTTP request.
- **SSE clients** connect to one backend process each.
- **Pub/sub fan-out**: when a message is posted, `publish RoomMessages(roomId)` writes to `tesl_pubsub_outbox`. PostgreSQL sends `NOTIFY tesl_pubsub` to ALL backend processes simultaneously. Each process's LISTEN thread reads the same outbox row (SELECT, not DELETE) and delivers to its locally connected SSE clients. **All users receive every message regardless of which backend they're connected to.**
- **Notification workers**: `enqueue NotifyJob` writes to `tesl_jobs`. All workers compete via `FOR UPDATE SKIP LOCKED` — each job is processed exactly once. Scale worker throughput with `startWorkers N NotificationWorkers with capabilities [notifyCap]`.
- **Outbox cleanup**: rows older than 30 seconds are deleted automatically. All processes have delivered them well before that.

### One-command cluster (3 instances + nginx load balancer)

```bash
bash example/chat/run-cluster.sh
```

This starts three backend instances on ports 3000, 3002, and 3004 behind an nginx
load balancer on port 8080. REST requests are round-robined; SSE connections
are routed via `ip_hash` (sticky per client IP) so each browser tab stays connected
to the same backend process. All instances share the same PostgreSQL database.

### Manual multi-instance setup

To run backends on individual ports without the cluster script:

```bash
# Terminal 1
CHAT_PORT=3000 bash example/chat/run-backend.sh

# Terminal 2
CHAT_PORT=3002 bash example/chat/run-backend.sh

# Terminal 3
CHAT_PORT=3004 bash example/chat/run-backend.sh
```

The `CHAT_PORT` environment variable controls which port each instance listens on
(default: `8080`). Each instance independently serves both static files and the
REST API.

---

## File structure

```
example/chat/
  backend.tesl                Tesl source — compiles to Racket
  backend.rkt                 Generated output (created by run-backend.sh)
  run-backend.sh              One-command backend launcher (supports CHAT_PORT)
  run-cluster.sh              Three-instance cluster + nginx load balancer
  run-frontend.sh             One-command frontend launcher (nginx reverse proxy)
  nginx.conf.template         nginx config template (single backend)
  nginx-cluster.conf.template nginx config template (three-backend cluster)
  README.md                   This file
  frontend/
    elm.json                  Elm 0.19.1 package manifest
    index.html                HTML shell with SSE JS bridge
    main.js                   Compiled Elm (created by run-frontend.sh)
    src/
      Main.elm                Complete Elm application
```

---

## Run via script

```./run-cluster.sh``

## Manual steps (if you prefer not to use the scripts)

### Backend

```bash
# From repo root, inside nix-shell:
nix-shell

# Bootstrap Racket package:
bash scripts/bootstrap-tesl-lang.sh

# Start Postgres:
bash scripts/postgres-start.sh
createdb -h 127.0.0.1 -p 55432 -U tesl chat

# Set env vars:
export CHAT_DB_NAME=chat CHAT_DB_USER=tesl CHAT_DB_PASSWORD=""
export CHAT_DB_HOST=127.0.0.1 CHAT_DB_PORT=55432
export CHAT_DB_SOCKET="$PWD/.tesl-postgres"

# Compile and run:
tesl run example/chat/backend.tesl
```

### Frontend

```bash
# Requires Elm 0.19.1 and nginx (or: nix-shell -p elmPackages.elm nginx)
cd example/chat/frontend
elm make src/Main.elm --output=main.js
# Then run nginx with a config generated from nginx.conf.template
# (see run-frontend.sh for the sed substitution and startup steps)
```
