# Built-in Rate Limiting

**Discarded** because this will never work when you run several instances of the backend (which is the normal thing to do). Therefore it is no point of increasing the surface area of the language.

## Goal

Capability-based rate limiting that is declared at the function/handler level and enforced by the runtime without boilerplate.

## Proposed design

```tesl
capability apiRequests rateLimit {
  window:   60           # seconds
  maxCalls: 100
  keyBy:    session.userId
}

handler doExpensiveOperation(session: Session ::: Authenticated session, ...)
  requires [apiRequests] =
  ...
```

When `doExpensiveOperation` is called, the runtime atomically increments a counter for `session.userId` in a sliding-window store (PostgreSQL or Redis). If the limit is exceeded, the handler returns `fail 429 "rate limit exceeded"` before executing the body.

The `keyBy` expression selects which field is used as the rate-limit key — userId, IP, API key, etc.

## Scope

Medium-large. Requires:
1. New `rateLimit` capability modifier in compiler
2. Runtime rate-limit store (PostgreSQL-backed for horizontal scaling, in-memory fallback)
3. Integration with `define-handler`'s capability check machinery