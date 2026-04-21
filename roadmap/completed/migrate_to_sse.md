# Migrate from WebSockets to SSE

> **Implemented** — Tesl channels now use Server-Sent Events (SSE) instead of WebSockets.

## What changed

| Feature | Before (WebSockets) | After (SSE) |
|---|---|---|
| Tesl syntax | `websocket "/ws/path"` | `sse "/events/path"` |
| Server startup | `startWebSocket Chan on PORT` | Automatic inside `serve` |
| Separate port | Yes (e.g. 3001) | No — same port as HTTP API |
| nginx config | WebSocket proxy needed | No changes needed |
| Client API | `new WebSocket("ws://...")` | `new EventSource("/events/...")` |
| Reconnection | Manual | Automatic (built into EventSource) |
| Protocol | RFC 6455 TCP | Standard HTTP `text/event-stream` |
| HTTP/2 | No | Yes — multiplexed |

## Why the change is correct

Tesl channels are **server→client only**: clients send data via regular POST endpoints, the server pushes events via the channel. This is exactly what SSE is designed for. WebSockets provided bidirectional capability that was never used.

## Backward compatibility

The `websocket` keyword is still accepted as a deprecated alias for `sse`. A linter warning is emitted. Code using `startWebSocket ... on PORT` should remove that call (it becomes a no-op with a warning).

## Files changed

- `tesl/sse.rkt` — new SSE connection handler (replaces `tesl/websocket.rkt`)
- `tesl/websocket.rkt` — deleted
- `dsl/web.rkt` — SSE routing in `serve`, `find-sse-match`, `handle-sse-request`
- `compile_thsl.py` — `sse` keyword, `emit_api_form` emits `ServerName-sse-routes`, `compile_serve` passes `#:sse-routes`
- `example/chat/backend.tesl` — `websocket` → `sse`, removed `startWebSocket`
- `example/chat/frontend/index.html` — `WebSocket` → `EventSource`
- `example/learn/lesson24-pubsub-sse.md` — updated lesson (was `lesson24-pubsub-websockets.md`)
- `LANGUAGE-SPEC.md` — section 11.11 updated, `startWebSocket` removed from 11.13
