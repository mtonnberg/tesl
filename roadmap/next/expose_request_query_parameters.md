# Expose `request.queryParameters` on `HttpRequest`

## Goal
Allow handlers and auth functions to read URL query-string parameters via
dot-access, alongside the already-exposed `request.cookies` and
`request.headers`:

```tesl
handler search(request: HttpRequest) -> SearchResult requires [...] =
  case Dict.lookup "q" request.queryParameters of
    Nothing      -> ...
    Something qs -> ...
```

`request.queryParameters` should be a `Dict String String` (a `String`→`String`
map), mirroring the shape of `request.cookies` / `request.headers`.

## Why this is deferred (not a one-liner)
`.cookies` and `.headers` were trivial to expose because the data already lives
on the runtime request struct. Query parameters do **not**:

- `dsl-request` (`dsl/web.rkt:72`) is `(method path headers body cookies raw-request)` —
  there is **no query field**, and no query-string parsing anywhere in the runtime.
- The api-test dispatch path (`dsl/test-support.rkt` `dispatch-api-test-request`)
  builds requests with `raw-request = #f`, so there is no web-server request to
  pull bindings from. Production builds the path via `request->dsl-request`
  (`dsl/web.rkt:1134`) from `(url-path (request-uri req))`, which **discards the
  query part** today.

So this requires plumbing in three layers, not just a `register-field-access!` entry.

## Implementation sketch
1. **Runtime struct**: add a `query` field to `dsl-request` (a `String`→`String`
   hash), or parse it lazily from the URL. Prefer a struct field so both
   production and api-test paths populate it once.
2. **Production parse** (`request->dsl-request`, `dsl/web.rkt:1134`): read the
   query bindings from the web-server request (`request-bindings`/`url-query` of
   `(request-uri req)`) and build the hash.
3. **api-test parse** (`dispatch-api-test-request`, `dsl/test-support.rkt`):
   - decide how an api-test passes a query — either inline in the path string
     (`get "/search?q=foo&limit=10"`, split on `?` and parse) or a dedicated
     `query { "q": "foo" }` clause (parser + `emit_api_test_*` support).
   - The compiler currently tokenizes the path via `api-test-path-fragment`
     (`compiler/lib/emit_racket.ml:5752`) — extend it to peel off and parse the
     query segment, or add the `query { }` clause.
4. **Field access** (`dsl/web.rkt:1942`): add `queryParameters` to the
   `register-field-access!` field list and return the query hash.
5. **Docs**: LANGUAGE-SPEC + the HttpRequest reference + an api-test lesson.

## Verification
- `./compile-examples.sh` → "All good!"
- A new api-test exercising `request.queryParameters` (both present and absent).
- Round-trip: a `get "/x?a=1&a=2"` decision on repeated keys (last-wins vs list).

## Open questions
- Repeated keys (`?a=1&a=2`): last-wins `String`, or `Dict String (List String)`?
  - DECISION: last wins
- URL-decoding of values (`%20` → space) — decode on parse.
  - DECISION: Yes, decode
- Surface for api-tests: inline `?...` in the path vs an explicit `query { }`
  clause (the latter is more consistent with `cookie { }` / `body { }`).
  - DECISION: inline in path since it is part of the url
