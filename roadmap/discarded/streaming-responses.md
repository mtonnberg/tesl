# Streaming Responses

## SSE for channels — Implemented

Server-Sent Events for pub/sub channels are implemented. See `future-roadmap/completed/migrate_to_sse.md` and lesson 24.

## What remains: general-purpose streaming

The `sse` endpoint currently streams **channel events** only. The remaining use cases for streaming:

### 1. Streaming arbitrary computed data

A handler that generates data incrementally (e.g. a large report, AI token stream, or log tail) and wants to stream it to the client without buffering everything in memory first.

```tesl
api ReportApi {
  get "/reports/:id/stream"
    capture id: String ::: ReportId id via reportIdCapture
    auth    session: Session ::: Authenticated session via sessionAuth
    ->      Stream ReportChunk
}

handler streamReport(id: String ::: ReportId id) requires [dbRead] =
  let chunks = generateReportChunks(id)
  stream chunks
```

### 2. Large file / binary downloads

Streaming a file from database or object storage without loading it all into RAM.

### 3. HTTP chunked transfer (non-SSE)

For binary formats or non-event streaming.

## Design considerations

- `Stream T` as a new return type in the compiler
- `stream expr` built-in statement in function bodies
- Handler returns `response/output` (already supported in Racket web-server) instead of `dsl-response`
- The `dispatch-request` → `serve` boundary already handles `response/output` (introduced for SSE)

## Scope

Medium. The infrastructure (response/output in serve) is already in place from the SSE implementation. The main work is compiler support for `Stream T` return types and the `stream` built-in.
