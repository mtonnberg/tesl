# Tesl | Joyfully unbreakable APIs.

**Tesl** is a high-velocity programming language for building unbreakable, production-ready APIs without the infrastructure tax. By treating validation as a first-class citizen, Tesl ensures that once data is checked, the compiler "remembers" the performed check - structurally eliminating defensive boilerplate and the logic bugs that plague traditional stacks. With built-in job queues and real-time pub/sub, Tesl provides the operational simplicity to ship your MVP today and the fearless refactoring to scale it tomorrow. It is the definitive engine for product engineering—the shortest path from your business logic to a reliable, global system you can trust with total confidence.

---

## The problem it solves

In most frameworks you validate at the boundary and then... hope. The validated data is still the same type as unvalidated data, so nothing stops it from getting mixed up — or from a function deep in the call stack receiving raw input and skipping the check.

```
// Typical C#/TypeScript pattern
string title = request.Body.Title;  // could be anything
// ...passed through 3 layers...
await db.Todos.AddAsync(new Todo { Title = title });  // was it validated? hard to tell
```

Tesl solves this at the type level. A `check` function doesn't just validate — it *annotates* the value with proof that it passed. That proof is carried in the type signature wherever the value travels.

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

`check` is like a function that returns `Result<T, Error>` — except instead of wrapping the value in a `Some`/`Ok`, it *stamps* the original value with a proof. The `:::` annotation is the stamp. The check runs **once**, at the validation boundary, and never again.

**Runtime cost — erased by default:** After a successful `check`, the proof is a *compile-time* fact. In a normal (release) build the proof-tracking machinery — the `named-value` struct, the per-argument re-validation, the proof-environment threading — is **erased during macro expansion**: by the time your code runs there is no wrapper and no allocation for standard `check`/`fn`/`handler` paths. This was switched on by default once a differential audit proved the erased program behaves identically to the runtime-checked one across the whole corpus (byte-identical emitted code, 80/80 behavioral parity, ~1,150 negative tests). On proof-annotated calls this is ~81% faster with ~47% less allocation; proof-*free* parameters cost exactly zero.

**The "(almost)":** A few things deliberately keep a minimal runtime representation. Free-floating proofs (`detachFact`, `attachFact`) are first-class values explicitly passed around, so they carry a small token; a proof-*annotated* parameter keeps a single allocation so `detachFact`/decomposition still work on it; and `establish`/`Fact`, existential `pack`/`unpack`, newtype nominal wrappers, and DB-sourced (`FromDb`) proofs retain their carriers.

**Even debug builds erase.** Proofs are erased under `--debug` too. The debugger's Variables panel shows the raw runtime value, and a binding's proof/type is *compile-time* information (exactly what hover / `--type-at` report), so the debugger overlays it from there rather than from runtime structs. Breakpoints and stepping (`thsl-src!` checkpoints) are emitted separately and unaffected.

**mutation testing** Since the check function is where crititical bugs can creep in Tesl has built in mutation testing for all check, establish and auth functions.

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

When Tesl decodes a `NewTodo` from a request body, it runs `isValidTitle` automatically. If it fails, the request is rejected with a 400 before your handler even runs. If it passes, the `title` field carries the `ValidTitle` proof.

If an endpoint needs a separate wire shape, write the adapter explicitly in the API declaration: `body req: Domain from Wire via decodeWire` and `response Wire via encodeWire`. These adapters must be declared Tesl functions so the compiler can verify them at compile time. `decodeWire` must accept exactly one raw `Wire` value and return `Domain` (including any required body proof unless the endpoint uses a `body ... via (...)` boundary checker). `encodeWire` must accept the raw handler return value and return `Wire`. The `Wire` type still needs a visible codec because it is the type that crosses the HTTP boundary.

## Client generation
Tesl can also generate client-facing artifacts from the same API declarations that drive the server surface.

Today that mainly means:
- `tesl --ir file.tesl` for a frontend-facing JSON view of records, facts, codecs, and endpoints
- `tesl generate ts` / `tesl --generate-ts` for a TypeScript client that uses Zod
- `tesl generate elm` / `tesl --generate-elm` for an Elm client that preserves proof-carrying values with `mtonnberg/refinement-proofs`

The point is not just convenience. Tesl already knows:
- the request and response shapes
- the codecs that cross the HTTP boundary
- which facts are simple enough to mirror on the client
- which facts remain server-only

That lets the generated clients stay close to the actual API contract instead of drifting into a hand-maintained second definition.

Because the API layer, database JSONB layer, and generated clients all lean on the same declared codecs and type shapes, Tesl can reuse one wire-format story across the stack instead of maintaining separate ad hoc schemas for each consumer.

> Note: the generated TypeScript and Elm clients, along with the frontend-facing IR they depend on, are still experimental in the current alpha and may change aggressively.

In practice that means the feature is already useful, but you should still expect sharp edges:
- names and emitted helper shapes may still change
- not every proof can be mirrored client-side yet
- the TS and Elm generators still consume the compiler AST directly rather than going through one fully normalized internal frontend IR

The long-term goal is for the client surface to feel like a natural extension of the language: define the API once, and get a trustworthy server, wire contract, and frontend client story from the same source.

### 3. Declare what you need — the compiler checks the rest

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

The handler signature tells you everything: it needs an authenticated user, a valid request body, database read/write access, a clock, and a random source. The compiler verifies all of it. The `exists todoId =>` in the return type is Tesl's way of saying "I created a new entity and here's the proof it exists in the database" — the caller gets a `Todo` that the compiler knows came from a real insert.

---

## Key features

### Auth is a compile-time guarantee

Auth in most frameworks is a runtime concern — a middleware attribute, a guard, something that runs before your handler. If you forget it, nothing tells you until a request hits.

In Tesl, auth produces a proof. A handler that declares `user: User ::: Authenticated user` simply cannot be called with an unauthenticated user — the compiler rejects it.

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

Every function lists what it touches. Think of it as dependency injection, but enforced by the compiler rather than at runtime.

```tesl
capability todoRead  implies dbRead
capability todoWrite implies dbWrite
capability todoService implies todoRead, todoWrite, time, random

handler listTodos(user: User ::: Authenticated user)
  -> List Todo
  requires [todoRead] =       # declares: this function reads the DB
  select todo from Todo where todo.ownerId == user.id
```

If you add a database write and forget to update `requires`, the compiler tells you immediately. If you call a function that requires `todoWrite` from a context that only has `todoRead`, the compiler rejects it. No surprises in production. Capabilities are a compile-time concept — they have zero runtime representation and zero runtime cost.

### Typed SQL — no ORM magic, no string column names

Tesl doesn't generate SQL from object graphs (Entity Framework style) and it doesn't ask you to write raw SQL strings (Dapper style). You write SQL-shaped queries using the field names from your entity declaration, and the compiler checks every field reference at compile time.

Start by declaring your entity — this is the single source of truth for both the schema and the query types:

```tesl
entity Todo table "todos" primaryKey id {
  id:        String
  title:     String
  ownerId:   String     @db(text)
  status:    Status                  # Status is an ADT — stored as text, decoded automatically
  createdAt: PosixMillis
}
```

Then query it. Field names are checked by the compiler — misspell `ownerId` and you get a compile error, not a runtime crash:

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

There is no query builder, no expression tree, no reflection. The generated SQL is always parameterised (`WHERE owner_id = $1`) — SQL injection is structurally impossible because user data never appears as literal SQL text.

**Atomic writes with `transaction`**

When two or more writes must either all succeed or all fail, wrap them in `transaction`:

```tesl
transaction {
  let _ = insert User { id: userId, name: name }
  insert Profile { userId: userId, bio: "" }
}
```

The block returns the value of its last expression. Any exception inside rolls back everything. Transactions cannot be nested — a `transaction` inside another `transaction` is a compile error, caught before you run a line. Note that adding items to a queue can also be in a transaction with an insert for instance.

Column type mapping is automatic for all common types — you rarely need to annotate anything:

| Tesl type | PostgreSQL column | Notes |
|---|---|---|
| `String` | `TEXT NOT NULL` | |
| `Int` | `BIGINT NOT NULL` | |
| `Bool` | `BOOLEAN NOT NULL` | |

Use `Bool` in Tesl source code. `BOOLEAN` here describes the SQL storage type, not an alternate Tesl type spelling.
| `PosixMillis` | `BIGINT NOT NULL` | Auto-coerced; no annotation needed |
| Any ADT | `JSONB NOT NULL` | Encoded as `{"tag":"ConstructorName","fields":{...}}` |
| Newtype wrapping `String` | `TEXT NOT NULL` | Unwrapped transparently on read/write |
| `Maybe T` | Nullable column for `T` | Maps to SQL `NULL`; `Nothing` ↔ `NULL`, `Something v` ↔ the value |

`@db(type)` lets you override when you need a specific PostgreSQL type (e.g., `@db(uuid)` for a UUID column). For the common cases above, leave it off.

**ADTs are stored as JSONB**

This deserves a callout. An ADT field — whether it is a simple flag like `Status = Open | Done` or a richer union like `JobResult = Delivered messageId:String | Failed reason:String | Pending` — is automatically stored as a PostgreSQL `JSONB` column with no annotation required:

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

There are two practical benefits to this over storing the constructor name as plain text:

First, ADT *variants with data* round-trip correctly. A `Delivered "msg-123"` value survives a write and read back as exactly `Delivered "msg-123"` — the payload is preserved in the JSON object, not truncated.

Second, it means there is only one serialization format across the entire stack. The JSON encoding Tesl uses for HTTP response bodies is the same encoding used for database storage. No separate codec, no mismatch between what a client sees and what is in the database.

JSONB also opens the door to querying on ADT structure in the future. Today you can filter on equality of simple fields; the roadmap includes extending the SQL layer to support patterns like:

**Parameterized ADTs — generic containers**

You can declare ADTs with type parameters, just like `List a` or `Maybe a` in the standard library. List the lowercase parameter names after the type name:

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

# A pair of two values of (possibly different) types
type Pair a b
  = Pair first:a second:b
```

Pattern matching works the same way — the type parameter controls what type you get when you bind a field:

```tesl
fn extractResult(r: DomainResult Int, default: Int) -> Int =
  case r of
    Success value  -> value
    ValidationError _ -> default
    NotFound          -> default
```

The compiler infers type arguments — you never write them explicitly. Type parameters are erased at runtime so there is no overhead versus a concrete ADT. `Maybe`, `Result`, `Either`, `List`, `Dict`, `Set`, and `Tuple2`/`Tuple3` in the standard library are all parameterized ADTs.

```tesl
# planned — not yet in the language
selectOne task from Task where task.result == Delivered "msg-123"
# compiles to: WHERE result @> '{"tag":"Delivered","fields":{"messageId":"msg-123"}}'::jsonb
```

PostgreSQL has native GIN indexes for JSONB containment queries, so this will be fast even on large tables.

The mental model is closer to **Doobie** (Scala) or **SqlCommand with typed parameters** (.NET) than to an ORM — you write the query, you see the SQL, there are no surprises. The difference is that field names are resolved at compile time and the result type is inferred, so you get type safety without the ceremony.

**`PosixMillis` — timestamps without timezone drama**

`PosixMillis` is a nominal type for timestamps (ms since epoch). Being a newtype, the compiler rejects accidentally passing a duration where a timestamp is expected. It auto-maps to `BIGINT` in PostgreSQL with no annotation, and `Date.now()` on the frontend reads it directly — no conversion layer, no timezone surprises.

### Schema and migrations

Tesl derives the database schema directly from your `entity` and `database` declarations. On first run it creates any missing tables automatically — no separate migration file needed to get started:

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

This is intentionally optimistic for development — spin up a fresh database and `tesl run` just works. For production, a dedicated migration tool is on the roadmap. The current approach is: Tesl owns the schema declaration; you own the migration strategy. If you add a column to an entity, Tesl tells you at startup if it is missing — then you decide how to apply the change (a migration script, `ALTER TABLE`, whatever your deployment allows).

The key constraint Tesl does enforce: you cannot reference a field in a query that is not in the entity declaration. If you remove a field from the entity, every query and handler that touches it becomes a compile error — so you always know the full blast radius of a schema change before you touch the database.

### Queues and background workers — no infrastructure glue

Setting up Hangfire or a Redis-backed job queue takes real configuration. In Tesl, queues are first-class declarations.

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
(`Job <JobType> <workerFn> <deadLetterSlot>`) — there is no separate `workers`
declaration. Use `Nothing` for no dead-letter handler, or `(Something deadFn)` to
attach one.

Jobs are stored in PostgreSQL using `FOR UPDATE SKIP LOCKED` for safe concurrent dequeue. No Redis. No separate service. Retry with exponential backoff is declarative. Dead-letter queues for failed jobs are a built-in `deadWorker` declaration.

### Real-time push — one port, no WebSocket proxy

SSE (Server-Sent Events) runs on the same HTTP port as your REST endpoints. No separate WebSocket server, no nginx config, no reconnection logic — the browser's native `EventSource` handles it.

```tesl
sseChannel RoomMessages(roomId: String) = SseChannel {
  database: ChatDatabase
  payload: RoomEvent
}

# Publish from inside a transaction — atomically with your DB writes:
transaction {
  publish RoomMessages(roomId) NewMessage { content: req.content, ... }
  insert Message { ... }
}

# Subscribe from an SSE endpoint:
sse "/events/rooms/:roomId"
  auth    session: User ::: Authenticated session via cookieAuth
  capture roomId:  String ::: ValidRoomId roomId via roomIdCapture
  subscribe RoomMessages(roomId)
```

Horizontal scaling uses PostgreSQL `LISTEN/NOTIFY`. No separate message broker.

### Type-safe list filtering (ForAll proofs)

When a `select` query runs, Tesl annotates the result list with proof of its origin. Filter the list and the proof expands rather than disappears — similar to how F# `Seq.filter` preserves the element type, except here it also preserves the proof.

```tesl
# Return type says: every element is owned by this user AND is open
handler listOpenTodos(user: User ::: Authenticated user)
  -> List Todo ::: ForAll (FromDb (OwnerId == user.id) && IsOpen)
  requires [todoRead] =
  let mine = select todo from Todo where todo.ownerId == user.id
  List.filterCheck(checkOpen, mine)   # filterCheck expands the proof, never removes it
```

A function that accepts `List Todo ::: ForAll (IsOpen)` cannot receive a plain `List Todo` — the compiler enforces that filtering actually happened. At runtime a `ForAll`-annotated list is a plain list with no extra wrapping — the annotation is erased after type-checking, so there is no per-element boxing, no extra allocations, and no measurable overhead versus a regular filter.

### Tesl-native API tests

Tesl can test the full HTTP boundary from inside the language. `api-test` blocks exercise routing, auth, codecs, database effects, queues, and SSE without dropping to Racket.

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

Every `api-test` runs against a fresh in-memory database unless the CLI is told to use a real test database. Response bodies are raw `JsonValue`s on purpose: the goal is to verify the wire contract your clients actually see. `Tesl.ApiTest` provides helpers for status ranges, JSON extraction, SSE collection, and deterministic worker processing.

### ADTs and pattern matching

Tesl has sum types with exhaustive pattern matching — the same model you know from F# discriminated unions or Scala sealed traits.

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

The compiler rejects non-exhaustive `case` expressions. Add a new constructor and every unhandled `case` becomes a compile error.

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

A variable or wildcard catch-all arm is required for `Int` and `String` since they have infinite domains.

**Nested constructor patterns.** A field can be a sub-pattern that matches inside a nested constructor, eliminating the need for an inner `case` expression:

```tesl
type Wrapped = Wrap inner: Maybe Int

fn extract(w: Wrapped) -> Int =
  case w of
    Wrap (Something n) -> n   # positional: parens wrap the sub-pattern
    Wrap Nothing       -> 0
```

For ADTs with multiple fields, use the labeled brace syntax:

```tesl
Wrap { inner = Something { value = n } } -> n
```

**ADTs in codecs.** When an ADT type appears as a field in a request record, declare a codec for it using `adtJson` — this tells Tesl to use the standard `{"tag": "ConstructorName"}` JSON format for both encoding and decoding:

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

The compiler validates that `with_codec Priority` is used on a field declared as `Priority` and that `Priority` has an `adtJson` codec — a type mismatch (e.g., `with_codec stringCodec` on a `Priority` field) is a compile error.

### OpenTelemetry is ambient

Observability is the one side effect that shouldn't require bureaucracy. Add `telemetry` calls anywhere — no capability declaration needed.

```tesl
handler listTodos(user: User ::: Authenticated user)
  -> List Todo
  requires [todoRead] =
  telemetry "todos.list" { user.id = user.id }   # zero overhead when not sampling
  select todo from Todo where todo.ownerId == user.id
```

---

## Runtime cost

Most of Tesl's safety guarantees are *compile-time only* and disappear before your program runs.

| Feature | Runtime cost |
|---|---|
| Proof annotations (`:::`) | **Zero by default.** Proof checking runs once at the validation boundary; the proof itself is a compile-time fact. In release builds the `named-value` struct, argument re-validation, and proof-env threading are **erased during expansion** — no wrapper, no allocation — for standard `check`/`fn`/`handler` paths (verified behavior-identical across the corpus). The "(almost)": free-floating proofs (`detachFact`/`attachFact`) carry a small token, a proof-annotated parameter keeps one allocation, and `establish`/existential/newtype/`FromDb` carriers are retained. Erased under `--debug` too. |
| `check` functions | Runs **once**, at the validation boundary. Never re-runs downstream. |
| Capabilities (`requires [...]`) | **Zero.** A compile-time contract with no runtime representation. |
| `ForAll` on lists | **Zero.** The list is a plain list at runtime; the annotation is erased. |
| ADTs / sum types | Normal tagged union struct. Equivalent to a C# discriminated union library. |
| Newtypes (`type UserId = String`) | Minimal — a thin wrapper struct that the runtime uses to enforce nominal distinctness. Unwrapped automatically on DB read/write and JSON encode/decode. |
| `telemetry` | **Zero** when not sampling. Guarded by a single boolean check at module load time. |
| Auth (`auth` functions) | Runs at request time — same as any middleware. The resulting proof carries a small runtime record in the current alpha (see proof annotations row). |

The short version: if it's a proof or a capability, the static cost is zero. If it's actual work (validating a value, reading a cookie, executing a query), it runs exactly once, at the right moment, and never again.

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
| Real-time push, one port | `sse` + `channel` on standard HTTP; browser `EventSource` reconnects automatically |
| Dead-letter queues built in | `deadWorker` handles exhausted retries declaratively |
| Property-based tests | `property` blocks built into the language, no library needed |

---

## The theory behind it (if you're curious)

Tesl is built on two well-established ideas from programming language research, combined in a way that keeps the surface syntax practical.

### Ghosts of Departed Proofs (GDP)

The proof-annotation system — `value ::: Predicate value` — is an implementation of [Ghosts of Departed Proofs](https://kataskeue.com/gdp.pdf) (Noonan, 2018). The core insight is that you can attach arbitrary compile-time *evidence* to a value using phantom types, without changing the value's runtime representation. In Tesl this is realised literally: the proof is erased during compilation and exists only in the static checker — including under `--debug`. The debugger overlays a binding's proof/type from compile-time information and shows the raw runtime value, so it needs no runtime struct.

If you have used **F# units of measure**, you have seen a restricted version of this idea: `float<kg>` and `float<m>` are the same at runtime but the compiler keeps them distinct. GDP generalises this — instead of just tracking units, you can track any predicate (`ValidTitle`, `FromDb`, `Authenticated`), and you can compose predicates with `&&`, extract them with pattern matching, and pass them across function boundaries.

If you have looked at **Scala's Refined library** (`Refined[String, NonEmpty]`) or **Haskell's** `newtype` + phantom type tricks, you are in familiar territory. The main difference is that Tesl bakes this into the language syntax (`:::`, `check`, `establish`) rather than requiring library machinery.

The key guarantee GDP gives you: a proof predicate is *unforgeable* outside the boundary where it was produced. Only `check`, `establish`, and `auth` functions can stamp a value with a new predicate — normal functions cannot, and the compiler enforces this. This is what makes the `Authenticated` proof meaningful: you cannot construct one by accident or malice anywhere outside the auth function.

**`check` vs `establish`.** There are two kinds of proof-producing functions:

- **`check f(x) -> x: T ::: P x`** — fallible validation: can return a proof *or* fail with an HTTP error. Used at HTTP boundaries and any point where the input might be invalid.

```tesl
check isValidPort(p: Int) -> p: Int ::: ValidPort p =
  if 1 <= p && p <= 65535 then ok p ::: ValidPort p
  else fail 400 "port out of range"
```

- **`establish f(x) -> Fact (P x)`** — total proof: always succeeds, returning a `Fact` value. Used when you can guarantee the proof without risk of failure (e.g. values already validated, values derived from DB results). The body returns proof constructors directly — no `ok` or `fail`:

```tesl
establish provePositive(n: Int) -> Fact (IsPositive n) =
  IsPositive n
```

  For conditional proofs where the caller already holds the value, return `Maybe (Fact (P))`:

```tesl
establish validPort(p: Int) -> Maybe (Fact (ValidPort p)) =
  if 1 <= p && p <= 65535 then Something (ValidPort p) else Nothing
```

  When the value and its proof are produced together inside the function, use the
  `Maybe (v: T ::: P v)` form — the proof propagates automatically through `case`:

```tesl
type Tree
  = Leaf
  | Node left:Tree value:Int right:Tree

fact AllPositive (t: Tree)

check checkAllPositive(t: Tree) -> t: Tree ::: AllPositive t = ...

# Returns the validated tree with proof, or Nothing
fn maybeValidTree(t: Tree) -> Maybe (v: Tree ::: AllPositive v) =
  if someCondition t then
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

The `requires [...]` system is an *effects system* — a way of tracking what side effects a function may perform. This is a well-studied area of type theory (Gifford & Lucassen, 1986; Koka, Effekt, and others), but Tesl takes a deliberately simple and practical approach: capabilities are just names that form a lattice (`capability chatService implies chatRead, chatWrite`), and the compiler checks that every function only uses what it declared.

This is conceptually close to **algebraic effects** (as in F# computation expressions or Scala's ZIO environment type `ZIO[R, E, A]`) but without the monadic ceremony. In Tesl, `requires [dbRead]` is a flat annotation, not a type parameter — easy to read, easy to grep, easy to reason about in a code review.

### How Tesl is implemented

Tesl compiles to [Racket](https://racket-lang.org/), a Lisp dialect with a strong macro system. The compiler is centered on a ~10 000-line OCaml frontend, with explicit stages: parsing/module loading, structural type checking, proof-aware checking, and Racket emission. This means:

- The generated code is readable and debuggable
- The Racket ecosystem (libraries, tooling, REPL) is available for advanced use cases
- Proof annotations drive the static-checking pass; the proof is then erased (see the cost table above) and exists only at compile time

The compiler runs two orthogonal static-checking passes:

**Structural type checking** (Hindley–Milner style) — catches ordinary type mistakes at compile time. Passing `1` to `Dict.fromList`, calling `String.length 42`, using a plain `Int` where a `PosixMillis` timestamp is expected, reading a missing record field, returning a non-packed value from an existential-return function, writing mixed-type arithmetic/boolean/comparison expressions, or calling proof-total stdlib APIs like `Int.divide`, `Float.div`, `List.take`, or `Dict.get` without first obtaining the required proof (`IsNonZero`, `FloatNonZero`, `IsNonNegative`, `HasKey`) are all compile errors. Function values remain first-class: bare `f` is the function, while `f()` is an explicit zero-argument call. This pass uses Robinson unification and let-generalisation.

**Integer range.** `Int` in Tesl is a 63-bit signed fixnum (the native Racket fixnum on 64-bit platforms). The valid range is `−2^62` to `2^62 − 1` (i.e., `−4611686018427387904` to `4611686018427387903`). Integer literals outside this range are rejected at compile time.

**GDP proof checking** — verifies that proof predicates (`ValidTitle title`, `Authenticated user`, `FromDb id`) flow correctly through the call graph. This is a fixed set of structural rules applied top-down, making error messages specific and actionable rather than cryptic.

The two layers are independent: structural types describe what values *are*; proof annotations describe what we *know* about them.

For example, passing an unvalidated string to a function that requires a proof:

```
$ tesl check api.tesl
api.tesl:47: tesl compile error
  argument `email` in call to `sendWelcome` requires proof `ValidEmail email`
  the value has type `String` but does not carry the `ValidEmail` proof
  hint: use a `check` function to validate it first:
    check validateEmail(email: String) -> email: String ::: ValidEmail email = ...
```

No stack traces. No type variable soup. Just what went wrong and how to fix it.

**Deployment.** Tesl produces Racket source (`.rkt` files) that run on the Racket VM. The standard production deploy is a Docker image based on `racket/racket` with your compiled files. A standalone binary builder (via `raco exe`) is on the roadmap.

**Structured logging.** Set `TESL_VERBOSE=1` at runtime to activate structured log lines on stderr for every HTTP request/response, SQL query, queue operation, and pub/sub event:

```bash
TESL_VERBOSE=1 tesl run your-app.tesl
```

Example output:
```
[TESL][HTTP] → POST /todos
[TESL][SQL] insert into "todos" ("id", ...) values ($1, ...) [todo-abc, ...]
[TESL][HTTP] ← 201 POST /todos (12ms)
```

When `TESL_VERBOSE` is unset or `0`, there is zero per-call overhead — the flag is evaluated once at module load time.

**Editor and Language Server.** The `editor/` directory contains a VSCodium/VS Code extension (`editor/vscode-tesl/`) and an LSP server (`editor/tesl-lsp/`) that provides live diagnostics, go-to-definition, hover types, completions, and occurrence highlighting. See `editor/README.md` for installation instructions.

**Package ecosystem.** Tesl's standard library covers strings, lists, time, HTTP, and basic types. For anything outside it — JWT parsing, Stripe integration, email — a thin Racket shim works today, since Tesl compiles to Racket. A first-party Tesl package manager is on the roadmap.

**Scope.** Tesl is intentionally narrow: HTTP handlers, PostgreSQL queries, validation, background jobs, and real-time events. It is not a general-purpose language. If you want to write a CLI tool or parse binary protocols, reach for something else. Within the web-API slice, it covers the common cases completely.

---

## Logo, tagline, and mascot

**Tagline:** *Joyfully unbreakable APIs.*

**Mascot — Tess the Type Seal:** A friendly seal.

Tess is warm and encouraging — the kind of compiler that says "here's exactly what went wrong and here's how to fix it" rather than a wall of stack trace. When she's happy, she stamps your code approved. When there's a type error, she puts on a magnifying glass and points helpfully at the exact problem, never scolding.

The seal metaphor: a **seal of approval** (validated data), **sealing a type** (nominal newtypes that prevent accidental misuse), and a creature that is both playful and capable of navigating complex environments with ease.

---

## Getting started

```bash
# Try without installing anything:
nix run github:mtonnberg/tesl -- help

# Permanent install:
nix profile install github:mtonnberg/tesl
tesl help
```

See [`INSTALL.md`](INSTALL.md) for full installation options including home-manager, NixOS modules, and editor setup.

The `example/learn/` folder contains 47 lessons from hello world through ADTs, proofs, database queries, queues, and real-time SSE — each as a small, runnable `.tesl` file with inline explanations.
