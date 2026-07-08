# Tesl — a guided feature tour

> Audience: Tesl users evaluating or learning the language. This is the long-form,
> feature-by-feature tour. For the short pitch see [README](../README.md); for the precise
> semantics see [LANGUAGE-SPEC.md](../LANGUAGE-SPEC.md). Run `tesl help manual tour` to read this
> from the CLI.

**Tesl** is a programming language for building robust web APIs without the infrastructure tax. By
treating validation as a first-class citizen, Tesl makes a checked value *carry its proof*: once
data is validated at the boundary, the compiler structurally prevents whole classes of
forgotten-validation and defensive-boilerplate bugs from reappearing downstream. With built-in job
queues and real-time pub/sub, Tesl gives you the operational simplicity to ship your MVP today and
the confidence to refactor it as it grows — the shortest path from your business logic to a reliable
system, for humans and AI agents alike.

> **Status: beta.** The guarantees described below are real and compiler-enforced for code written
> in Tesl, but they are *compile-time* guarantees with no runtime re-check, and the trust boundary
> is drawn precisely in [`LANGUAGE-SPEC.md` §7](../LANGUAGE-SPEC.md). Tesl is not yet
> production-stable; breaking changes are expected. Read this document as the design intent and what
> is enforced today — not as a promise of a finished system.

---

## The problem it solves

In most frameworks you validate at the boundary and then... hope. The validated data is still the
same type as unvalidated data, so nothing stops it from getting mixed up — or from a function deep in
the call stack receiving raw input and skipping the check.

```tesl
# Typical framework pattern (pseudocode): the validated title has the same
# type as any other string, so nothing prevents it from reaching the database
# unchecked.
let title = request.body.title   # could be anything
# ...passed through 3 layers...
insert Todo { title: title }     # was it validated? hard to tell
```

Tesl solves this at the type level. A `check` function doesn't just validate — it *annotates* the
value with proof that it passed. That proof is carried in the type signature wherever the value
travels.

---

## How it works

### 1. Define validation once

```tesl
check isValidTitle(title: String) -> title: String ::: ValidTitle title =
  if 3 <= String.length(title) && String.length(title) <= 120 then
    ok title ::: ValidTitle title
  else
    fail 400 "Title must be between 3 and 120 characters"
```

`check` is like a function that returns `Result<T, Error>` — except instead of wrapping the value in
a `Some`/`Ok`, it *stamps* the original value with a proof. The `:::` annotation is the stamp. The
check runs **once**, at the validation boundary, and never again.

**Runtime cost — erased by default.** After a successful `check`, the proof is a *compile-time* fact.
In a normal (release) build the proof-tracking machinery is **erased during macro expansion**: by the
time your code runs there is no wrapper and no allocation for standard `check`/`fn`/`handler` paths.
This is the norm; a few constructs deliberately keep a minimal runtime carrier. For the full
per-feature breakdown see the canonical [proof cost model](best-practices.md#proof-cost-model).

**Mutation testing.** Since the `check` function is where critical bugs can creep in, Tesl has
built-in mutation testing for all `check`, `establish`, and `auth` functions.

### 2. Attach validation to request bodies via a codec

```tesl
record NewTodo {
  title: String ::: ValidTitle title
}

codec NewTodo {
  toJson_forbidden          # this type is input-only; encoding is not needed
  fromJson [
    {
      title <- "title" with_codec stringCodec via isValidTitle
    }
  ]
}
```

When Tesl decodes a `NewTodo` from a request body, it runs `isValidTitle` automatically. If it fails,
the request is rejected with a 400 before your handler even runs. If it passes, the `title` field
carries the `ValidTitle` proof.

If an endpoint needs a separate wire shape, write the adapter explicitly in the API declaration:
`body req: Domain from Wire via decodeWire` and `response Wire via encodeWire`. These adapters must
be declared Tesl functions so the compiler can verify them at compile time. `decodeWire` must accept
exactly one raw `Wire` value and return `Domain` (including any required body proof unless the
endpoint uses a `body ... via (...)` boundary checker). `encodeWire` must accept the raw handler
return value and return `Wire`. The `Wire` type still needs a visible codec because it is the type
that crosses the HTTP boundary.

### 3. Client generation

Tesl can also generate client-facing artifacts from the same API declarations that drive the server
surface. Today that mainly means:

- `tesl --ir file.tesl` for a frontend-facing JSON view of records, facts, codecs, and endpoints
- `tesl generate ts file.tesl` for a TypeScript client that uses Zod
- `tesl generate elm file.tesl` for an Elm client that preserves proof-carrying values with
  `mtonnberg/refinement-proofs`

The point is not just convenience. Tesl already knows the request and response shapes, the codecs
that cross the HTTP boundary, which facts are simple enough to mirror on the client, and which facts
remain server-only. That lets the generated clients stay close to the actual API contract instead of
drifting into a hand-maintained second definition.

Because the API layer, database JSONB layer, and generated clients all lean on the same declared
codecs and type shapes, Tesl can reuse one wire-format story across the stack instead of maintaining
separate ad hoc schemas for each consumer.

> Note: the generated TypeScript and Elm clients, along with the frontend-facing IR they depend on,
> are still experimental in the current beta and may change aggressively — names and emitted helper
> shapes may still change, not every proof can be mirrored client-side yet, and the generators still
> consume the compiler AST directly rather than a fully normalized internal frontend IR.

The long-term goal is for the client surface to feel like a natural extension of the language: define
the API once, and get a trustworthy server, wire contract, and frontend client story from the same
source.

### 4. Declare what you need — the compiler checks the rest

```tesl
handler createTodo(
  user:    User    ::: Authenticated user,
  newTodo: NewTodo
) -> exists todoId: String => Todo ? FromDb (Id == todoId)
                              # `?` means the caller gets back a Todo that the compiler
                              # knows was just inserted — the `FromDb` proof comes for free
  requires [dbRead, dbWrite, time, random] =
  let todoId = generatePrefixedId("todo")
  exists todoId =>
    insert Todo {
      id:        todoId,
      title:     newTodo.title,   # ValidTitle proof is already here — nothing to re-check
      ownerId:   user.id,
      status:    Open,
      createdAt: nowMillis()
    }
```

The handler signature tells you everything: it needs an authenticated user, a valid request body,
database read/write access, a clock, and a random source. The compiler verifies all of it. The
`exists todoId =>` in the return type is Tesl's way of saying "I created a new entity and here's the
proof it exists in the database" — the caller gets a `Todo` that the compiler knows came from a real
insert.

---

## Key features

### Auth is a compile-time guarantee

Auth in most frameworks is a runtime concern — a middleware attribute, a guard, something that runs
before your handler. If you forget it, nothing tells you until a request hits.

In Tesl, auth produces a proof. A handler that declares `user: User ::: Authenticated user` simply
cannot be called with an unauthenticated user — the compiler rejects it.

```tesl
auth cookieAuth(request: HttpRequest) -> user: User ::: Authenticated user
  requires [readCookies] =
  case request.cookies.user of
    Nothing       -> fail 401 "not logged in"
    Something uid -> ok { id: uid, role: "user" } ::: Authenticated user

# This endpoint can only be wired to a handler that takes Authenticated user.
# Try to wire it to a handler without auth — compile error.
get "/todos/mine"
  auth user: User ::: Authenticated user via cookieAuth
  -> List Todo
```

### Capabilities: explicit side effects

Every function lists what it touches. Think of it as dependency injection, but enforced by the
compiler rather than at runtime.

```tesl
capability todoRead  implies dbRead
capability todoWrite implies dbWrite
capability todoService implies todoRead, todoWrite, time, random

handler listTodos(user: User ::: Authenticated user)
  -> List Todo
  requires [todoRead] =       # declares: this function reads the DB
  select todo from Todo where todo.ownerId == user.id
```

If you add a database write and forget to update `requires`, the compiler tells you immediately. If
you call a function that requires `todoWrite` from a context that only has `todoRead`, the compiler
rejects it. No surprises in production. The capability *lattice* is enforced statically — the
contract is verified at compile time. At run time a function still runs inside a lightweight ambient
capability-grant (a dynamic-extent check), so unlike proofs, capabilities are not fully erased; the
residual per-call cost is small (a membership check against the granted set), not zero.

### Typed SQL — no ORM magic, no string column names

Tesl doesn't generate SQL from object graphs (Entity Framework style) and it doesn't ask you to write
raw SQL strings (Dapper style). You write SQL-shaped queries using the field names from your entity
declaration, and the compiler checks every field reference at compile time.

Start by declaring your entity — this is the single source of truth for both the schema and the query
types:

```tesl
entity Todo table "todos" primaryKey id {
  id:        String
  title:     String
  ownerId:   String     @db(text)
  status:    Status                  # Status is an ADT — stored as text, decoded automatically
  createdAt: PosixMillis
}
```

Then query it. Field names are checked by the compiler — misspell `ownerId` and you get a compile
error, not a runtime crash:

```tesl
# select returns List Todo ::: ForAll (FromDb (OwnerId == user.id)) — typed and proven
let mine = select todo from Todo where todo.ownerId == user.id

# selectOne returns Maybe Todo — the Nothing case is forced to be handled
let found = selectOne todo from Todo where todo.id == todoId

# insert returns a proof that the row exists in the database
insert Todo { id: todoId, title: newTodo.title, ownerId: user.id, status: Open, createdAt: nowMillis() }

# update with a typed predicate and typed set clause
update todo in Todo
  where todo.id == todoId
  set   todo.status = Done
  returning one
```

There is no query builder, no expression tree, no reflection. The generated SQL is always
parameterised (`WHERE owner_id = $1`) — SQL injection is structurally impossible because user data
never appears as literal SQL text.

**Atomic writes with `transaction`.** When two or more writes must either all succeed or all fail,
wrap them in `transaction`:

```tesl
transaction {
  let _ = insert User { id: userId, name: name }
  insert Profile { userId: userId, bio: "" }
}
```

The block returns the value of its last expression. Any exception inside rolls back everything.
Transactions cannot be nested — a `transaction` inside another `transaction` is a compile error,
caught before you run a line. Note that adding items to a queue can also be in a transaction with an
insert, for instance.

Column type mapping is automatic for all common types — you rarely need to annotate anything:

| Tesl type | PostgreSQL column | Notes |
|---|---|---|
| `String` | `TEXT NOT NULL` | |
| `Int` | `BIGINT NOT NULL` | |
| `Bool` | `BOOLEAN NOT NULL` | Use `Bool` in Tesl source; `BOOLEAN` describes the SQL storage type |
| `PosixMillis` | `BIGINT NOT NULL` | Auto-coerced; no annotation needed |
| Any ADT | `JSONB NOT NULL` | Encoded as `{"tag":"ConstructorName","fields":{...}}` |
| Newtype wrapping `String` | `TEXT NOT NULL` | Unwrapped transparently on read/write |
| `Maybe T` | Nullable column for `T` | `Nothing` ↔ `NULL`, `Something v` ↔ the value |

`@db(type)` lets you override when you need a specific PostgreSQL type (e.g., `@db(uuid)` for a UUID
column). For the common cases above, leave it off.

**ADTs are stored as JSONB.** An ADT field — whether a simple flag like `Status = Open | Done` or a
richer union with payloads — is automatically stored as a PostgreSQL `JSONB` column with no
annotation required:

```tesl
type JobResult
  = Delivered messageId: String
  | Failed    reason:    String
  | Pending

entity Task table "tasks" primaryKey id {
  id:        String
  result:    JobResult   # stored as JSONB — {"tag":"Delivered","fields":{"messageId":"msg-1"}}
  createdAt: PosixMillis
}
```

There are two practical benefits over storing the constructor name as plain text. First, ADT
*variants with data* round-trip correctly: a `Delivered "msg-123"` value survives a write and read
back as exactly `Delivered "msg-123"` — the payload is preserved in the JSON object, not truncated.
Second, there is only one serialization format across the entire stack: the JSON encoding Tesl uses
for HTTP response bodies is the same encoding used for database storage. No separate codec, no
mismatch between what a client sees and what is in the database.

JSONB also opens the door to querying on ADT structure in the future. Today you can filter on
equality of simple fields; the roadmap includes extending the SQL layer to support containment
patterns:

```tesl
# planned — not yet in the language
selectOne task from Task where task.result == Delivered "msg-123"
# compiles to: WHERE result @> '{"tag":"Delivered","fields":{"messageId":"msg-123"}}'::jsonb
```

PostgreSQL has native GIN indexes for JSONB containment queries, so this will be fast even on large
tables.

The mental model is closer to **Doobie** (Scala) or **SqlCommand with typed parameters** (.NET) than
to an ORM — you write the query, you see the SQL, there are no surprises. The difference is that field
names are resolved at compile time and the result type is inferred, so you get type safety without
the ceremony.

**`PosixMillis` — timestamps without timezone drama.** `PosixMillis` is a nominal type for timestamps
(ms since epoch). Being a newtype, the compiler rejects accidentally passing a duration where a
timestamp is expected. It auto-maps to `BIGINT` in PostgreSQL with no annotation, and `Date.now()` on
the frontend reads it directly — no conversion layer, no timezone surprises.

**Grouped aggregates and time bucketing.** `selectCount`/`selectSum`/`selectMax`/`selectMin` return
one scalar; `selectCountBy`/`selectSumBy … groupBy <key>` return **one row per group** as a
`List (Tuple2 key aggregate)`, ordered by key — the server-side series a chart wants.
`Time.truncHour/Day/Week/Month/Year zone ts` give the calendar bucket (ISO Monday weeks) both as
the `groupBy` key and as a plain function for computing range bounds. `TimeZone` is a **fixed
ADT**: `Utc`, `FixedOffset minutes`, or one of the 489 baked IANA zone constructors
(`EuropeStockholm`, `AmericaNewYork`, …) — a typo is a compile error, completion lists every zone,
and zone constructors are **DST-correct per instant**, so nobody tracks summer/winter time by hand:

```tesl
# per-day minutes for one org, in the org's zone — one (dayStart, sum) row per day,
# correct across DST transitions
selectSumBy e.minutes from Entry
  where e.orgId == orgId
  groupBy (Time.truncDay EuropeStockholm e.startedAt)   # List (Tuple2 PosixMillis Int)

# "revenue today" needs no SQL bucketing: trunc client-side, range where (index-friendly)
let dayStart = Time.truncDay EuropeStockholm (nowMillis())
selectSum s.price from Sale where s.soldAt >= dayStart

Time.offsetAt EuropeStockholm (nowMillis())   # the offset right now, if you need it
```

The bucket is computed in the database (integer arithmetic for fixed offsets, PostgreSQL's own
tzdata via `AT TIME ZONE` for zone keys — the column stays BIGINT millis, the key stays
`PosixMillis`) and the Memory test backend uses the same reference engine, parity-tested against
PostgreSQL per zone and unit.

### Schema and migrations

Tesl derives the database schema directly from your `entity` and `database` declarations. On first
run it creates any missing tables automatically — no separate migration file needed to get started:

```tesl
database TodoDatabase = Database {
  schema: "todo_api"
  entities: [Todo, User]
  backend: Postgres (PostgresConfig {
    dbName: env "TESL_POSTGRES_DATABASE"
    user: env "TESL_POSTGRES_USER"
    password: env "TESL_POSTGRES_PASSWORD"
    connection: TcpConnection {
      host: env "TESL_POSTGRES_HOST"
      port: envInt "TESL_POSTGRES_PORT" 5432
    }
  })
}
```

`PostgresConfig` also takes an optional `poolSize: Int` (default 10) — the maximum number of
simultaneously open connections; `poolSize: envInt "PG_POOL_SIZE" 20` makes it deployment-tunable.
When every pooled connection is busy, a request **waits** (bounded, 10s default,
`TESL_PG_POOL_LEASE_TIMEOUT_MS` overrides) for a freed connection instead of failing immediately;
a timed-out wait answers `503 Service Unavailable`, so brief bursts queue and succeed while genuine
sustained overload surfaces as a clear retryable signal.

This is intentionally optimistic for development — spin up a fresh database and `tesl run` just works.
For production, a dedicated migration tool is on the roadmap. The current approach is: Tesl owns the
schema declaration; you own the migration strategy. If you add a column to an entity, Tesl tells you
at startup if it is missing — then you decide how to apply the change (a migration script,
`ALTER TABLE`, whatever your deployment allows).

The key constraint Tesl does enforce: you cannot reference a field in a query that is not in the
entity declaration. If you remove a field from the entity, every query and handler that touches it
becomes a compile error — so you always know the full blast radius of a schema change before you touch
the database.

### Queues and background workers — no infrastructure glue

Setting up Hangfire or a Redis-backed job queue takes real configuration. In Tesl, queues are
first-class declarations.

```tesl
record NotifyJob {
  userId:  String
  message: String
}

queue NotificationQueue requires [notifyCap] = Queue {
  database: AppDatabase
  jobs:     [Job NotifyJob notifyWorker Nothing]
  retry:    QueueRetryStrategy {
    maxAttempts:  3
    backoff:      Exponential
    initialDelay: 5
  }
}

worker notifyWorker(job: NotifyJob ::: FromQueue (Id == jobId) job)
  requires [notifyCap] =
  # send the notification
  job
```

The worker is wired to its job type directly in the queue's `jobs` list
(`Job <JobType> <workerFn> <deadLetterSlot>`) — there is no separate `workers` declaration. Use
`Nothing` for no dead-letter handler, or `(Something deadFn)` to attach one.

Jobs are stored in PostgreSQL using `FOR UPDATE SKIP LOCKED` for safe concurrent dequeue. No Redis.
No separate service. Retry with exponential backoff is declarative. Dead-letter queues for failed
jobs are a built-in `deadWorker` declaration.

### Real-time push — one port, no WebSocket proxy

SSE (Server-Sent Events) runs on the same HTTP port as your REST endpoints. No separate WebSocket
server, no nginx config, no reconnection logic — the browser's native `EventSource` handles it.

```tesl
sseChannel RoomMessages(roomId: String) = SseChannel {
  database: ChatDatabase
  payload: RoomEvent
}

# Publish from inside a transaction — atomically with your DB writes:
transaction {
  publish RoomMessages(roomId) NewMessage { content: req.content }
  insert Message { id: msgId, roomId: roomId, content: req.content }
}

# Subscribe from an SSE endpoint:
sse "/events/rooms/:roomId"
  auth    session: User ::: Authenticated session via cookieAuth
  capture roomId:  String ::: ValidRoomId roomId via roomIdCapture
  subscribe RoomMessages(roomId)
```

Horizontal scaling uses PostgreSQL `LISTEN/NOTIFY`. No separate message broker.

### AI agents — typed tools, no schema strings

An agent is one typed-record constructor, `Agent { … }` — usable as a top-level declaration or a plain
expression (so a bring-your-own-key agent is just `Agent { … }` built per request). `provider` is a
full LLM provider value (the type checker enforces the model + key); `tools` are ordinary typed Tesl
functions wrapped with `asTool`, which derives the JSON Schema from the parameter types and decodes
the model's tool-call arguments for you — no hand-written schema or validator.

```tesl
fn lookupOrderStatus(orderId: String) -> String requires [dbRead] =
  case selectOne o from Order where o.id == orderId of
    Something o -> o.status
    Nothing -> "no such order"

agent SupportAgent requires [supportAi] = Agent {
  provider: anthropic (requireEnv "ANTHROPIC_API_KEY") "claude-opus-4-8"
  systemPrompt: "You are a concise support assistant."
  tools: [asTool lookupOrderStatus]
  maxTokens: 512
}

# one-shot, or a full multi-turn conversation you persist yourself:
let answer = ask SupportAgent "Where is order ord-42?"
```

**Your whole API as tools, preauthenticated (`serverTools`).** Instead of listing tools one by one,
give an agent every endpoint of a server in one expression — partially applied with the
proof-carrying authenticated user, so the agent acts strictly on the user's behalf (the tools ARE
your endpoint handlers; every ownership check in them runs unchanged, and there is no session
forwarding or token minting):

```tesl
handler assistant(user: User ::: Authenticated user, q: Question) -> String
  requires [todoWebService, supportAi] =
  let agent = Agent {
    provider: anthropic (requireEnv "ANTHROPIC_API_KEY") "claude-opus-4-8"
    systemPrompt: "You act on the user's todos via the provided tools."
    maxTokens: 512
    tools: List.append (serverTools TodoServer user) [asTool internalHelper]
  }
  ask agent q.text
```

Which endpoints become tools is decided per call site from the user's declared proof: a
`u ::: Authenticated u` user gets the plainly-authenticated endpoints, a
`u ::: Authenticated u && Admin u` user additionally gets the admin-gated ones. Tool names,
descriptions (handler doc-comments), and JSON schemas are derived; tool arguments run the endpoint's
own boundary validation (capture checks, body codecs). See LANGUAGE-SPEC §11.1 and
[lesson68](../example/learn/lesson68-server-endpoints-as-tools.tesl).

**Actions the agent may NOT do — hand them to the human (`humanActions`).** `humanActions S user`
is the exact complement of `serverTools S user`: the endpoints the user's declared proof does *not*
cover. Together they partition the server — the agent runs what the user can, and everything else
becomes an inert "ask the human" tool. Scope the agent's `user` narrower than the human's real
authority and the held-back endpoints (e.g. admin-only ones) land in `humanActions`:

```tesl
tools: List.append (serverTools NotesServer user) (humanActions NotesServer user)
```

Calling a `humanActions` tool **cannot** run the endpoint — the runtime is handed only the server
name and metadata, never a handler — so it returns a `human-action-request` descriptor
(`{ kind, server, action, args, handle }`) instead. `tesl generate elm|ts` emits a typed decoder per
server that rejects any `action` the server didn't declare and resolves the real URL from generated
client code, so the frontend renders a safe button; the human clicks, their browser calls the real
endpoint under their own session, and you feed the result back as another `converse` turn
("resume-after"). `humanActions` charges no capability. See LANGUAGE-SPEC §11.1 and
[lesson69](../example/learn/lesson69-agent-human-handoff.tesl).

**Long-running work: enqueue, then resume the conversation.** When a tool is slow (generate a
report, call a third party), don't block the turn — the tool `enqueue`s a job and returns "queued".
A `worker` does the work later and, when done, `publish`es to the conversation's SSE channel (an
`Email.send` fits here too) *and resumes the conversation*: load its transcript with
`conversationFrom`, run one more `converse` feeding in the result, persist. The conversation id
travels on the job, so completion re-enters exactly the conversation that was waiting — a browser
watching it sees the agent pick back up on its own. Nothing is suspended (a resumed turn is just
another `converse`, run on the worker), so a job that never finishes never pins a request. This is
plain composition of `enqueue` / `worker` / `publish` / the conversation primitives — no new agent
machinery. See [lesson70](../example/learn/lesson70-agent-async-work.tesl).

**Curating which tools the model gets (the two-api pattern).** `serverTools` derives tools from the
server's endpoint list, so a second `api`/`server` pair binding the *same handler functions* but
listing only a subset of endpoints is a compile-time tool allowlist: the user-facing server keeps the
full HTTP surface, the agent-facing server (it never needs to be mounted) decides exactly which
handlers the model may call.

**Capabilities travel with the tools.** A tool function's `requires` (and a `serverTools` endpoint's
handler `requires`) is checked where the agent is *built* and then delegated to the tool when it
*executes* inside the agent loop — so an agent that type-checks cannot have its tools trap on a
missing capability on a live turn. A tool body that still raises comes back to the model as an
`is_error` tool_result and the turn continues; it never kills the loop.

**Dates the model can read.** In agent tool results every `PosixMillis` renders as
`{"epochMillis": 1783804288000, "iso": "2026-07-11T21:11:28Z"}` instead of a bare integer — the model
gets the real calendar date instead of guessing one from epoch digits (a classic hallucination
source). Tool *parameters* typed `PosixMillis` likewise carry an epoch-milliseconds description in
their derived schema. HTTP responses are unchanged, and generated Elm/TypeScript clients decode
either shape.

For a chat UI, `converseStreaming conv message publish` runs a turn and calls `publish` with each
event as it happens — `tool: <name>` as a tool is dispatched, `text-delta: <part>` for each token of
the answer as the model generates it (real providers use the streaming API; the mock synthesizes
chunks), then `text: <reply>` at the end. Forward those to an `sseChannel` and a browser `EventSource`
renders the answer incrementally ("live typing"); a consumer that only reads `text:` still works.

A tool that reads the database does so through the same proof-carrying SQL boundary as the rest of
your code, so a tool answer is grounded in real rows, never fabricated. Tests run against a
deterministic `mockProvider` / `mockToolProvider` — no key, no network. Real providers (`anthropic` /
`openai` / `mistral` / `local`) require the `aiProvider` capability. For testing agent tools,
entitlements, and structured output, see [AI / Agent Testing](ai-testing.md).

### Type-safe list filtering (ForAll proofs)

When a `select` query runs, Tesl annotates the result list with proof of its origin. Filter the list
and the proof expands rather than disappears — similar to how F# `Seq.filter` preserves the element
type, except here it also preserves the proof.

```tesl
# Return type says: every element is owned by this user AND is open
handler listOpenTodos(user: User ::: Authenticated user)
  -> List Todo ::: ForAll (FromDb (OwnerId == user.id) && IsOpen)
  requires [todoRead] =
  let mine = select todo from Todo where todo.ownerId == user.id
  List.filterCheck(checkOpen, mine)   # filterCheck expands the proof, never removes it
```

A function that accepts `List Todo ::: ForAll (IsOpen)` cannot receive a plain `List Todo` — the
compiler enforces that filtering actually happened. At runtime a `ForAll`-annotated list is a plain
list with no extra wrapping — the annotation is erased after type-checking, so there is no
per-element boxing, no extra allocations, and no measurable overhead versus a regular filter.

### Tesl-native API tests

Tesl can test the full HTTP boundary from inside the language. `api-test` blocks exercise routing,
auth, codecs, database effects, queues, and SSE without dropping to Racket.

```tesl
import Tesl.ApiTest exposing [statusOk, subscribe, collect, processNextJob, expectJobOk, pendingJobCount]

api-test "comment notification reaches the user stream" for AppServer
  requires [dbRead, dbWrite, queueWrite, queueRead, pubsub] {
  let stream = subscribe "/events/users/usr_1" cookie "session=usr_1"
  let resp = post "/comments" cookie "session=usr_2" body { "body": "Looks good" }
  expect statusOk resp.status
  expect pendingJobCount NoticeQueue == 1

  let result = processNextJob NoticeQueue
  let job = expectJobOk result
  expect job.userId == "usr_1"

  let events = collect stream count 1 timeout 1500ms
  expect events |> includesWhere { "tag": "NoticeSent" }
}
```

Every `api-test` runs against a fresh in-memory database unless the CLI is told to use a real test
database. Response bodies are raw `JsonValue`s on purpose: the goal is to verify the wire contract
your clients actually see. `Tesl.ApiTest` provides helpers for status ranges, JSON extraction, SSE
collection, and deterministic worker processing.

### ADTs and pattern matching

Tesl has sum types with exhaustive pattern matching — the same model you know from F# discriminated
unions or Scala sealed traits.

```tesl
type JobResult
  = Delivered messageId: String
  | Failed    reason: String
  | Pending

fn describeResult(r: JobResult) -> String =
  case r of
    Delivered id -> "sent: " + id
    Failed reason -> "failed: " + reason
    Pending       -> "still waiting"
```

The compiler rejects non-exhaustive `case` expressions. Add a new constructor and every unhandled
`case` becomes a compile error.

**String and integer literal patterns.** Case arms can match exact literal values:

```tesl
case code of
  200 -> "OK"
  404 -> "Not Found"
  _   -> "other"

case cmd of
  "help"  -> showHelp()
  "quit"  -> quit()
  other   -> "unknown: " + other
```

A variable or wildcard catch-all arm is required for `Int` and `String` since they have infinite
domains.

**Nested constructor patterns.** A field can be a sub-pattern that matches inside a nested
constructor, eliminating the need for an inner `case` expression:

```tesl
type Wrapped = Wrap inner: Maybe Int

fn extract(w: Wrapped) -> Int =
  case w of
    Wrap (Something n) -> n   # positional: parens wrap the sub-pattern
    Wrap Nothing       -> 0
```

For ADTs with multiple fields, use the labeled brace syntax:

```tesl
case wrapped of
  Wrap { inner = Something { value = n } } -> n
  Wrap { inner = Nothing }                 -> 0
```

**Parameterized ADTs — generic containers.** You can declare ADTs with type parameters, just like
`List a` or `Maybe a` in the standard library. List the lowercase parameter names after the type name:

```tesl
# A generic result container for domain operations
type DomainResult a
  = Success value:a
  | ValidationError message:String
  | NotFound

# A tree structure parameterized over its element type
type Tree a
  = Leaf
  | Node left:(Tree a) value:a right:(Tree a)
```

Pattern matching works the same way — the type parameter controls what type you get when you bind a
field. The compiler infers type arguments; you never write them explicitly. Type parameters are
erased at runtime so there is no overhead versus a concrete ADT. `Maybe`, `Result`, `Either`, `List`,
`Dict`, `Set`, and `Tuple2`/`Tuple3` in the standard library are all parameterized ADTs.

**ADTs in codecs.** When an ADT type appears as a field in a request record, declare a codec for it
using `adtJson` — this tells Tesl to use the standard `{"tag": "ConstructorName"}` JSON format for
both encoding and decoding:

```tesl
type Priority = Low | Medium | High

codec Priority {
  adtJson         # encode/decode as {"tag": "Low"} / {"tag": "Medium"} / {"tag": "High"}
}

record NewTask {
  title:    String
  priority: Priority
}

codec NewTask {
  toJson_forbidden
  fromJson [
    {
      title    <- "title"    with_codec stringCodec
      priority <- "priority" with_codec Priority   # uses the adtJson codec above
    }
  ]
}
```

The compiler validates that `with_codec Priority` is used on a field declared as `Priority` and that
`Priority` has an `adtJson` codec — a type mismatch (e.g., `with_codec stringCodec` on a `Priority`
field) is a compile error.

### OpenTelemetry is ambient

Observability is the one side effect that shouldn't require bureaucracy. Add `telemetry` calls
anywhere — no capability declaration needed.

```tesl
handler listTodos(user: User ::: Authenticated user)
  -> List Todo
  requires [todoRead] =
  telemetry "todos.list" { user.id = user.id }   # zero overhead when not sampling
  select todo from Todo where todo.ownerId == user.id
```

Metrics are ambient too. Import `counter`/`histogram`/`gauge` from `Tesl.Telemetry` for your own
instruments, and the runtime records a built-in catalog automatically whenever a real OTLP endpoint
is configured — HTTP request duration per route, SQL and DB-pool timings, queue job outcomes, SSE
connection counts, cache hit rates, and LLM latency/token usage — exported to
`<endpoint>/v1/metrics` on an interval. No middleware, no SDK wiring
(`example/learn/lesson73-metrics.tesl`).

```tesl
fn completeSignup(plan: String) -> String requires [] =
  let _ = counter "signup.completed" 1 [Tuple2 "plan" plan]
  "welcome"
```

---

## Runtime cost

Most of Tesl's safety guarantees are *compile-time only* and disappear before your program runs: if
it's a proof or a capability, the static cost is essentially zero; if it's actual work (validating a
value, reading a cookie, executing a query), it runs exactly once, at the right moment, and never
again. The full per-feature table — proofs, `check`, capabilities, `ForAll`, ADTs, newtypes,
`telemetry`, and auth — is single-sourced in the canonical
[proof cost model](best-practices.md#proof-cost-model).

---

## At a glance

| What you get | How Tesl delivers it |
|---|---|
| Validate once, trust everywhere | Proof annotations flow through your call graph at compile time |
| No defensive re-checking | A validated value carries its proof — downstream code declares what it needs |
| Auth that the compiler enforces | Auth produces a proof; handlers without it simply won't type-check |
| Self-documenting side effects | `requires [...]` is the function's capability contract, verified statically |
| Typed SQL, no ORM magic | Field names checked at compile time; generated SQL is always parameterised |
| ADTs stored as JSONB | One serialization format for HTTP and DB; variants with data round-trip correctly |
| Type-safe DB results | Every `select` and `insert` auto-annotates with `FromDb` origin proof |
| Schema from entity declarations | Tables created from `entity` blocks; missing columns flagged at startup |
| Background jobs, no Redis | `queue` + `worker` declarative syntax, backed by PostgreSQL |
| Real-time push, one port | `sse` + `sseChannel` on standard HTTP; browser `EventSource` reconnects automatically |
| AI agents with typed tools | `Agent { … }` constructor; `asTool fn` derives the tool's JSON Schema from parameter types |
| Dead-letter queues built in | `deadWorker` handles exhausted retries declaratively |
| Property-based tests | `property` blocks built into the language, no library needed |

---

## The theory behind it (if you're curious)

Tesl is built on two well-established ideas from programming language research, combined in a way that
keeps the surface syntax practical.

### Ghosts of Departed Proofs (GDP)

The proof-annotation system — `value ::: Predicate value` — is an implementation of
[Ghosts of Departed Proofs](https://kataskeue.com/gdp.pdf) (Noonan, 2018). The core insight is that
you can attach arbitrary compile-time *evidence* to a value using phantom types, without changing the
value's runtime representation. In Tesl this is realised literally: the proof is erased during
compilation and exists only in the static checker — including under `--debug`. The debugger overlays a
binding's proof/type from compile-time information and shows the raw runtime value, so it needs no
runtime struct.

If you have used **F# units of measure**, you have seen a restricted version of this idea: `float<kg>`
and `float<m>` are the same at runtime but the compiler keeps them distinct. GDP generalises this —
instead of just tracking units, you can track any predicate (`ValidTitle`, `FromDb`, `Authenticated`),
and you can compose predicates with `&&`, extract them with pattern matching, and pass them across
function boundaries.

If you have looked at **Scala's Refined library** (`Refined[String, NonEmpty]`) or **Haskell's**
`newtype` + phantom type tricks, you are in familiar territory. The main difference is that Tesl bakes
this into the language syntax (`:::`, `check`, `establish`) rather than requiring library machinery.

The key guarantee GDP gives you: a proof predicate is *unforgeable* outside the boundary where it was
produced. Only `check`, `establish`, and `auth` functions can stamp a value with a new predicate —
normal functions cannot, and the compiler enforces this. This is what makes the `Authenticated` proof
meaningful: you cannot construct one by accident or malice anywhere outside the auth function.

**`check` vs `establish`.** There are two kinds of proof-producing functions:

- **`check f(x) -> x: T ::: P x`** — fallible validation: can return a proof *or* fail with an HTTP
  error. Used at HTTP boundaries and any point where the input might be invalid.

```tesl
check isValidPort(p: Int) -> p: Int ::: ValidPort p =
  if 1 <= p && p <= 65535 then
    ok p ::: ValidPort p
  else
    fail 400 "port out of range"
```

- **`establish f(x) -> Fact (P x)`** — total proof: always succeeds, returning a `Fact` value. Used
  when you can guarantee the proof without risk of failure (e.g. values already validated, values
  derived from DB results). The body returns proof constructors directly — no `ok` or `fail`:

```tesl
establish provePositive(n: Int) -> Fact (IsPositive n) =
  IsPositive n
```

For conditional proofs where the caller already holds the value, return `Maybe (Fact (P))`:

```tesl
establish validPort(p: Int) -> Maybe (Fact (ValidPort p)) =
  if 1 <= p && p <= 65535 then
    Something (ValidPort p)
  else
    Nothing
```

When the value and its proof are produced together inside the function, use the `Maybe (v: T ::: P v)`
form — the proof propagates automatically through `case`:

```tesl
fact AllPositive (t: Tree)

check checkAllPositive(t: Tree) -> t: Tree ::: AllPositive t = ...

# Returns the validated tree with proof, or Nothing
fn maybeValidTree(t: Tree) -> Maybe (v: Tree ::: AllPositive v) =
  if someCondition(t) then
    let valid = check checkAllPositive t
    Something valid
  else
    Nothing

fn processPositiveTree(t: Tree ::: AllPositive t) -> Int = ...

fn use(raw: Tree) -> Int =
  let m = maybeValidTree raw
  case m of
    Nothing -> 0
    Something v -> processPositiveTree v   # v carries AllPositive v automatically
```

### Capability-based effect tracking

The `requires [...]` system is an *effects system* — a way of tracking what side effects a function
may perform. This is a well-studied area of type theory (Gifford & Lucassen, 1986; Koka, Effekt, and
others), but Tesl takes a deliberately simple and practical approach: capabilities are just names that
form a lattice (`capability chatService implies chatRead, chatWrite`), and the compiler checks that
every function only uses what it declared.

This is conceptually close to **algebraic effects** (as in F# computation expressions or Scala's ZIO
environment type `ZIO[R, E, A]`) but without the monadic ceremony. In Tesl, `requires [dbRead]` is a
flat annotation, not a type parameter — easy to read, easy to grep, easy to reason about in a code
review.

### How Tesl is implemented

Tesl compiles to [Racket](https://racket-lang.org/), a Lisp dialect with a strong macro system. The
compiler is centered on a large OCaml frontend (plus a trusted Racket runtime substrate), with
explicit stages: parsing/module loading, structural type checking, proof-aware checking, and Racket
emission. This means:

- The generated code is readable and debuggable
- The Racket ecosystem (libraries, tooling, REPL) is available for advanced use cases
- Proof annotations drive the static-checking pass; the proof is then erased (see the
  [proof cost model](best-practices.md#proof-cost-model)) and exists only at compile time

The compiler runs two orthogonal static-checking passes:

**Structural type checking** (Hindley–Milner style) — catches ordinary type mistakes at compile time.
Passing `1` to `Dict.fromList`, calling `String.length 42`, using a plain `Int` where a `PosixMillis`
timestamp is expected, reading a missing record field, returning a non-packed value from an
existential-return function, writing mixed-type arithmetic/boolean/comparison expressions, or calling
proof-total stdlib APIs like `Int.divide`, `Float.div`, `List.take`, or `Dict.get` without first
obtaining the required proof (`IsNonZero`, `FloatNonZero`, `IsNonNegative`, `HasKey`) are all compile
errors. Function values remain first-class: bare `f` is the function, while `f()` is an explicit
zero-argument call. This pass uses Robinson unification and let-generalisation.

**Integer range.** `Int` in Tesl is **arbitrary-precision** (unbounded), matching the Racket
integer runtime, which transparently spans fixnums and bignums. Integer literals of any size are
accepted — there is no compile-time range check — and arithmetic never overflows: results that
exceed the native fixnum range are automatically represented as bignums.

**GDP proof checking** — verifies that proof predicates (`ValidTitle title`, `Authenticated user`,
`FromDb id`) flow correctly through the call graph. This is a fixed set of structural rules applied
top-down, making error messages specific and actionable rather than cryptic.

The two layers are independent: structural types describe what values *are*; proof annotations
describe what we *know* about them. For example, passing an unvalidated string to a function that
requires a proof:

```text
$ tesl validate api.tesl
api.tesl:47: tesl compile error
  argument `email` in call to `sendWelcome` requires proof `ValidEmail email`
  the value has type `String` but does not carry the `ValidEmail` proof
  hint: use a `check` function to validate it first:
    check validateEmail(email: String) -> email: String ::: ValidEmail email = ...
```

No stack traces. No type variable soup. Just what went wrong and how to fix it.

### Deployment

Tesl produces Racket source (`.rkt` files) that run on the Racket VM. The standard production deploy
is a Docker image built by `tesl build` — see [Deploying a Tesl web API](deploy.md) for the image
flavours, runtime config, and CI workflow. A standalone-executable builder is also available today via
`tesl --exe <file> [--out <path>]` (it shells out to `raco exe`; needs `raco` on PATH).

### Structured logging

Set `TESL_VERBOSE=1` at runtime to activate structured log lines on stderr for every HTTP
request/response, SQL query, queue operation, and pub/sub event:

```bash
TESL_VERBOSE=1 tesl run your-app.tesl
```

Example output:

```text
[TESL][HTTP] → POST /todos
[TESL][SQL] insert into "todos" ("id", ...) values ($1, ...) [todo-abc, ...]
[TESL][HTTP] ← 201 POST /todos (12ms)
```

When `TESL_VERBOSE` is unset or `0`, there is zero per-call overhead — the flag is evaluated once at
module load time.

### Editor and Language Server

The `editor/` directory contains a VSCodium/VS Code extension (`editor/vscode-tesl/`) and an LSP
server (`editor/tesl-lsp/`) that provides live diagnostics, go-to-definition, hover types,
completions, and occurrence highlighting. See [`INSTALL.md`](../INSTALL.md) for installation
instructions.

### Package ecosystem

Tesl's standard library covers strings, lists, time, HTTP, and basic types. For anything outside it —
JWT parsing, Stripe integration, email — a thin Racket shim works today, since Tesl compiles to
Racket. A first-party Tesl package manager is on the roadmap.

### Scope

Tesl is intentionally narrow: HTTP handlers, PostgreSQL queries, validation, background jobs, and
real-time events. It is not a general-purpose language. If you want to write a CLI tool or parse
binary protocols, reach for something else. Within the web-API slice, it covers the common cases
completely.

---

## Logo, tagline, and mascot

**Tagline:** *Proof-carrying web APIs, for humans and AI agents.*

**Mascot — Tess the Type Seal:** A friendly seal. Tess is warm and encouraging — the kind of compiler
that says "here's exactly what went wrong and here's how to fix it" rather than a wall of stack trace.
When she's happy, she stamps your code approved. When there's a type error, she puts on a magnifying
glass and points helpfully at the exact problem, never scolding.

The seal metaphor: a **seal of approval** (validated data), **sealing a type** (nominal newtypes that
prevent accidental misuse), and a creature that is both playful and capable of navigating complex
environments with ease.

---

## Getting started

Ready to try it? Install Tesl and scaffold a project:

```bash
nix profile install github:mtonnberg/tesl
tesl init myapi --yes
cd myapi
tesl run app.tesl     # serves on http://localhost:8086
```

See [`INSTALL.md`](../INSTALL.md) for full installation options (home-manager, NixOS modules, editor
setup). The `example/learn/` folder contains 70+ lessons from hello world through ADTs, proofs,
database queries, queues, and real-time SSE — each a small, runnable `.tesl` file with inline
explanations, browsable via `tesl help manual examples`.

---

## See also

- [Manual Index](MANUAL.md) — back to the main manual
- [Overview](overview.md) — the one-screen concept explanation and core principles
- [Getting Started](GETTING-STARTED.md) — install and build your first API step by step
- [Best Practices](best-practices.md) — patterns, naming, testing, and the proof cost model
- [LANGUAGE-SPEC.md](../LANGUAGE-SPEC.md) — the formal specification (source of truth)
