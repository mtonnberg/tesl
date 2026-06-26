# Library Support

*Status: Design exploration — not yet implemented*

---

## Why Libraries Come Before a Package Manager

The [package manager roadmap](package_manager.md) depends on a clear answer to: what is a publishable unit? Right now every Tesl file is part of a single application. The package manager needs libraries — modules that contain reusable logic, types, and proof predicates that can be versioned, published, and imported across projects.

This document explores what "library" means in Tesl, where the boundary sits between library and application code, and three concrete examples covering the spectrum from pure domain logic to infrastructure-adjacent patterns.

---

## The Library Boundary

### What a library IS

A library is a Tesl module (or collection of modules) that provides reusable:

- **Types**: records, ADTs, newtypes, aliases
- **Proof predicates**: `fact` declarations and the `check`/`establish` functions that create them
- **Domain functions**: pure `fn` functions, transformation logic
- **Auth functions**: `auth` declarations that extract and verify identity from requests
- **Handler functions**: `handler` declarations for HTTP endpoints
- **Worker functions**: `worker` and `deadWorker` declarations for queue processing
- **Capabilities**: abstract effect requirements
- **Codecs**: JSON encoding and decoding logic

### What a library is NOT

A library does **not** own infrastructure. These declarations are application-level and belong only in the application root:

| Declaration | Why it stays in the app |
|---|---|
| `database` | App owns its connection config and migration lifecycle |
| `entity` | Bound to a specific database; apps have different schemas |
| `queue` | App owns queue infrastructure, retry policy, database binding |
| `channel` | App owns the event stream and its database backing |
| `workers` block | Wires worker functions to a specific queue — app's concern |
| `deadWorkers` block | Same as workers |
| `api` block | Route declarations define the app's external contract |
| `server` block | Binds handlers to routes and starts the server |
| `main` block | Application entry point |

The key insight: **handler, worker, and auth functions are just functions** — they CAN live in libraries. What stays in the app are the *wiring blocks* (`api`, `server`, `workers`) that bind those functions to infrastructure. A library provides the logic; the application assembles it.

---

## The Re-Export Problem

Current Tesl prohibits re-exporting: if module A imports `ValidEmail` from `tesl-validate/Email`, it cannot include `ValidEmail` in its own `exposing [...]` list. This is intentional for single-project code — it keeps proof predicate ownership explicit and greppable.

For libraries, this creates a **transitive import burden**. Consider:

```
tesl-validate   →  defines ValidEmail fact
tesl-user       →  imports ValidEmail, builds UserProfile record with email: String ::: ValidEmail email
App             →  imports tesl-user, gets UserProfile back from handlers
```

The app uses `userProfile.email` and wants to pass it somewhere that requires `ValidEmail email`. But `ValidEmail` is not in the app's scope — the app has to also `import myorg/tesl-validate/Email exposing [ValidEmail]` even though it only directly depends on `tesl-user`.

This doesn't break correctness (the proof tags travel with the value), but it breaks ergonomics: the app must know about every transitive dependency that appears in its code's type signatures.

### Two options

**Option A — Explicit transitive imports (current behavior)**

The app imports every library whose types appear directly in app code. The compiler error message says "ValidEmail comes from myorg/tesl-validate/Email — add that import." Verbose but completely explicit.

**Option B — Re-export with preserved identity**

Libraries are allowed to re-export names from their dependencies, with the proof identity preserved. The name becomes available under the re-exporting library's surface, but the compiler knows the canonical source.

```tesl
# In myorg/tesl-user
module User exposing [
  UserProfile,
  ValidEmail,      # re-exported from myorg/tesl-validate/Email — identity preserved
  checkEmail,      # re-exported
  lookupUser,
]
import myorg/tesl-validate/Email exposing [ValidEmail, checkEmail]
```

App code:
```tesl
import myorg/tesl-user exposing [UserProfile, ValidEmail, checkEmail, lookupUser]
# ValidEmail is myorg/tesl-validate/Email.ValidEmail — same identity, just accessible here
```

This is closer to how TypeScript re-exports work: the type identity is preserved even when the name is re-exported.

**Recommendation**: Option B for libraries, Option A retained for within-project modules. The package manifest lists which names are primary exports vs. re-exports, allowing the API diff engine to correctly attribute proof ownership.

*This is a known open design question — the examples below use Option A for clarity.*

---

## Package Manifest

Every library has a `tesl.json` at its root:

```json
{
  "name": "myorg/tesl-validate",
  "version": "1.2.0",
  "description": "Common validation predicates for Tesl applications",
  "license": "MIT",
  "repository": "https://github.com/myorg/tesl-validate",
  "tesl": ">=0.8.0",
  "dependencies": {},
  "modules": [
    "src/Email",
    "src/Url",
    "src/Money",
    "src/PhoneNumber"
  ]
}
```

Import path convention: `packageName/ModuleName`, e.g.:
```tesl
import myorg/tesl-validate/Email exposing [ValidEmail, checkEmail]
```

---

## Example 1: `tesl-validate` — Pure Validation Predicates

This is the simplest and most common library type. Zero infrastructure dependency — just types, facts, and check functions that any application can import regardless of how it's deployed.

**What the library provides:**
- Proof predicates for common data formats
- Check functions that validate at HTTP boundaries
- Type aliases for common string subtypes

**File: `src/Email.tesl`**

```tesl
#lang tesl
module Lesson00HelloWorld exposing [
  ValidEmail,
  checkEmail,
  EmailAddress,
]

import Tesl.Prelude exposing [String]
import Tesl.String exposing [String.contains, String.length, String.trim]

type EmailAddress = String

fact ValidEmail (s: String)

check checkEmail(s: String) -> s: String ::: ValidEmail s =
  let trimmed = String.trim s
  if String.contains trimmed "@" && String.length trimmed >= 5 then
    ok trimmed ::: ValidEmail trimmed
  else
    fail 400 "invalid email address: must contain @ and be at least 5 characters"
```

**File: `src/Money.tesl`**

```tesl
#lang tesl
module Money exposing [
  NonNegativeCents,
  checkNonNegativeCents,
  PositiveCents,
  checkPositiveCents,
]

import Tesl.Prelude exposing [Int]

fact NonNegativeCents (n: Int)
fact PositiveCents (n: Int)

check checkNonNegativeCents(n: Int) -> n: Int ::: NonNegativeCents n =
  if n >= 0 then
    ok n ::: NonNegativeCents n
  else
    fail 400 "amount must be zero or positive"

check checkPositiveCents(n: Int) -> n: Int ::: PositiveCents n =
  if n > 0 then
    ok n ::: PositiveCents n
  else
    fail 400 "amount must be greater than zero"
```

**How the app uses it:**

```tesl
#lang tesl
module UserApi exposing [UserServer]

import myorg/tesl-validate/Email exposing [ValidEmail, checkEmail]
import myorg/tesl-validate/Money exposing [NonNegativeCents, checkNonNegativeCents]
import Tesl.Prelude exposing [String, Int]

record NewUserRequest {
  email: String    # codec will run checkEmail automatically via `via`
  balance: Int
}

codec NewUserRequest {
  fromJson [
    {
      email   <- "email"   with_codec stringCodec via checkEmail
      balance <- "balance" with_codec intCodec    via checkNonNegativeCents
    }
  ]
  toJson {
    email   -> "email"   with_codec stringCodec
    balance -> "balance" with_codec intCodec
  }
}

fn getEmail(req: NewUserRequest) -> String ::: ValidEmail email =
  req.email  # carries ValidEmail proof from codec decode
```

**Value delivered:** Every endpoint that decodes `NewUserRequest` gets proof-carrying email and balance fields automatically. The validation happens once at decode, not scattered through handlers. The library is 100% infrastructure-free and works in any Tesl application.

---

## Example 2: `tesl-auth-jwt` — Stateless JWT Authentication

JWT (JSON Web Tokens) are self-contained — verification requires only the signing secret, not a database. This makes JWT a natural fit for a library: the library provides the `auth` function; the application provides the secret (typically from an environment variable) and creates its own routes.

**What the library provides:**
- `Authenticated` fact predicate
- `JwtClaims` record type
- A ready-to-use `auth` function factory pattern
- Helper functions for claims extraction

**Why this works without a database:** JWT tokens are cryptographically signed. Verifying the signature and checking expiry is a pure computation — no storage lookup needed. Revocation (if needed) is an application concern: the app can wrap the library's auth with an additional revocation check against its own database.

**File: `src/BearerAuth.tesl`**

```tesl
#lang tesl
module BearerAuth exposing [
  Authenticated,
  JwtClaims,
  checkBearer,
  extractClaim,
  requireClaim,
]

import Tesl.Prelude exposing [String, Int, Fact]
import Tesl.Http exposing [HttpRequest]
import Tesl.Dict exposing [Dict, Dict.lookup]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.String exposing [String.startsWith, String.drop, String.length]
import Tesl.Time exposing [nowMillis]
import Tesl.Json exposing [stringCodec]

# The core proof predicate — carrying this means the request was authenticated
fact Authenticated (userId: String)

# Claims extracted from the JWT payload
record JwtClaims {
  sub: String           # subject (user ID)
  exp: Int              # expiry (unix timestamp ms)
  iss: String           # issuer
  extra: Dict String String  # any additional claims
}

# Extract the bearer token string from the Authorization header
fn extractBearerString(req: HttpRequest) -> Maybe String =
  case Dict.lookup "authorization" req.headers of
    Nothing -> Nothing
    Something header ->
      if String.startsWith "Bearer " header then
        Something (String.drop 7 header)
      else
        Nothing

# The auth function the application wires into its API
# Takes the JWT secret as a parameter — app provides this from env vars
auth checkBearer(secret: String, req: HttpRequest) -> userId: String ::: Authenticated userId
  requires [] =
  case extractBearerString req of
    Nothing ->
      fail 401 "missing or malformed Authorization header"
    Something tokenStr ->
      # JWT.verify raises fail 401 automatically if signature invalid or expired
      let claims = check JWT.verify tokenStr secret
      ok claims.sub ::: Authenticated claims.sub

# Helper: extract a specific claim from the JWT, useful for role checks
fn extractClaim(req: HttpRequest, secret: String, claim: String) -> Maybe String =
  case extractBearerString req of
    Nothing -> Nothing
    Something tokenStr ->
      case JWT.decode tokenStr of
        Nothing -> Nothing
        Something claims -> Dict.lookup claim claims.extra

# Helper: require a specific claim value (useful for role-based access)
fact HasRole (userId: String) (role: String)

establish requireRole(userId: String ::: Authenticated userId, role: String, claims: JwtClaims)
  -> Fact (HasRole userId role) =
  HasRole userId role
```

**How the application uses it:**

```tesl
#lang tesl
module MyApi exposing [MyServer]

import myorg/tesl-auth-jwt/BearerAuth exposing [Authenticated, checkBearer]
import Tesl.Env exposing [env]
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]

# App instantiates the auth function with its own secret
auth myAuth(req: HttpRequest) -> userId: String ::: Authenticated userId
  requires [] =
  let secret = env "JWT_SECRET"
  checkBearer secret req

api MyApi {
  get "/profile"
    auth user : String ::: Authenticated user via myAuth
    -> UserProfile
}

handler getProfile(user: String ::: Authenticated user) -> UserProfile requires [dbRead] =
  selectOne p from UserProfile where p.userId == user
```

**What the application owns:**
- The JWT secret source (`env "JWT_SECRET"`)
- The `myAuth` function that wires the secret in
- The API route declaration
- The server and database binding
- Any supplementary checks (revocation lists, role verification)

**What stays out of the library:**
- The library has no idea what secret the app uses
- The library has no database dependency
- The library does not declare any routes
- Multiple applications can use the same library with different secrets and routes

**Extending with revocation (app-side):**

If the app needs token revocation, it wraps the library's verification with its own check:

```tesl
auth myAuthWithRevocation(req: HttpRequest) -> userId: String ::: Authenticated userId
  requires [dbRead] =
  let secret = env "JWT_SECRET"
  # First: library does cryptographic verification
  let userId = checkBearer secret req
  # Then: app does its own revocation check
  case selectOne r from RevokedToken where r.userId == userId of
    Something _ -> fail 401 "token has been revoked"
    Nothing -> ok userId ::: Authenticated userId
```

The library handles the universal part (cryptographic verification); the application handles the application-specific part (revocation policy).

---

## Example 3: `tesl-audit-log` — Audit Trail with Queue Workers

Audit logging is a common cross-cutting concern: record who did what, when, to which resource. The challenge is that audit logging involves both synchronous proof creation (was this action audited?) and asynchronous persistence (write the audit record to the database).

This example shows how a library can provide both the synchronous proof machinery and the asynchronous worker function while the application owns all the infrastructure.

**What the library provides:**
- `AuditEvent` record type (the job payload)
- `Audited` proof predicate (proves an operation was logged)
- `auditEvent` helper function (creates an audit event and returns the proof)
- `processAuditEvent` worker function (persists the event — app provides its entity)
- `AuditableAction` ADT for standard action types

**What the application provides:**
- The `AuditLog` database entity (schema is app-controlled)
- The `auditQueue` queue declaration with its database binding
- The `workers` block wiring `processAuditEvent` to the queue
- The actual database write implementation (via entity + insert)

**File: `src/AuditLog.tesl`**

```tesl
#lang tesl
module AuditLog exposing [
  AuditEvent,
  AuditableAction,
  Audited,
  auditEvent,
  processAuditEvent,
]

import Tesl.Prelude exposing [String, Int]
import Tesl.Time exposing [nowMillis, PosixMillis, time]
import Tesl.Queue exposing [FromQueue, enqueue, queueWrite]
import Tesl.DB exposing [dbWrite]

# Standard actions — apps can extend with their own types by wrapping
type AuditableAction
  = Create
  | Read
  | Update
  | Delete
  | Login
  | Logout
  | Export
  | Custom label: String

# The job payload sent to the queue
record AuditEvent {
  userId:     String
  action:     AuditableAction
  resource:   String        # what was affected, e.g. "User/abc123"
  resourceId: String
  metadata:   String        # JSON string for extra context
  occurredAt: PosixMillis
}

# The proof predicate: carrying this proves the operation was submitted for audit
fact Audited (userId: String) (resource: String)

# Submit an audit event to the queue and return the Audited proof
# The app's queue is provided as a capability — library doesn't own it
fn auditEvent(
  userId:     String,
  action:     AuditableAction,
  resource:   String,
  resourceId: String,
  metadata:   String
) -> Unit ? Audited ::: Audited userId resource
  requires [queueWrite] =
  let ts = time nowMillis
  let event = AuditEvent {
    userId:     userId
    action:     action
    resource:   resource
    resourceId: resourceId
    metadata:   metadata
    occurredAt: ts
  }
  let _ = enqueue event
  () ::: Audited userId resource

# Worker function: processes an audit event from the queue
# The app MUST provide an entity called AuditLogEntry with these fields:
#   userId, action, resource, resourceId, metadata, occurredAt
# This is a design contract, not a compiler-enforced constraint (yet)
worker processAuditEvent(event: AuditEvent ::: FromQueue (Id == jobId) event)
  requires [dbWrite] =
  insert AuditLogEntry {
    userId:     event.userId
    action:     event.action
    resource:   event.resource
    resourceId: event.resourceId
    metadata:   event.metadata
    occurredAt: event.occurredAt
  }
```

**How the application wires it up:**

```tesl
#lang tesl
module TaskApi exposing [TaskServer]

import myorg/tesl-audit-log/AuditLog exposing [
  AuditEvent,
  AuditableAction,
  Audited,
  auditEvent,
  processAuditEvent,
]
import Tesl.Prelude exposing [String, Int, Unit]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Queue exposing [queueRead, queueWrite]

# App owns its database and the audit log entity
database AppDb {
  backend postgres
  schema  "app"
  entities [Task, AuditLogEntry]
  postgres { database "myapp" user "app" password "" host "localhost" port 5432 socket "" }
}

entity AuditLogEntry table "audit_log" primaryKey id {
  id:         Int
  userId:     String
  action:     String        # serialized from AuditableAction
  resource:   String
  resourceId: String
  metadata:   String
  occurredAt: PosixMillis
}

entity Task table "tasks" primaryKey id {
  id:     Int
  title:  String
  userId: String
}

# App owns the queue with its own database binding
queue AuditQueue {
  database AppDb
  jobs     [AuditEvent]
  retry    { maxAttempts: 5 backoff: exponential initialDelay: 1000 }
}

# App wires the library's worker function to its queue
workers AuditWorkers for AuditQueue {
  AuditEvent = processAuditEvent
}

# ── Using audit in a handler ──────────────────────────────────────────────

capability taskWrite implies dbWrite, queueWrite
capability taskRead  implies dbRead

handler createTask(userId: String, title: String)
  -> Unit ? Audited ::: Audited userId "Task"
  requires [taskWrite] =
  let _ = insert Task { title: title userId: userId }
  auditEvent userId Create "Task" userId "{\"title\": \"${title}\"}"
```

**What the library owns:**
- The `AuditEvent` type (the queue job format)
- The `Audited` proof predicate and how it's created
- The `processAuditEvent` worker function (the persistence logic)
- The business logic of what an audit event is

**What the application owns:**
- `AppDb` — the actual database connection
- `AuditLogEntry` — the database entity (the library specifies what fields it needs, but the app declares the entity)
- `AuditQueue` — the queue with its retry policy and database binding
- `AuditWorkers` — the wiring of the worker function to the queue
- The main entry point that starts workers

**The entity contract:** This reveals a real design gap. The library's `processAuditEvent` worker writes to `AuditLogEntry`, but the entity is declared by the app. The library depends on the app having an entity with specific fields. Currently, this is an informal contract (comment in the library code). Future Tesl versions could formalize this as an "entity interface" or "entity shape requirement" that the compiler verifies.

---

## Harder Cases

### Session-based authentication

Bearer token auth without a database works purely (Example 2). Session-based auth — where a session token in a cookie is looked up in a sessions table — requires database access. A library cannot own that database.

**Pattern: function injection.** The library provides auth helper functions; the app passes its own lookup implementation:

```tesl
# What the library provides (helper, not a complete auth function)
fn validateSessionToken(
  lookupSession: String -> Maybe String,  # app provides this DB-backed function
  req:           HttpRequest
) -> Maybe (String ::: Authenticated userId) =
  case Dict.lookup "session" req.cookies of
    Nothing -> Nothing
    Something token ->
      case lookupSession token of
        Nothing -> Nothing
        Something userId -> Something (userId ::: Authenticated userId)
```

The app then writes its own `auth` function that calls this helper with its database lookup:

```tesl
# In the app
import myorg/tesl-auth-session/SessionAuth exposing [validateSessionToken]

fn lookupSession(token: String) -> Maybe String requires [dbRead] =
  case selectOne s from Session where s.token == token of
    Nothing -> Nothing
    Something s -> Something s.userId

auth myAuth(req: HttpRequest) -> userId: String ::: Authenticated userId
  requires [dbRead] =
  case validateSessionToken lookupSession req of
    Nothing -> fail 401 "invalid or expired session"
    Something userId -> ok userId ::: Authenticated userId
```

The library provides the extraction and structuring logic; the database stays in the app.

### CQRS (Command Query Responsibility Segregation)

CQRS is fundamentally a structural pattern — commands, queries, and events are types; handlers are pure functions that transform state. A `tesl-cqrs` library is almost entirely pure:

```tesl
# Pure CQRS machinery — no infrastructure needed
type CommandResult r
  = Accepted result: r
  | Rejected reason: String code: Int

fact CommandValidated (cmdId: String)

fn validateCommand(
  validators: List (a -> Maybe (Int, String)),
  cmd: a,
  cmdId: String
) -> CommandResult (a ::: CommandValidated cmdId) = ...

fn applyEvent(state: s, event: e, reducer: s -> e -> s) -> s = reducer state event
```

The application wires commands to queues and events to databases. The library provides only the type machinery and validation combinators. This is the clearest case: CQRS logic is pure, infrastructure is application-owned.

### Shared database schemas

A common question: can a library provide shared entity definitions that multiple applications use against the same database (e.g., a multi-tenant SaaS)?

**Answer: No, and this is intentional.** Each application owns its database schema. Libraries define record TYPES (interfaces), not database entities. If two applications need the same database schema, they should share a common record type from a library and each declare their own entity that matches that shape. This keeps deployment and migration under application control.

---

## Proof Predicate Namespacing

When the package manager is live, proof predicates get a fully-qualified identity based on their source package. The type system tracks this identity:

- `ValidEmail` from `myorg/tesl-validate/Email` is **different** from `ValidEmail` from `acme/email-utils/Validation`
- Two predicates with the same name but different packages cannot be confused
- The API diff engine uses the fully qualified name when detecting breaking changes

For human-readable error messages, the short name (`ValidEmail`) is shown; for identity purposes, the full qualified name (`myorg/tesl-validate/Email.ValidEmail`) is used.

This means: renaming a proof predicate across packages is always a MAJOR version bump (the proof identity changes, all consumers must update).

---

## Relationship to the Package Manager

The package manager (see [package_manager.md](package_manager.md)) depends on library support in these ways:

1. **API diffing** must understand the library boundary. Only library-allowed declarations (types, functions, proofs, capabilities) are included in the public API signature. Infrastructure declarations (`database`, `entity`, `queue`, etc.) are excluded from the diff even if they appear in a library module — treating their presence as a validation error would be surfaced by the package manager before publishing.

2. **Proof predicate ownership** is the canonical unit for semantic versioning. Renaming a predicate is MAJOR. Adding a new check function for an existing predicate is MINOR. Changing a check function's validation logic without changing its signature is PATCH.

3. **Capability requirements** appear in the public API signature. If a library function changes from `requires [dbRead]` to `requires [dbRead, dbWrite]`, that is a MAJOR breaking change — all callers must update their capability chains.

4. **Private channels** for the package manager work the same as for public packages from a library design perspective. The library boundary (no infrastructure ownership) applies equally to private and public packages.

---

## Open Questions

These require further design work before libraries can be fully specified:

1. **Re-export semantics**: Should libraries be allowed to re-export proof predicates from their dependencies with preserved identity? (See the re-export section above.) Recommendation: yes, with explicit declaration in the module header.

2. **Entity shape contracts**: How does a library express "I need an entity with at least these fields" without owning the entity declaration? Options range from informal documentation (current) to compiler-enforced record shape matching.

3. **Capability inheritance**: If a library function requires `queueWrite`, and an app's handler calls that function, must the handler explicitly declare `queueWrite` in its own capabilities? Currently yes. Should libraries be able to "seal" their capability requirements so callers see only a named capability (e.g., `auditWrite`) rather than the transitive implementation?

4. **Testing libraries**: Libraries need a way to run their test blocks without infrastructure. Currently, test blocks work only with `racket tests/all.rkt`. A library test harness (run by `tesl test src/Email.tesl`) that starts no database or queue is needed.

5. **Version resolution**: When app A depends on `tesl-validate@1.2.0` and `tesl-user@2.0.0` depends on `tesl-validate@1.1.0`, which version resolves? Elm requires a single version per package; the same constraint makes sense here given proof predicate identity.
