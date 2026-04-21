# API Tests — Tracks A and B

## Problem

Tesl currently has two test layers:

1. **`test` blocks in `.tesl` files** — test pure functions, `check`/`proof` functions, and
   property-based invariants. Great for unit-level contracts, but cannot exercise the HTTP
   boundary: no routing, no auth, no codec serialization, no DB interaction.
2. **Racket-level tests in `tesl-test.rkt`** — use `dispatch-with-server` / `make-request` to
   fire real HTTP requests against a compiled server object. These exist and work, but they are
   written in Racket, not Tesl. Users cannot write API tests without leaving the language.

**The gap**: there is no way to write *"POST /books returns 201 and the response body contains an
`id` field"* in Tesl syntax. The entire flow — routing → codec → auth → handler → DB →
response serialization — is untestable from within the language.

---

## Design principles

**Raw JSON at the boundary.** Both request bodies and response bodies are raw JSON values — not
Tesl typed records. This is a deliberate design choice, not a limitation.

The purpose of api-tests is to verify what the type system *cannot* catch: that the codec
correctly serializes and deserializes, that the routing dispatches to the right handler, that
the auth middleware rejects unauthenticated requests, and that the exact JSON wire format the
server produces matches what clients expect. If a type error could prevent the bug, there would
be no need for a test. Raw JSON bodies also make api-tests platform-agnostic — the same test
file can in principle run against any HTTP server, not just the Tesl-compiled one.

**Two flavors in total.** Example-based tests (this document) and load/performance tests
(`roadmap/next/04-api-test-load-tests.md`). Property-based tests are not included: without
typed structure on the request body there is no schema for a generator to exploit, and
arbitrary random JSON will be rejected by most endpoints with 400s. Property-based HTTP
testing is deferred until a structured approach exists.

**Fully independent tests.** Each `api-test` block starts with a clean in-memory database. Tests
do not share state. This is the only sane default — shared mutable state between tests is the
primary cause of flaky test suites.

---

## Syntax

### Example-based tests

```tesl
api-test "create and retrieve book" for BookServer
  requires [dbWrite, time] {
  seed {
    insert User {
      id:        "user-alice",
      email:     "alice@example.com",
      role:      Admin,
      createdAt: nowMillis()
    }
  }

  let create = post "/books"
                 cookie "session=user-alice"
                 body { "title": "SICP", "authorId": "author-id3" }
  expect create.status == 201
  let bookId = create.body.id

  let fetch = get "/books/{bookId}" cookie "session=user-alice"
  expect fetch.status == 200
  expect fetch.body.title == "SICP"

  let list = get "/books" cookie "session=user-alice"
  expect list.status == 200
  expect list.body |> includesWhere { "id": bookId }
}

api-test "missing auth returns 401" for BookServer {
  let r = get "/books"
  expect r.status == 401
}

api-test "malformed body returns 400" for BookServer
  requires [dbWrite, time] {
  seed {
    insert User {
      id:        "user-alice",
      email:     "alice@example.com",
      role:      Admin,
      createdAt: nowMillis()
    }
  }
  let r = post "/books"
            cookie "session=user-alice"
            body { "title": "" }
  expect r.status == 400
}
```

---

## Request builder syntax

Inside `api-test` and `load-test` blocks, the request builder sub-syntax is:

```
get    PATH [cookie STRING] [headers { STRING: STRING, ... }]
post   PATH [cookie STRING] [headers { STRING: STRING, ... }] [body JSON]
put    PATH [cookie STRING] [headers { STRING: STRING, ... }] [body JSON]
delete PATH [cookie STRING] [headers { STRING: STRING, ... }]
```

**`PATH`** is a string literal. `{varName}` interpolation substitutes a value bound earlier in
the same `api-test` block. Rules:

- The interpolated value must be a `String`. Any other type is a compile error. To interpolate
  a non-string, convert explicitly: `"/items/{Int.toString(itemId)}"`.
- The substituted string is percent-encoded automatically, so values containing `/`, `?`, or
  `%` are safe to interpolate.
- Referencing a name not yet `let`-bound in the block is a compile error, not a runtime error.

**`body JSON`** is a JSON literal — the same syntax as Tesl record literals but untyped. Keys
must be quoted strings. Any valid JSON value is accepted: objects, arrays, strings, numbers,
booleans, null. There is no `rawBody` variant; body is always raw JSON.

**`cookie STRING`** sets the `Cookie` request header. For cookie-based auth this is sufficient.
For bearer tokens or custom headers use `headers { "Authorization": "Bearer {token}" }`.

---

## Response type

Every request expression returns an `HttpResponse`:

```
HttpResponse {
  status:  Int
  body:    JsonValue
  headers: Dict String String
}
```

`HttpResponse` and its field names are fixed and compiler-known. The compiler checks that
`resp.status`, `resp.body`, and `resp.headers` are valid accesses — misspelling `.stats` is a
compile error.

`JsonValue` is the deliberate name for the body type. It communicates clearly that the body is
dynamic, untyped JSON — not a Tesl record. Accessing a field on a `JsonValue` (`resp.body.id`,
`resp.body.items`) is a dynamic access. The compiler does not check field names against any
schema. A missing field returns `JsonNull` at runtime rather than crashing, so
`expect resp.body.id != JsonNull` is the idiomatic way to assert field presence.

`JsonValue` is not available as a user-writeable type annotation elsewhere in Tesl. It only
appears as the type of `HttpResponse.body` inside `api-test` blocks, making clear that this
escape hatch is local to the testing layer.

---

## State isolation

Every `api-test` block runs against a fresh in-memory database. The database capability is
swapped for a clean in-memory store at the start of each block and discarded at the end.

### `seed { }` — pre-population before the DB is live

For tests that need existing records (users for auth, reference data), a `seed { }` block runs
before the in-memory DB is activated and populates it directly — bypassing the HTTP stack. This
avoids the circular dependency where auth endpoints need DB users but the DB starts empty.

**Seed blocks use the standard Tesl `insert` syntax**, identical to what you write inside
handlers. The compiler applies the same checks: field names are resolved against the entity
declaration, field types are verified, and every non-nullable field without a default must be
present. This means a schema change — adding a required column, renaming a field, removing a
field — immediately breaks every seed block that is now out of date, at compile time, before
any test runs.

```tesl
api-test "..." for MyServer {
  seed {
    let aliceId = "user-alice"
    insert User {
      id:        aliceId,
      email:     "alice@example.com",
      role:      Admin,
      createdAt: nowMillis()
    }
    insert User {
      id:        "user-bob",
      email:     "bob@example.com",
      role:      Member,
      createdAt: nowMillis()
    }
    insert Membership {
      userId: aliceId,
      orgId:  "org-1",
      since:  nowMillis()
    }
  }
  ...
}
```

**Seed blocks declare capabilities like any other function with side effects.** The required
capabilities depend on what the seed body uses: `dbWrite` for `insert`, `random` if
`generatePrefixedId` is called, `time` if `nowMillis()` is called. Capabilities are declared
on the enclosing `api-test` block:

```tesl
api-test "..." for MyServer
  requires [dbWrite, random, time] {
  seed {
    insert User {
      id:        generatePrefixedId("user"),
      email:     "alice@example.com",
      role:      Admin,
      createdAt: nowMillis()
    }
  }
  ...
}
```

The same `requires` covers capabilities needed anywhere in the block — seed, test body, or
load loop. The compiler checks them the same way it checks handler capabilities.

**What is allowed in a seed block:**

- `insert Entity { ... }` — standard SQL insert; the proof/existential return value is
  discarded (you do not need `exists id =>` in a seed context)
- `let name = expr` — value bindings for constructing related records that reference each
  other (as shown with `aliceId` above)
- Any expression that the declared capabilities permit: string and number literals, ADT
  constructors, `generatePrefixedId()` (requires `random`), `nowMillis()` (requires `time`),
  arithmetic, string operations

**What is not allowed in a seed block:**

- HTTP calls (`get`, `post`, etc.) — seed runs before the HTTP layer is active
- `expect` assertions — seed is setup, not verification
- `select`, `update`, `delete` — seed is append-only by design; querying in setup is a
  smell that the test structure needs rethinking

### Auth warm-up is just the start of the test body

There is no separate `setup { }` block. If a test needs to obtain a token before running its
assertions, that login call is simply the first step in the test body — a plain `let` binding
like any other:

```tesl
api-test "authenticated flow with JWT" for MyServer
  requires [dbWrite, time] {
  seed {
    insert User {
      id:           "user-alice",
      email:        "alice@example.com",
      passwordHash: "hashed-s3cr3t",
      role:         Member,
      createdAt:    nowMillis()
    }
  }

  let loginResp = post "/login" body { "user": "alice", "pass": "s3cr3t" }
  expect loginResp.status == 200
  let token = loginResp.body.token

  let r = get "/profile" headers { "Authorization": "Bearer {token}" }
  expect r.status == 200
}
```

The scoping is ordinary and visible: `token` is bound on line 7 and used on line 9, exactly
like any other `let` binding in Tesl. There is no magic and nothing to learn about a special
scope rule.

### Real Postgres (`--test-db`)

When `tesl test --test-db` is passed, each `api-test` block wraps its requests in a database
transaction that is rolled back at the end instead of using the in-memory store. The `seed { }`
block inserts into the same transaction before the test body runs, using exactly the same
compiled SQL that handlers use — no special seed-specific SQL generation needed.

The `--test-db` flag is set at the CLI level, not per test block. The same test file runs
against both backends.

---

## The `http` capability — outbound HTTP in production and tests

Tesl handlers and workers sometimes need to make outbound HTTP calls: triggering a webhook
after an order is placed, calling a payment gateway from a checkout handler, notifying a
third-party service from a queue worker. These are side effects and must be governed by a
capability.

The `http` capability gates all outbound HTTP calls. It is declared and composed exactly like
any other capability:

```tesl
capability notifyWebhook implies http

worker deliveryWorker(job: DeliveryJob ::: FromQueue ...)
  requires [dbWrite, notifyWebhook] =
  let resp = Http.post "https://hooks.example.com/delivery"
               body { "orderId": job.orderId, "status": "shipped" }
               codec WebhookResponse
  case resp.status of
    200 -> update ...
    _   -> fail 500 "webhook rejected delivery notification"
```

`Http.post`, `Http.get`, `Http.put`, `Http.delete` are the production outbound HTTP functions.
They accept a full URL and an optional `codec T` clause that decodes the response body into a
typed Tesl value using `T`'s `fromJson` codec. The response type is `HttpResponse T` where
`T` is the decoded body type — fully typed, checked by the compiler.

**The distinction from api-test HTTP calls.** Inside `api-test` blocks, `get "/path"` and
`post "/path"` dispatch internally to the server under test — they are not outbound network
calls and do not require the `http` capability. The response body is always `JsonValue`
(raw JSON) because the test is verifying the wire contract, not consuming a typed API.

In production code (`Http.post "https://..."`) the response body is typed by the codec
because the production code is a consumer of the API and should work with proper types.

```
                      Production code          Test code
────────────────────────────────────────────────────────
Syntax                Http.post "https://..."  post "/path"
Needs http cap        yes                      no (internal dispatch)
Response body type    T (codec-decoded)        JsonValue (raw JSON)
Purpose               call external service    test server under test
```

`http` is declared in `Tesl.Http` alongside `HttpRequest`. Queue workers and handlers that
call external services import and declare it; api-test blocks never need it for their own
internal dispatch.

---

## Imports

Any file containing `api-test` or `load-test` blocks must import `Tesl.ApiTest`:

```tesl
import Tesl.ApiTest exposing [
  # response types
  HttpResponse, JsonValue, JsonNull,
  # status helpers
  statusOk, statusClientError, statusServerError,
  # JSON extraction
  jsonInt, jsonString, jsonBool, jsonArray, jsonObject,
  jsonLength, isNull, isNotNull,
  # array assertions
  includesWhere, excludesWhere, hasLength, isEmpty, isNotEmpty, arrayAt,
  # object helpers
  hasField, fieldAt, bodyField, jsonContains,
  # SSE
  SseStream, subscribe, collect,
  # queue / worker
  JobResult(..), processNextJob, processNextDeadJob, drainQueue, pendingJobCount,
  expectJobOk, expectJobFailed,
]
```

`JobResult(..)` imports the ADT and both constructors (`JobOk`, `JobFailed`) for use in
`case` expressions.

`Tesl.ApiTest` is the single source for everything api-test-specific. Nothing from this module
is available by default — it must be imported explicitly.

The compiler emits a targeted error if an `api-test` block is present but `Tesl.ApiTest` is not
imported:

```
api-test block requires `import Tesl.ApiTest exposing [...]`
hint: add the import at the top of the file
```

---

## Assertion helpers

### JSON equality and comparisons

`JsonValue` compares directly to Tesl primitive values with `==` and `!=`. The runtime checks
the JSON type and fails with a clear message on mismatch:

```tesl
expect resp.body.title == "SICP"      # JsonValue == String
expect resp.body.count == 5           # JsonValue == Int
expect resp.body.active == true       # JsonValue == Bool
expect resp.body.deletedAt == JsonNull  # explicit null check
```

On type mismatch the failure message names the types:

```
expected String "SICP" but body field "title" contains Int 42
```

Ordering operators (`<`, `>`, `<=`, `>=`) also work between `JsonValue` and `Int`.

---

### Status helpers

**`statusOk resp`**

Passes if `resp.status` is 200–299. Prefer `expect resp.status == 201` for specific codes;
use `statusOk` when any success code is acceptable.

**`statusClientError resp`**

Passes if `resp.status` is 400–499. Useful when testing that a request is rejected without
caring which 4xx code is returned.

**`statusServerError resp`**

Passes if `resp.status` is 500–599.

---

### JSON extraction

These functions extract a typed Tesl value from a `JsonValue`. They fail with a clear error if
the JSON value is not of the expected type.

**`jsonInt v`** → `Int`

```tesl
expect jsonInt(resp.body.count) > 0
```

**`jsonString v`** → `String`

```tesl
let id = jsonString(resp.body.id)
let fetch = get "/items/{id}"
```

**`jsonBool v`** → `Bool`

```tesl
expect jsonBool(resp.body.active) == true
```

**`jsonArray v`** → `List JsonValue`

```tesl
let items = jsonArray(resp.body.items)
expect List.length(items) == 3
```

**`jsonObject v`** → `Dict String JsonValue`

```tesl
let user = jsonObject(resp.body.user)
```

**`jsonLength v`** → `Int`

Returns the length of a JSON array or the number of keys in a JSON object. Fails if the
value is neither.

```tesl
expect jsonLength(resp.body.items) == 5
```

---

### Null checks

**`isNull v`** → `Bool`

```tesl
expect isNull(resp.body.deletedAt)
```

**`isNotNull v`** → `Bool`

```tesl
expect isNotNull(resp.body.id)
```

---

### Array assertions

**`includesWhere { "field": value, ... } jsonArray`**

Passes if at least one element of the JSON array has all the specified fields equal to the
specified values.

**Failure behaviour:** if the field is not present on an element, fails immediately with a
descriptive error rather than silently treating the element as a non-match:

```
includesWhere: looking for field "id" but element does not have it
element: {"title": "SICP", "authorId": "id3"}
tip: did you mean one of: "title", "authorId"?
```

If the input is not a JSON array:

```
includesWhere: expected a JSON array, got Object {"id": "x", "title": "y"}
```

Multiple fields: `includesWhere { "id": bookId, "title": "SICP" }` — all must match.

**`excludesWhere { "field": value, ... } jsonArray`**

Passes if no element matches all specified fields. Same error behaviour as `includesWhere`.

**`hasLength n jsonValue`**

Passes if the JSON array (or object) has exactly `n` elements.

```tesl
expect hasLength(3, resp.body.items)
```

**`isEmpty jsonValue`**

Passes if the JSON array or object has zero elements.

**`isNotEmpty jsonValue`**

Passes if the JSON array or object has at least one element.

**`arrayAt n jsonValue`** → `JsonValue`

Returns the element at zero-based index `n`. Fails with a clear error if the index is out of
range or the value is not an array.

```tesl
expect arrayAt(0, resp.body.items).id == "item-1"
```

---

### Object helpers

**`hasField "name" jsonValue`** → `Bool`

```tesl
expect hasField("id", resp.body)
expect hasField("error", resp.body) == false
```

**`fieldAt "name" jsonValue`** → `JsonValue`

Extracts a field from a JSON object by name. Fails with a clear error (printing the object)
if the field is not present. Equivalent to dot notation but usable where a programmatic name
is needed:

```tesl
let fieldName = "title"
expect fieldAt(fieldName, resp.body) == "SICP"
```

**`bodyField "name" resp`**

Shorthand for `fieldAt "name" resp.body`. Useful in pipelines:

```tesl
expect resp |> bodyField "items" |> includesWhere { "id": bookId }
```

---

### String matching

**`jsonContains substring jsonValue`**

Passes if the `JsonValue` is a string containing `substring`.

```tesl
expect jsonContains("alice", resp.body.email)
```

Fails clearly if the value is not a JSON string.

---

## SSE testing

SSE endpoints produce a stream of events. Testing them requires two things to happen
concurrently: a subscription that listens, and an HTTP action that triggers events. The design
handles this with a two-step model:

1. `subscribe` opens the SSE connection and returns a handle immediately — it does not block.
   Events arriving after this point are buffered in the handle.
2. The test body performs HTTP actions.
3. `collect` drains the handle, blocking until the desired number of events arrives or the
   timeout expires.

Because the subscription is opened before the triggering action, there is no race condition.

### `subscribe` — open a stream

```
subscribe PATH [cookie STRING] [headers { STRING: STRING, ... }]
```

Returns an `SseStream` handle. The connection is established synchronously before the
expression returns (the server sends the HTTP 200 and the initial headers), so any events
published after this line are guaranteed to be buffered.

```tesl
let aliceStream = subscribe "/events/rooms/room-general" cookie "session=user-alice"
```

Multiple subscriptions can be open simultaneously — each is a separate named handle:

```tesl
let aliceStream = subscribe "/events/inbox/user-alice" cookie "session=user-alice"
let bobStream   = subscribe "/events/inbox/user-bob"   cookie "session=user-bob"
```

This is how "multiple clients" work — there is no special `client` block, just multiple
`SseStream` handles in the same test body.

### `collect` — wait for events

```
collect HANDLE [count N] [until { JSON-PATTERN }] [timeout DURATION]
```

Returns `List JsonValue` — the events received, each as the parsed JSON payload of one SSE
`data:` line.

**`count N`** — wait until at least N events have arrived, then return all buffered events.
Default is 1 if neither `count` nor `until` is specified.

**`until { JSON-PATTERN }`** — wait until an event matching the pattern arrives, then return
all buffered events up to and including that event. Useful when you don't know exactly how many
events precede the one you care about.

**`timeout DURATION`** — maximum time to wait. If the timeout expires before the condition is
met, the test fails with a clear message showing what was received:

```
collect: timed out after 3s waiting for count 1
received 0 events on stream "/events/rooms/room-1"
hint: did the action that produces events run successfully?
```

**Timeout is required** whenever `count` or `until` is specified — there is no default timeout
that silently hangs a test. The syntax enforces this at parse time.

**Collecting to assert no events** — use `timeout` alone to gather everything that arrives
within a window:

```tesl
let events = collect aliceStream timeout 500ms
expect isEmpty(events)   # nothing should have been published
```

### SSE examples

**Basic: one client receives an event triggered by an HTTP action**

```tesl
api-test "new message appears in room stream" for ChatServer
  requires [dbWrite, time] {
  seed {
    insert User {
      id:        "user-alice",
      email:     "alice@example.com",
      role:      Member,
      createdAt: nowMillis()
    }
    insert User {
      id:        "user-bob",
      email:     "bob@example.com",
      role:      Member,
      createdAt: nowMillis()
    }
    insert Room {
      id:        "room-general",
      name:      "General",
      createdAt: nowMillis()
    }
  }

  let aliceStream = subscribe "/events/rooms/room-general" cookie "session=user-alice"

  let msg = post "/rooms/room-general/messages"
              cookie "session=user-bob"
              body { "content": "Hello!" }
  expect msg.status == 201

  let events = collect aliceStream count 1 timeout 3s
  expect isNotEmpty(events)
  expect events |> includesWhere { "type": "NewMessage", "content": "Hello!" }
}
```

**Two clients: only the intended recipient receives the event**

```tesl
api-test "direct message only reaches recipient" for ChatServer
  requires [dbWrite, time] {
  seed {
    insert User {
      id:        "user-alice",
      email:     "alice@example.com",
      role:      Member,
      createdAt: nowMillis()
    }
    insert User {
      id:        "user-bob",
      email:     "bob@example.com",
      role:      Member,
      createdAt: nowMillis()
    }
    insert User {
      id:        "user-carol",
      email:     "carol@example.com",
      role:      Member,
      createdAt: nowMillis()
    }
  }

  let aliceStream = subscribe "/events/inbox/user-alice" cookie "session=user-alice"
  let carolStream = subscribe "/events/inbox/user-carol" cookie "session=user-carol"

  let dm = post "/messages"
             cookie "session=user-bob"
             body { "to": "user-alice", "text": "Hey Alice" }
  expect dm.status == 201

  # Alice gets the message
  let aliceEvents = collect aliceStream count 1 timeout 3s
  expect aliceEvents |> includesWhere { "type": "DirectMessage", "from": "user-bob" }

  # Carol receives nothing
  let carolEvents = collect carolStream timeout 500ms
  expect isEmpty(carolEvents)
}
```

**`until` pattern: wait for a specific event in a noisy stream**

```tesl
api-test "processing-complete event arrives after async work" for WorkServer
  requires [dbWrite, time] {
  seed {
    insert User {
      id:        "user-alice",
      email:     "alice@example.com",
      role:      Member,
      createdAt: nowMillis()
    }
  }

  let progressStream = subscribe "/events/jobs" cookie "session=user-alice"

  let job = post "/jobs/start" cookie "session=user-alice" body { "type": "export" }
  expect job.status == 202
  let jobId = job.body.id

  # Wait for the Done event specifically — intermediate Progress events are fine
  let events = collect progressStream
                 until { "type": "Done", "jobId": jobId }
                 timeout 10s
  let last = arrayAt(jsonLength(events) - 1, events)
  expect last.type == "Done"
  expect last.status == "success"
}
```

---

## Queue and worker testing

Workers consume jobs asynchronously in production. In tests, workers are run synchronously
and on-demand — the test controls when each job is processed. This gives deterministic,
reproducible tests with no timing sensitivity.

### `JobResult` — the ADT returned by all job-processing functions

```tesl
type JobResult
  = JobOk     job: JsonValue
  | JobFailed job: JsonValue  error: JsonValue
```

Both variants carry `job` — the full input payload that was dequeued. This lets a single
`processNextJob` call verify both that the right job was enqueued and that the worker handled
it correctly:

```tesl
case processNextJob EmailQueue of
  JobOk job ->
    expect job.to == "alice@example.com"
    expect job.subject |> jsonContains "Welcome"
  JobFailed job error ->
    fail "expected success but worker failed"
```

Because `JobResult` is an ADT, the compiler enforces exhaustive handling of both variants.

**Convenience helpers** for the common cases where you expect a specific outcome and want
the test to fail immediately with a clear message if it doesn't:

`expectJobOk result` → `JsonValue` (the job payload)
Fails the test if the result is `JobFailed`, printing the error.

`expectJobFailed result` → `JsonValue` (the error payload)
Fails the test if the result is `JobOk`, printing the job payload.

```tesl
let job = expectJobOk(processNextJob EmailQueue)
expect job.to == "alice@example.com"
```

There is no `JobEmpty` variant. `processNextJob` and `processNextDeadJob` fail the test
immediately if the queue is empty — you call them when you assert a job exists:

```
processNextJob: queue EmailQueue is empty — expected at least one pending job
hint: did the HTTP action that enqueues the job run and return a success status?
```

### `processNextJob QUEUE_NAME` — run one job

Dequeues the next pending job and runs its worker synchronously. Returns `JobResult`. Fails
the test immediately if the queue is empty.

```tesl
let result = processNextJob NotificationQueue
case result of
  JobOk job ->
    expect job.userId == "alice"
  JobFailed job error ->
    fail "notification job failed"
```

### `processNextDeadJob QUEUE_NAME` — run one dead-letter job

Same as `processNextJob` but operates on the dead-letter queue. Runs the `deadWorker`
registered for that queue. Fails the test immediately if the dead-letter queue is empty.

```tesl
let result = processNextDeadJob NotificationQueue
let job = expectJobOk(result)
expect job.userId == "alice"
```

### `drainQueue QUEUE_NAME` — process all pending jobs

Runs `processNextJob` in a loop until the queue is empty. Returns `List JobResult`. An empty
list is a valid result (zero jobs is fine here — unlike `processNextJob`, draining nothing is
not an assertion failure).

**`drainQueue` has a safety limit** of 1000 jobs. If jobs remain after 1000 iterations the
test fails — this prevents infinite loops when a worker re-enqueues jobs.

```tesl
let results = drainQueue NotificationQueue
expect List.all(lambda r => case r of
  JobOk _ -> true
  JobFailed _ _ -> false, results)
```

Or using the helper:

```tesl
# fails immediately if any job failed, showing the error
List.map(expectJobOk, drainQueue NotificationQueue)
```

### `pendingJobCount QUEUE_NAME` — inspect queue depth

Returns `Int`. Useful when you want to assert on the number of enqueued jobs before deciding
how many times to call `processNextJob`:

```tesl
expect pendingJobCount(NotificationQueue) == 2
```

### Queue examples

**Verify both input payload and worker success**

```tesl
api-test "user registration sends welcome email" for AppServer
  requires [dbWrite, random, time] {
  let reg = post "/register"
              body { "email": "alice@example.com", "password": "s3cr3t" }
  expect reg.status == 201

  let job = expectJobOk(processNextJob EmailQueue)
  expect job.to      == "alice@example.com"
  expect job.subject |> jsonContains "Welcome"
}
```

**Verify a job fails when expected and the error payload is informative**

```tesl
api-test "invalid recipient causes worker failure" for AppServer
  requires [dbWrite, time] {
  seed {
    insert User {
      id:        "user-alice",
      email:     "alice@example.com",
      role:      Admin,
      createdAt: nowMillis()
    }
  }

  # Enqueue a job pointing to a non-existent user
  post "/admin/send-notice"
    cookie "session=user-alice"
    body { "to": "ghost@nowhere.com", "message": "Hello" }

  let result = processNextJob EmailQueue
  let error = expectJobFailed(result)
  expect error.reason |> jsonContains "recipient not found"
}
```

**Exhaust retries and handle the dead-letter job**

```tesl
api-test "exhausted retries move job to dead-letter" for AppServer
  requires [dbWrite, time] {
  seed {
    insert User {
      id:        "user-alice",
      email:     "alice@example.com",
      role:      Member,
      createdAt: nowMillis()
    }
    # External service intentionally not seeded — worker calls will fail
  }

  post "/sync/start" cookie "session=user-alice" body {}

  # Exhaust all retry attempts (maxAttempts: 3 in queue declaration)
  # Discard results — we expect all three to fail
  processNextJob SyncQueue   # attempt 1 — fails, re-enqueued
  processNextJob SyncQueue   # attempt 2 — fails, re-enqueued
  processNextJob SyncQueue   # attempt 3 — fails, moves to dead-letter

  expect pendingJobCount(SyncQueue) == 0

  # Dead-letter handler logs the failure and marks the job
  let dead = expectJobOk(processNextDeadJob SyncQueue)
  expect dead.userId == "alice"
}
```

### Combined: HTTP → queue → SSE

The full end-to-end chain: an HTTP request triggers a worker job; the worker processes it
and publishes an SSE event; a subscribed client receives it.

```tesl
api-test "order placed triggers fulfilment and real-time confirmation" for ShopServer
  requires [dbWrite, time] {
  seed {
    insert User {
      id:        "user-alice",
      email:     "alice@example.com",
      role:      Member,
      createdAt: nowMillis()
    }
    insert Product {
      id:        "prod-widget",
      name:      "Widget",
      priceCents: 999,
      stock:     10,
      createdAt: nowMillis()
    }
  }

  let aliceStream = subscribe "/events/notifications/user-alice" cookie "session=user-alice"

  let order = post "/orders"
                cookie "session=user-alice"
                body { "productId": "prod-widget", "quantity": 2 }
  expect order.status == 201
  let orderId = order.body.id

  # Verify the fulfilment job has the right payload before running it
  expect pendingJobCount(FulfilmentQueue) == 1
  let job = expectJobOk(processNextJob FulfilmentQueue)
  expect job.orderId   == orderId
  expect job.productId == "prod-widget"
  expect job.quantity  == 2

  # Worker publishes SSE — Alice receives the confirmation
  let events = collect aliceStream count 1 timeout 3s
  expect events |> includesWhere { "type": "OrderConfirmed", "orderId": orderId }
}
```

---

## Module scope

`api-test "name" for ServerName` requires `ServerName` to be in scope. A typical file with
api-tests imports both the server and the testing module:

```tesl
import ChatApi      exposing [ChatServer, NotificationQueue]
import Tesl.ApiTest exposing [
  HttpResponse, JsonValue, JsonNull,
  statusOk, statusClientError,
  includesWhere, excludesWhere, hasLength, isEmpty, isNotEmpty, arrayAt,
  isNull, isNotNull, jsonInt, jsonString, jsonBool, jsonArray, jsonLength,
  hasField, fieldAt, bodyField, jsonContains,
  SseStream, subscribe, collect,
  JobResult(..), processNextJob, processNextDeadJob, drainQueue, pendingJobCount,
  expectJobOk, expectJobFailed,
]

api-test "..." for ChatServer { ... }
```

Queue names (`NotificationQueue`, `FulfilmentQueue`, etc.) are imported from the module that
declares them, not from `Tesl.ApiTest`.

There is no `*.api-test.tesl` file convention. Api-tests are top-level declarations in the same
module system as every other Tesl form. They may live in the same file as the server definition
or in a dedicated file that imports it — whichever fits the project layout.

---

## Compilation strategy

`api-test` blocks compile to Racket inside the `module+ test` submodule, exactly like
`test` blocks today. The generated code:

1. Acquires the server value from the same module.
2. Executes the `seed { }` block against the in-memory store directly.
3. Wraps the block in `call-with-fresh-memory-db` (or a transaction for `--test-db`).
4. Translates each `get`/`post`/`put`/`delete` in the body to a `dispatch-with-server` call.
5. Translates each `expect` to a `check-equal?` / `check-true` rackunit assertion.

The only new Racket runtime primitive needed is `call-with-fresh-memory-db` in
`dsl/test-support.rkt`. `load-test` compilation (`dsl/load-test.rkt`,
`dsl/baselines.rkt`) is Track C — see `roadmap/next/04-api-test-load-tests.md`.

---

## Parser additions

The following top-level form is added to the compiler:

- `parse_api_test_block` — parses `api-test "name" for Server { seed? body }`, including the
  optional `seed { }` sub-block, request builders, `let` bindings, and `expect` assertions.

Added as a top-level form alongside `parse_test_block` in the compiler dispatch.
`parse_load_test_block` is Track C — see `roadmap/next/04-api-test-load-tests.md`.

---

## Deferred

- **Property-based api-tests.** No typed schema to generate from; deferred until a structured
  approach (e.g., OpenAPI schema integration) exists.
- **Parallel test execution.** Tests within a file run sequentially. Parallel execution across
  files is a future optimisation once the in-memory isolation model is battle-tested.
- **Load tests.** `load-test` blocks with rate-based scheduling, HDR Histogram measurement,
  and baseline comparison are Track C — see `roadmap/next/04-api-test-load-tests.md`.

---

## Implementation plan

Tracks A and B can proceed in parallel once the shared foundation (step A1) is confirmed.
Track C (load tests) is in `roadmap/next/04-api-test-load-tests.md` and is deferred until
after the compiler rewrite.

**Track A — Example-based HTTP tests**

| Step | What | Notes |
|------|------|-------|
| A1 | Verify `call-with-fresh-memory-db` generates `FromDb` proofs on `insert` | Confirm before building on it |
| A2 | `seed { }` parsing and compilation — reuse existing `insert` emission; discard proof return; implicit capabilities | Same compile-time field/type checking as handler inserts; no new SQL generation needed |
| A3 | Parser: `parse_api_test_block` — `seed`, request builders, `let`, `expect` | Start with `get`/`post` only |
| A4 | Compiler: `emit_api_test_block` → `module+ test` Racket | Uses existing `dispatch-with-server` |
| A5 | `tesl/api-test.rkt`: `Tesl.ApiTest` module — `HttpResponse`, `JsonValue`, all JSON/array/status helpers | Specified failure semantics throughout |
| A6 | Lesson: `lesson32-api-tests.tesl` against `todo-api.tesl` | Validates end-to-end |

**Track B — SSE and queue testing**

| Step | What | Notes |
|------|------|-------|
| B1 | `SseStream` type and buffered SSE connection in `tesl/api-test.rkt` | Connection established on `subscribe`; events buffered until `collect` |
| B2 | Parser: `subscribe` and `collect` expressions inside `api-test` bodies | `collect` requires `timeout` when `count` or `until` is specified |
| B3 | Compiler: emit `subscribe`/`collect` as calls into `tesl/api-test.rkt` | Runs in same in-memory DB scope as the rest of the test |
| B4 | `JobResult` ADT, `processNextJob`, `processNextDeadJob`, `drainQueue`, `pendingJobCount`, `expectJobOk`, `expectJobFailed` in `tesl/api-test.rkt` | Fail-fast on empty queue for `processNextJob`/`processNextDeadJob`; `drainQueue` limit 1000 |
| B5 | Parser/compiler: `processNextJob` / `drainQueue` expressions inside `api-test` bodies | Queue names are values imported from the declaring module |
| B6 | Lesson: `lesson33-sse-and-queue-tests.tesl` against `chat/backend.tesl` | Validates SSE + queue together |

---

## Examples

### Full CRUD flow

```tesl
api-test "todo lifecycle" for TodoServer
  requires [dbWrite, time] {
  seed {
    insert User {
      id:        "user-alice",
      email:     "alice@example.com",
      role:      Member,
      createdAt: nowMillis()
    }
  }

  # Create
  let create = post "/todos"
                 cookie "session=user-alice"
                 body { "title": "Buy milk" }
  expect create.status == 201
  let todoId = create.body.id

  # Read back
  let fetch = get "/todos/{todoId}" cookie "session=user-alice"
  expect fetch.status == 200
  expect fetch.body.title == "Buy milk"
  expect fetch.body.status == "Open"

  # Update
  let update = put "/todos/{todoId}"
                 cookie "session=user-alice"
                 body { "status": "Done" }
  expect update.status == 200

  # Verify update
  let after = get "/todos/{todoId}" cookie "session=user-alice"
  expect after.body.status == "Done"

  # Delete
  let del = delete "/todos/{todoId}" cookie "session=user-alice"
  expect del.status == 204

  # Confirm gone
  let gone = get "/todos/{todoId}" cookie "session=user-alice"
  expect gone.status == 404
}
```

### Auth boundary tests

```tesl
api-test "unauthenticated requests are rejected" for TodoServer {
  let r1 = get "/todos"
  expect r1.status == 401

  let r2 = post "/todos" body { "title": "x" }
  expect r2.status == 401
}

api-test "user cannot access another user's todos" for TodoServer
  requires [dbWrite, time] {
  seed {
    insert User {
      id:        "user-alice",
      email:     "alice@example.com",
      role:      Member,
      createdAt: nowMillis()
    }
    insert User {
      id:        "user-bob",
      email:     "bob@example.com",
      role:      Member,
      createdAt: nowMillis()
    }
  }

  let create = post "/todos"
                 cookie "session=user-alice"
                 body { "title": "Alice's todo" }
  expect create.status == 201
  let todoId = create.body.id

  let attempt = get "/todos/{todoId}" cookie "session=user-bob"
  expect attempt.status == 403
}
```

---

## End goal: Track C

The syntax and infrastructure built in Tracks A and B are designed to extend cleanly to
load tests. A `load-test` block reuses `seed { }`, the same request builders, and the same
`Tesl.ApiTest` import — the only additions are `rate`, `duration`, `baseline`, and `assert`
on histogram values. The full design and implementation plan for Track C is in
`roadmap/next/04-api-test-load-tests.md`.

Keep this in mind when designing the `api-test` block structure: the request body of a
`load-test` is a single request expression (not a sequence), which is the same sub-syntax
as a single-step `api-test`. The parser and emitter should be factored so that the request
builder parsing is shared between both block types.
