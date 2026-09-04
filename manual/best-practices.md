# Tesl Best Practices

This guide covers recommended patterns, conventions, and best practices for writing idiomatic and maintainable Tesl code.

Use `tesl help manual best-practices` to access this from the CLI.

---

## Table of Contents

1. [General Principles](#general-principles)
2. [Project Structure](#project-structure)
3. [Naming Conventions](#naming-conventions)
4. [Validation Patterns](#validation-patterns)
5. [Proof Management](#proof-management)
6. [Proof Cost Model](#proof-cost-model)
7. [Security](#security)
8. [Error Handling](#error-handling)
9. [API Design](#api-design)
10. [Database Access](#database-access)
11. [Money and Units](#money-and-units)
12. [Interop and Foreign Work](#interop-and-foreign-work)
13. [Testing](#testing)
14. [Performance](#performance)

---

## General Principles

### Validate Once at the Boundary

**✅ Do:**
```tesl
check isValidEmail(email: String) -> email: String ::: ValidEmail email =
  if String.contains email "@" then
    ok email ::: ValidEmail email
  else
    fail 400 "Invalid email format"
```

**❌ Don't:** Re-validate the same value multiple times in the call stack.

The compiler tracks the proof (`:::` annotation) and ensures the value remains validated throughout its lifetime.

### Make Auth Requirements Explicit

**✅ Do:**
```tesl
handler get getTodo(requestUser: User ::: Authenticated requestUser, todoId: String ::: ValidTodoId todoId)
  -> Todo ? FromDb (Id == todoId)
  requires [dbRead Todo] =
  # Auth is visible in the signature: requestUser carries the Authenticated proof
```

**❌ Don't:** Hide auth checks in middleware or handler bodies without type-level visibility.

### Keep Functions Small and Focused

Each function should:
- Have a single responsibility
- Validate its inputs (if at the boundary)
- Return clearly typed outputs with appropriate proofs

---

## Project Structure

### Recommended Directory Layout

```
my-api/
├── src/
│   ├── types.tesl          # Shared type definitions
│   ├── validation.tesl    # Validation functions (checks)
│   ├── auth.tesl          # Authentication predicates and handlers
│   ├── db.tesl            # Database schema and queries
│   ├── routes/
│   │   ├── todos.tesl     # Todo-related routes
│   │   ├── users.tesl     # User-related routes
│   │   └── ...
│   └── main.tesl          # Entry point with API declaration
├── tests/
│   ├── todos.test.tesl    # Tests for todo routes
│   └── users.test.tesl    # Tests for user routes
└── config/
    └── database.tesl      # Database configuration
```

### Module Organization

- **One module per file** with clear exports
- **Explicit imports** - always specify what you import
- **Layered architecture** - validation → types → business logic → routes

---

## Naming Conventions

### Types and Predicates

| Entity | Convention | Example |
|--------|------------|---------|
| Type names | PascalCase | `User`, `Todo`, `EmailAddress` |
| Predicate names | PascalCase, often prefixed with `Is`, `Has`, or `Valid` | `ValidEmail`, `UserExists`, `HasPermission` |
| Record fields | camelCase | `firstName`, `lastName`, `createdAt` |
| Variables | camelCase | `userId`, `todoList`, `email` |
| Functions | camelCase | `getUser`, `createTodo`, `validateEmail` |
| Proof names | Same as predicate | `ValidEmail`, `UserExists` |

### Route Naming

- **Plural nouns** for collections: `GET /todos`, `POST /todos`
- **Singular nouns** for single items: `GET /todos/:id`, `PUT /todos/:id`
- **Verbs** for actions: `POST /todos/:id/complete`, `POST /users/login`

### Check Function Naming

Prefix validation functions with verbs that indicate their purpose:
- `isValid...` - for simple boolean validation
- `check...` - for validation that returns proofs
- `parse...` - for parsing/transforming input

---

## Validation Patterns

### Composing Validations

**✅ Do:** Compose simple checks into complex ones:
```tesl
check validateUser(user: RawUser) -> validated: User ::: ValidUser validated =
  let email = check isValidEmail(user.email)
  let name = check isValidName(user.name)
  let age = check isValidAge(user.age)
  ok { email, name, age } ::: ValidUser { email, name, age }
```

### Using Codecs

**✅ Do:** Define codecs for request/response types:
```tesl
record NewTodo {
  title: String ::: ValidTitle title
  description: String ::: ValidDescription description
  dueDate: Date ::: ValidFutureDate dueDate
}

codec NewTodo {
  toJson_forbidden
  fromJson
}
```

**Don't hand-write a `toJson` for a plain response record.** A record used only as a
response auto-derives its JSON *encoder* from its shape — you do **not** need a `codec`
block at all:
```tesl
# This compiles and serializes as {"id":…, "name":…} with NO codec block:
record TodoView { id: Int, name: String }

handler get getTodo() -> TodoView =
  TodoView { id: 1, name: "buy milk" }
```
Write an explicit `codec` only when you need the *decode* side (`fromJson`, to validate
incoming request data and mint proofs `via` a check — as in `NewTodo` above), or to
override the default field-name/format mapping. Restating every field in a `toJson`
that just mirrors the record shape is redundant.

### Cross-Field Validation

**✅ Do:** Use `check` for cross-field validation:
```tesl
check validateRegistration(req: RegistrationRequest) -> valid: RegistrationRequest ::: ValidRegistration valid =
  let email = check isValidEmail(req.email)
  let password = check isValidPassword(req.password)
  let _ = check passwordsMatch(req.password, req.confirmPassword)
  ok req ::: ValidRegistration req

check passwordsMatch(password: String, confirm: String) -> unit ::: PasswordsMatch =
  if password == confirm then
    ok unit ::: PasswordsMatch
  else
    fail 400 "Passwords do not match"
```

---

## Proof Management

### The Trust Boundary

`check`, `auth`, and `establish` are the **trusted proof-minting kinds** — Tesl's
equivalent of a Ghosts-of-Departed-Proofs *smart constructor*. Everywhere else, the
compiler guarantees you **cannot skip a validator**: a value that reaches a
proof-carrying parameter without an unbroken chain back to one of these kinds (or a
framework provenance such as `FromDb`) is a compile error. That is the real, mechanical
guarantee, and it is strong.

What the compiler **does not** do is verify that a validator body is *correct*. Inside a
`check`/`auth`/`establish` body you are trusted:

```tesl
# The compiler ACCEPTS this — the body is trusted, and this body is WRONG.
check checkPositive(guard: Int, payload: Int) -> payload: Int ::: Positive payload =
  if guard > 0 then
    ok payload ::: Positive payload   # stamps `Positive payload` while testing `guard`
  else
    fail 400 "not positive"
```

Tesl adds *guardrails* on top of the trust (e.g. the `ok`-value must name the binding it
stamps; `establish` cannot invent a different subject) that catch the naive mistakes.
These are a safety net, **not** a proof of correctness — do not read a clean build as
"the validator is verified." Treat every `check`/`auth`/`establish` body the way you
would a `unsafePerformIO` or a hand-written smart constructor: keep them small, named,
localized, and **reviewed by a human**. The value Tesl delivers is that there are few of
them and the compiler forces all trust through them.

### Attaching Proofs

**✅ Do:** Attach proofs at the validation boundary:
```tesl
handler post createTodo(req: NewTodo ::: ValidNewTodo) -> Todo ? FromDb (Id == todo.id)
  requires [dbWrite Todo] =
  # req carries the ValidNewTodo proof automatically
  insert Todo req
```

### Detaching and Reattaching Proofs

When you need to pass proofs explicitly:
```tesl
fn processTodo(todo: Todo ::: TodoExists todo.id) -> Result =
  let proof = detachFact todo
  # proof is now a separate fact value
  # todo is the raw value without the proof
  ...
```

### Forall Proofs

**✅ Do:** Use forall proofs for collections:
```tesl
handler get getAllTodos() -> List Todo ? ForAll (FromDb (Id == todo.id))
  requires [dbRead Todo] =
  select todo from Todo
```

---

## Proof Cost Model

**Proof *tracking* is erased on the standard path.** For standard `check`/`fn`/`handler` paths
the compiler drops the proof-tracking machinery (struct wrapping, runtime argument validation, the
proof-environment scope) during macro expansion, so a build allocates **nothing for proof tracking**
in release and `--debug` alike (LANGUAGE-SPEC.md §4.3). Proof verification is a purely compile-time
guarantee.

This means you should reach for proofs **freely**. Adding a `:::` annotation, composing predicates
with `&&`, or constraining a list with `ForAll` costs essentially nothing at runtime. Design your
types around the guarantees you want, not around an imagined allocation budget.

The one caveat: erasure applies to *tracking*, not to every carrier. A **proof-annotated parameter
keeps ≤1 `named-value` allocation** at runtime so proof decomposition (`let (bare ::: p) = x`) still
works — this is not a bare "zero." Free-floating proofs (`detachFact` / `attachFact`), existential
packages, newtype nominal wrappers, and `FromDb` proofs likewise retain their representation (§4.3).
So: proof tracking is erased on the standard path, but a proof-annotated parameter keeps at most one
allocation — don't claim proofs are unconditionally zero-allocation.

Separately, "erased tracking" does *not* mean a call has zero runtime overhead: each `fn`/`handler`
call still pays a small always-on capability-grant + return-shape-validation cost (see the
per-feature table below); those checks guard runtime-only facts and are never erased.

### Debugging proofs

Proofs are erased even under `--debug`. A binding's proof is *compile-time* information (the static
checker already knows `port : Int ::: ValidPort`), so the step debugger shows the raw runtime value
and overlays the proof/type from compile-time type info — it needs no runtime struct. Breakpoints
and stepping work normally. The compiler is the sole proof contract: if a program that should be
rejected slips through, that is a compiler bug to report — there is no runtime toggle to fall back on.

```bash
tesl run my-api.tesl                            # proofs erased, zero overhead
tesl run --debug my-api.tesl                    # breakpoints + raw-value inspection; proofs still erased
```

### Per-feature runtime cost

| Feature | Runtime cost |
|---|---|
| Proof annotations (`:::`) | **Tracking erased** on the standard path (no proof structs), in release and `--debug` alike — checked once at the boundary. A *proof-annotated parameter* keeps **≤1 `named-value` allocation** so decomposition works; it is not unconditionally zero-allocation (§4.3). The debugger reads proof/type from compile-time info. |
| `check` functions | The check body runs **once**, at the validation boundary. It never re-runs downstream. |
| Capabilities (`requires [...]`) | **Near-zero.** The lattice is verified at compile time; at run time each call runs inside an ambient capability-grant scope with a small membership check against the granted set (not fully erased like proofs). |
| `ForAll` on lists | **Zero.** The list is a plain list at runtime; the annotation is erased — no per-element boxing. |
| Free-floating proofs (`detachFact` / `attachFact`) | **Minimal token, always.** These are explicit first-class values passed around at runtime, so they keep a small representation even in release builds. |
| ADTs / sum types | A normal tagged-union struct, like a discriminated union in any other language. |
| Newtypes (`type UserId = String`) | A thin wrapper struct for nominal distinctness; unwrapped automatically on DB and JSON boundaries. |

> This table is the **canonical** proof-cost model for the docs — the overview, getting-started, FAQ,
> tour, and the `README` all link here rather than restate it. The underlying proof-erasure rules are
> specified in [`LANGUAGE-SPEC.md`](../LANGUAGE-SPEC.md); if this table and the spec ever diverge, the
> language spec is authoritative.

---

## Security

The compiler carries a dedicated **`Security`** diagnostic category (`SEC0xx`) — run
`tesl help codes` to list it, and `tesl help SEC001` for any single code. Everything in this
section is either enforced by one of those codes or is a rule Tesl cannot check for you.

### A cookie check is not authentication

**❌ Don't:** decide who the caller is by comparing request data against a string:

```tesl
auth cookieAuth(request: HttpRequest) -> user: String ::: Authenticated user =
  case Dict.lookup "user" request.cookies of
    Nothing -> fail 401 "no user cookie"
    Something userId ->
      -- SEC001 fires on the comparison below
      if userId == "admin" then
        ok userId ::: Authenticated userId
      else
        fail 401 "admin only"
```

The client picks the value of `user`, so `Cookie: user=admin` walks straight in. Nothing about
this is authentication: it is a client-supplied claim being read back as if it were a fact. The
same applies to a `role` cookie, an `X-User-Id` header, or a `?user=` query parameter — **any
value the client sends is a request, never a credential.** The compiler reports this shape as
`SEC001`.

**✅ Do:** authenticate against something the client cannot forge, and let the verification mint
the fact:

```tesl
auth sessionOwner(request: HttpRequest) -> user: String ::: Authenticated user
  requires [sessions] =
  case Http.sessionToken request of
    Nothing -> fail 401 "Not signed in"
    Something token ->
      -- Checks the HMAC and the `exp` claim in constant time, auto-401s, and
      -- mints `Authentic` on the claims. `Authenticated` is reachable only on
      -- the far side of that check.
      let claims = check JWT.verify token (requireSecret "SESSION_KEY")
      ok (subjectOf claims) ::: Authenticated user
```

**This is the blessed session pattern, and it is the only one you should be assembling by
hand.** `Http.sessionToken` / `Http.setSessionCookie` / `Http.clearSessionCookie` (from
`Tesl.Http`, gated by `cookieCap`) are the whole transport: one fixed cookie name, every attribute
fixed, and a writer that demands a `JwtToken` so an unsigned session cookie cannot be expressed.
`requireSecret` puts the key in a `Secret` without a `String` ever holding key material. See
`example/learn/lesson76-sessions.tesl` for the full login → protected endpoint → logout program,
including the CSRF story and the honest limitation (logout drops the browser's cookie; it does not
revoke the token, which stays valid until `exp` — bounded at one hour).

For a session that does not log out a user who is still working, add `JWT.renew` to the `auth`
block and set the result — an `auth` block may write the cookie. Renewal carries every claim
across (rebuilding the claims dict by hand is how a `role` gets silently dropped on every
renewal), preserves the original `iat`, and refuses past a fixed 12-hour absolute maximum. That
cap is the security core, not a preference: renewal is presented *with* the token, so without it a
captured token would be renewable forever and nothing revokes it.

Three shapes are honest, in rough order of how much machinery they need:

| Shape | Verify with | Notes |
|---|---|---|
| **Session cookie (the default)** | `check JWT.verify token secret`, with `Http.sessionToken` reading it | The blessed pattern. Stateless, so it scales horizontally with no session store; claims travel inside the signature. `JWT.sign` stamps a fixed one-hour `exp` (epoch seconds, RFC 7519) — the expiry is not a parameter, so signing also needs `time`. See LANGUAGE-SPEC.md §21.2 |
| Signed value, MAC by hand | `check Crypto.checkSignature key sig payload` → `Authentic payload` | The primitive underneath. Reach for it for signed non-credential payloads (a webhook body, a one-time link); do not hand-roll a session out of it |
| Opaque session id | your own session table lookup | `Crypto.randomToken` to mint, storing only its `Crypto.fingerprint`; revocable, but needs storage. The right answer for long-lived credentials (API keys, machine tokens), not for browser sessions |

Comparing an **already-verified** value against a literal is correct and does not fire — the
verified subject is yours, not the client's. `SEC001` stops tracking a value the moment it passes
through `Crypto.checkSignature`, `Crypto.checkPassword`, `JWT.verify`, or a `check`/`auth` call.

### Never let the client declare its own privileges

A `role` that arrives in a cookie, header or query parameter is a request to be an administrator,
not evidence of being one. Put the role **inside the signed payload** (a JWT claim, or a MAC that
covers the role as well as the user id) or look it up server-side from the authenticated user id.

```tesl
-- ❌ privilege escalation: the client sends `role=admin` and the handler believes it
case Dict.lookup "role" request.cookies of
  Something role -> ok AdminUser { id: userId, role: role } ::: Authenticated requestUser

-- ✅ the role is a claim inside the signed token, so editing the cookie invalidates it
--    `check` is required: JWT.verify is check-shaped, and binding it is what makes
--    the 401 propagate instead of handing the failure value on as if it were a Dict.
let claims = check JWT.verify (JwtToken raw) (requireSecret "SESSION_JWT_SECRET")
case Dict.lookup "role" claims of
  Something role -> ok AdminUser { id: userId, role: role } ::: Authenticated requestUser
```

Tesl cannot detect this one for you: whether a record field originated with the client is a
cross-function dataflow question about values the linter has no types for. It is on you, and it is
the single most common real-world web authorization bug.

### Keys come from the environment, never from the source

```tesl
-- ❌ SEC003 — committed to the repository, identical in every deployment,
--    and still in git history after you change it
let key = Secret "s3cr3t-signing-key"

-- ✅ read it at startup; rotate it where it lives
let key = Secret (requireEnv "SESSION_SIGNING_KEY")
```

`Secret` has a constructor precisely so a config read can produce one — `SEC003` is what keeps
that constructor from becoming a place to type a key.

### Verify tags, do not compare them

```tesl
-- ❌ SEC004 — `==` on String short-circuits, so the comparison time leaks how
--    many leading bytes of the correct tag were guessed
let matches = Crypto.signatureHex (Crypto.signWith key payload) == provided

-- ✅ constant-time, and it yields a fact instead of a Bool
let verified = check Crypto.checkSignature key (Crypto.signatureFromHex provided) payload
```

This is why `Signature` has no `==` at all: the only legitimate comparison of two tags **is** a
verification. `Crypto.signatureHex` exists to put a tag in a header and `Crypto.signatureFromHex`
to read one back out — neither is a way to check one.

### Passwords

Store `Crypto.hashPassword`, never the plaintext and never a fast digest of it
(`Crypto.fingerprint` is for ETags and cache keys, not passwords). Verify with
`Crypto.checkPassword`, which is timing-equalized against user enumeration and yields a
`PasswordVerified` fact rather than a `Bool`.

Where two same-typed plaintexts are in scope at once — change-password (`oldPassword`,
`newPassword`) and password-reset (`resetToken`, `newPassword`, `confirmPassword`) — demand
`HashFor` one layer up, and hashing the wrong one stops compiling:

```tesl
fn storeNewPassword(user: User, newPassword: String,
                    hash: PasswordHash ::: HashFor newPassword) -> Unit = ...

storeNewPassword user np (Crypto.hashPassword np)                 -- compiles
storeNewPassword user np (Crypto.hashPassword body.oldPassword)   -- rejected
```

### Scope capabilities to resources

Database capabilities must name the entity they cover:

```tesl
fn listOrders(userId: String) -> List Order requires [dbRead Order] =
  select order from Order where order.userId == userId

capability orderService implies dbRead Order, dbWrite Order
```

`dbRead Customer` does not satisfy `dbRead Order`. `dbWrite Order` covers both reads and writes of
`Order`, but no access to `Customer`. Bare `dbRead` and `dbWrite` grants are compile errors; only
their imports stay bare. The compiler derives requirements from each query, including every entity
touched by a join, and checks them through capability implications. Every DB entity granted by
`main` must also belong to the database selected by `App.database`.

Queue and pub/sub resource scopes are also implemented: `queueRead QueueName`,
`queueWrite QueueName`, and `pubsub ChannelName`. `queueWrite QueueName` covers reads from that same
queue, never another queue. Bare queue/pubsub grants currently remain migration wildcards.

### A GET may not change state

**❌ Don't:** put a write behind a `get` route.

```tesl
handler get recordView(id: String) -> String requires [dbWrite View] =
  let _ = insert View { docId: id }
  "ok"

api DocApi {
  get "/doc/:id/view" -> String     -- ❌ SEC005 — a write reachable through a GET
}
```

**✅ Do:** use a method that is allowed to change things, and keep the GET read-only.

```tesl
api DocApi {
  post "/doc/:id/view" -> String    -- ✅ the mutation moved to POST
  get  "/doc/:id"      -> Doc       -- ✅ the GET only reads
}
```

`SEC005` is a hard **error**, not a warning: a `get` route whose handler's capability closure
reaches `dbWrite`, `queueWrite`, `pubsub` or `emailCap` does not compile. Three reasons it is worth
a build failure:

- **HTTP says so.** GET is *safe* per RFC 9110 §9.2.1. Caches, prefetchers, link crawlers and
  `<img>`/`<link>` tags all issue GETs with no user intent behind them.
- **It is the last CSRF gap.** The session cookie is `SameSite=Lax`, and a browser **does** attach a
  Lax cookie to a cross-site *top-level* GET navigation. So a mutating GET is triggerable by an
  attacker's page navigating your user's browser to the URL. Every other CSRF vector is already
  closed by construction — the 415 on non-`application/json` request bodies, no CORS headers on JSON
  routes, parameterised SQL — which is what makes this one worth enforcing rather than documenting.
- **`emailCap` counts.** A GET that sends mail is a cross-site spam vector reached exactly the same
  way.

The rule keys on what the handler's body *actually does* (transitively, through the calls it makes),
not on what it declares — so a handler holding a capability that `implies dbWrite View` while only
selecting rows stays clean. Reads are fine: `dbRead Entity` and `queueRead Queue` in a GET are the common case.
Telemetry is ambient and out of scope, and so is `cacheCap` — it has no read/write split, and
filling a cache during a GET is response caching, the benign case.

If you need a read-audit trail (who viewed what), record it through telemetry, or accept the write
on a POST.

### What Tesl deliberately does not check

- **Entropy of string literals.** A lint that guesses whether `"abc123"` is a key fires on test
  vectors and fixtures forever. `SEC003` is structural instead: a literal in a *key position*.
- **Field names.** Whether `password: String` should have been a `secret` type is a naming
  judgement; it is planned behind a suppression mechanism rather than shipped as an unsilenceable
  warning.
- **Whether an `auth` body verified anything at all.** Every honest `auth` reads request data, so
  the shape is not a signal on its own — which is exactly why `SEC001` keys on the *literal
  comparison* rather than on the read.

---

## Error Handling

### Use Appropriate HTTP Status Codes

| Error Type | Status Code | Message |
|------------|-------------|---------|
| Validation error | 400 | "Invalid input: <field> <reason>" |
| Authentication required | 401 | "Authentication required" |
| Permission denied | 403 | "Permission denied" |
| Not found | 404 | "Resource not found" |
| Conflict | 409 | "Resource already exists" |
| Server error | 500 | "Internal server error" |

### Structured Error Messages

**✅ Do:** Provide clear, actionable error messages:
```tesl
check isValidEmail(email: String) -> email: String ::: ValidEmail email =
  if not (String.contains email "@") then
    fail 400 "Invalid email: must contain @ symbol"
  else if not (String.contains email ".") then
    fail 400 "Invalid email: must contain a domain"
  else
    ok email ::: ValidEmail email
```

**❌ Don't:**
```tesl
fail 400 "Bad request"  -- Too vague
```

---

## API Design

### Route Design

**✅ Do:**
```tesl
api TodoApi {
  get "/todos/:id"
    capture id: String ::: ValidTodoId id via todoIdCapture
    auth user: User ::: Authenticated user via cookieAuth
    -> Todo ? FromDb (Id == id)

  post "/todos"
    auth user: User ::: Authenticated user via cookieAuth
    body req: NewTodo ::: ValidNewTodo
    -> Todo ? FromDb (Id == todo.id)

  put "/todos/:id"
    capture id: String ::: ValidTodoId id via todoIdCapture
    auth user: User ::: Authenticated user via cookieAuth
    body req: UpdateTodo
    -> Todo ? FromDb (Id == id)
}
```

### Versioning

Include API version in endpoints:
```tesl
api TodoApi_v1 {
  get "/todos/:id"
    capture id: String ::: ValidTodoId id via todoIdCapture
    -> Todo ? FromDb (Id == id)
}

api TodoApi_v2 {
  get "/todos/:id"
    capture id: String ::: ValidTodoId id via todoIdCapture
    -> TodoV2 ? FromDb (Id == id)
}
```

### Pagination

**✅ Do:**
```tesl
api TodoApi {
  get "/todos"
    query page: Int ::: Positive page
    query limit: Int ::: Positive limit
    -> Paginated(Todo)
}
```

---

## Database Access

### Typed Queries

**✅ Do:** Use typed SQL queries with entities:
```tesl
let todos = select todo from Todo where todo.userId == userId
```

The compiler infers the return type from the entity definition and query.

### Parameterized Queries

Always use parameterized queries to prevent SQL injection:
```tesl
-- ✅ Safe - parameterized query
let user = selectOne user from User where user.email == email

-- ❌ Unsafe (SQL injection risk) - don't use string concatenation
-- let user = db.query ("SELECT * FROM users WHERE email = '" ++ email ++ "'")
```

### Transactions

**✅ Do:** Use `transaction` for multi-operation consistency:
```tesl
handler post transferAmount(fromId: String, toId: String, amount: Int ::: Positive amount)
  -> TransferResult
  requires [dbWrite Account] =
  transaction {
    let fromBalance = selectOne account from Account where account.id == fromId
    let toBalance = selectOne account from Account where account.id == toId

    if fromBalance == Nothing || toBalance == Nothing then
      fail 404 "Account not found"
    else if fromBalance.value.balance < amount then
      fail 400 "Insufficient funds"
    else
      update account in Account
        where account.id == fromId
        set account.balance = account.balance - amount
      update account in Account
        where account.id == toId
        set account.balance = account.balance + amount
      ok { success: true }
  }
```

---

## Money and Units

### Money

**✅ Do:** Represent money as `Money` (Tesl.Money) — exact integer MINOR units with an intrinsic currency. **❌ Don't** model money as `Float` (binary floats cannot represent 0.10) or as a bare `Int` that forgets its currency.

```tesl
let price = Money.usd 1050          # $10.50, minor units (cents)
let total = Money.scale price 3     # exact integer scaling
```

- **Use the per-currency constructors** (`Money.usd`, `Money.sek`, …) with minor units; use `Money.fromMinorUnits` when the currency is picked at runtime. A typo'd `Currency` constructor is a compile error.
- **Mint `SameCurrency` before arithmetic:** `Money.add`/`Money.subtract`/`Money.compare` require it — `let proven = check Money.requireSameCurrency a b` then `Money.add a proven`. Raw `+`/`-`/`<` on money never compiles.
- **Exchange rates are runtime data**, never constants in source: build them with `ExchangeRate.make from to rate asOf` from a rate service or fixture, and convert with `Money.convert` (Result) or `Money.requireRateFor` + `Money.convertChecked` (proof path).
- **Display at boundaries** with `Money.display`; store `Money` entity fields directly (two columns, `_minor` + `_currency`) and remember `selectSum` over money sums a single currency only.

### Units

**✅ Do:** Give physical quantities their dimension (Tesl.Units) instead of passing bare `Float`s whose unit lives in a comment or parameter name.

```tesl
fn brakingDistance(v: Speed, a: Acceleration) -> Length =
  let vSquared = Units.square v
  let twoA = 2.0 * a
  let nonZero = check Units.requireNonZero twoA
  vSquared / nonZero
```

- **SI canonical inside:** constructors convert in (`Length.miles 3.0` is meters internally), accessors convert out (`Speed.inKilometersPerHour v`). Convert at the boundaries; never carry a "which unit is this?" Float through the core.
- **Dimensions are checked at compile time** and erased at runtime — the operators do the algebra (`Length / Duration : Speed`), cross-dimension `+` does not compile, and a quantity costs exactly a `Float`.
- **Scalars are Float literals** (`2.0 * len`, not `2 * len`), and a variable divisor needs `check Units.requireNonZero` first, like every Tesl division (the `check` is what propagates the zero-divisor rejection; it keeps the dimension).

---

## Interop and Foreign Work

Tesl has **no FFI**: no `foreign fn`, no `eval`, no subprocesses, no filesystem. It still talks to non-Tesl code every day — through the primitives you already have. A handler `enqueue`s a job, a `worker` calls the foreign service over `HttpClient`, and the result is `insert`ed and/or `publish`ed to the caller's SSE channel. Nothing new is required, and the proof system survives the boundary intact.

The worked example is [`example/learn/lesson74-interop-patterns.tesl`](../example/learn/lesson74-interop-patterns.tesl) — file access, background workloads, and a foreign service called from a worker, all compiled and tested. This section is the policy behind it; read the lesson for the code.

### Triage: "Tesl can't do X, give me an escape hatch"

Three requests hide behind that sentence, and they have three different answers.

| The request really is | Answer | Why |
|---|---|---|
| A **bounded primitive gap** — hashing, regex, a date format | A **primitive in the trusted core**, behind its own capability | Small, auditable, maintained by us; the value it returns is constructed by trusted code, not decoded from a stranger |
| A **large third-party ecosystem** — image processing, ML, PDF, a vendor SDK | A **separate service** the app calls over HTTP, per the initiator rule below | We are never going to re-implement it, and it does not have to live in our process to be usable |
| **Arbitrary host access from app code** — a general `foreign fn` | **Never** | The return value would enter typed Tesl with no validating boundary, so it could forge any proof-annotated field, newtype, or ADT tag — a hole in the proof kernel, not a feature |

The precedent for the first row is `Tesl.JWT`: the Go runtime binds the standard cryptographic primitives and exposes exactly `JWT.sign` / `JWT.verify` / `JWT.decode` under the `jwt` capability. Host integration is allowed **maintainer-side**, inside the trusted core, with a narrow typed surface. It is never user-facing.

The load-bearing distinction across the whole table is **data boundary vs. host-value boundary**. A result that arrives as JSON crosses the validating decoder and cannot forge a proof — a `:::`-annotated record field will not even decode without a registered check ([`LANGUAGE-SPEC.md`](../LANGUAGE-SPEC.md) §11.17). A result that arrives as a host value bypasses every check Tesl makes.

### Tesl always initiates

**✅ Do:** make the outbound call from a `worker` and treat the reply *as* the HTTP response. The foreign side learns no Tesl URL, holds no credential, and Tesl exposes no inbound surface. Durability and retry come from the queue, so a dropped connection is just a retried job.

| | Reply path | Tesl exposes inbound? | Extra machinery |
|---|---|---|---|
| **Tesl initiates** (default) | response to our own outbound call | no | outbound timeout |
| **Inbound webhook** (fallback) | foreign side calls the Tesl API | **yes** | endpoint + auth + replay defence + correlation storage |

Reach for the webhook only when the work runs long enough (minutes and up) that holding an outbound connection is untenable. Note what happens when you do: it stops being interop machinery and becomes an ordinary integration — an authenticated Tesl endpoint, with the existing `auth` machinery applying unchanged and nothing interop-specific about it.

**❌ Don't** ignore what the default costs. A blocked outbound call pins one of the queue's `numberOfWorkers` threads for its whole duration, so a slow upstream still occupies a worker for the duration of the call: with `numberOfWorkers: 4`, four simultaneously-slow calls stall *all* background work, including job types that have nothing to do with the foreign service. Outbound calls now carry connect, read and SSE-idle deadlines with conservative defaults (`TESL_HTTP_CONNECT_TIMEOUT_MS`, `TESL_HTTP_TIMEOUT_MS`, `TESL_HTTP_STREAM_IDLE_TIMEOUT_MS`), so a *hung* upstream fails the job instead of wedging the thread forever — and a failed job goes through retry, backoff and dead-lettering as normal. That bounds the damage; it does not remove it. Give a flaky upstream headroom anyway — a larger `numberOfWorkers`, or its own queue so it cannot starve unrelated jobs.

### The foreign-work recipe

Same shape as the agent resume-after pattern (`LANGUAGE-SPEC.md` §11.18, [`lesson70-agent-async-work.tesl`](../example/learn/lesson70-agent-async-work.tesl)) with "an LLM" swapped for "a Rust service" — read that first if you have not; the rest of this is what changes.

**There is no blocking wait.** Say this to yourself before designing anything: Tesl has no `sleep` and no `await`, so a handler **cannot** enqueue work and then wait for the answer. This is the thing people trip over. Interop is a *workflow*, not a function call: the handler returns immediately ("queued", plus a correlation id), and the answer arrives later through a different channel. If your design has a step that reads "and then we wait for the result", it will not compile, and the fix is to redraw the flow, not to look for the await.

**Correlate explicitly.** `tesl_jobs` has no `result` column, so nothing carries an answer back for you. A reply is a *second* thing: another job type, a database row, or an SSE event — carrying a correlation id that is present in both payloads. Generate it in the handler (`generatePrefixedId`), return it to the caller, and put it on the outbound request so the foreign side echoes it back.

**Assume duplicates.** Queue delivery is **at-least-once** with retry and backoff: a worker that crashes after calling the foreign service but before completing will call it again. The foreign side must therefore be idempotent — key its work on the correlation id and return the previous result for a repeat. On the Tesl side, prefer writes that are safe to repeat (upsert or check-then-insert on the correlation id) over blind `insert`.

**Name the capability after the effect, not the transport.** Declare one capability per foreign effect, on both sides of the queue:

```tesl
capability thumbnailRequest implies queueWrite  # what a handler needs to request a thumbnail
capability thumbnailer      implies httpClient  # what the worker needs to produce one
```

so signatures read `requires [thumbnailRequest]` and `requires [thumbnailer]`, exactly the way `capability emailWrite implies queueWrite` (`LANGUAGE-SPEC.md` §11.15) makes "send an email" a capability rather than "write to a queue". A bare `requires [queueWrite]` or `requires [httpClient]` on business logic tells a reader nothing — it says "this can enqueue something" or "this can reach the network", when what they need to know is "this can reach the thumbnailer, and nothing else". The capability list is documentation the compiler checks; spend it on the effect.

**The foreign side never gets app database credentials.** It receives a JSON payload and returns a JSON result. Not a connection string, not a read-only replica, not "just for reporting". The reason is in the next subsection, and it is a soundness reason, not a hygiene one.

### Never point an external worker at `tesl_jobs`

This is the first idea everyone has — "the jobs are already in Postgres, just let my Python worker poll the table" — and it is the one variant that breaks the proof system.

`tesl_jobs` lives in the app's own database, so consuming it from a non-Tesl process means handing that process the app's PostgreSQL credentials. **The database read path does not re-validate record invariants**: the checker enforces them at the *write* site, which is sound precisely because every write goes through the checker. A process with database write access sits outside that guarantee. It can plant rows that violate declared invariants, and Tesl will read them back and treat those facts as established — including facts a `check` function would have rejected. Of everything you could grant a foreign process, database write access is the single grant that defeats the proof system.

The practical blockers point the same way: `tesl_jobs` is internal and unversioned (its shape changes without notice), it has no `result` column to write an answer into, and with no PostgreSQL runtime configured the queue is in-memory — so an external consumer cannot attach in dev or in tests, where you would want to prove the integration works.

Supporting an external consumer properly would mean a versioned view over `tesl_jobs`, a locked-down PostgreSQL role, and a published payload contract. That is a project, not a shortcut. Until it exists, the supported shape is the one above: Tesl initiates, JSON in, JSON out, credentials stay home.

---

## Testing

Tesl provides a comprehensive testing framework with multiple testing approaches. Understanding each type helps you write robust, maintainable tests for different aspects of your application.

### Test Organization

- **One test file per module** with `.test.tesl` suffix
- **Test both success and failure cases** - don't just test the happy path
- **Use mutation testing** for critical validation functions
- **Keep tests focused** - one assertion or related set of assertions per test
- **Name tests descriptively** - the test name should describe what it verifies

### Test Types Overview

Tesl supports several types of tests, each serving a different purpose:

| Test Type | Command | Purpose | When to Use |
|-----------|---------|---------|-------------|
| **Unit Tests** | `test` / `expect` | Test individual functions in isolation | Pure functions, validation logic |
| **Property Tests** | `test … with N runs` + `property` | Verify properties hold across many inputs | Validation invariants, business rules |
| **API Tests** | `api-test` | Test HTTP endpoints | Integration, endpoint behavior |
| **Queue Tests** | `api-test` + queue helpers | Test background job processing | Queue message handling |
| **SSE/PubSub Tests** | `api-test` + `subscribe`/`collect` | Test real-time event streams | Server-Sent Events, pub/sub |
| **Load Tests** | `load-test` | Test performance under load | Performance-critical endpoints |
| **Mutation Tests** | `tesl mutate` | Verify validation functions | Critical check/establish/auth functions |

### 1. Unit Tests

Test individual functions in isolation. Use for pure functions and business logic.

**✅ Do:**
```tesl
# Test a pure function
test "isValidEmail rejects empty strings" {
  let result = isValidEmail("")
  expect result.isError == true
}

test "isValidEmail accepts valid emails" {
  let result = isValidEmail("test@example.com")
  expect result.isOk == true
  case result of
    Ok email -> expect email == "test@example.com"
    Err _ -> fail "Expected Ok"
}

# Test with specific values
test "addPositive adds correctly" {
  let result = addPositive(5, 3)
  case result of
    Ok sum -> expect sum == 8
    Err _ -> fail "Expected Ok"
}

test "addPositive rejects negative numbers" {
  let result = addPositive(-1, 5)
  expect result.isError == true
}
```

**Key patterns:**
- Use `test` for synchronous pure function tests
- Use `expect` to assert conditions
- Test both happy paths and error cases
- Return `unit` from test blocks

### 2. Property-Based Tests

Verify that properties hold across many randomly generated inputs. Ideal for validation functions.

**✅ Do:**
```tesl
test "email length" with 100 runs {
  property "valid emails are never empty" (email: String) { String.length email >= 0 }
}

test "addPositive is commutative" with 50 runs {
  property "commutative" (a: Int, b: Int) { addPositive a b == addPositive b a }
}

test "clamp stays in range" with 100 runs {
  property "result is in range" (lo: Int, hi: Int where lo <= hi, n: Int) {
    clamp lo hi n >= lo && clamp lo hi n <= hi
  }
}
```

**Key patterns:**
- Property tests live inside a `test "..." with N runs { ... }` block, one or more
  `property "name" (params) { expr }` clauses per block
- Declare the random inputs as the property's parameters (`(x: Int, y: Int)`); add a
  `where` clause to filter (`(n: Int where n > 0)`) or `via genFn` for a custom generator
- Test invariants and properties, not specific values

### 3. API Tests

Test HTTP endpoints and API behavior. These are integration tests that verify your API works as expected.

**✅ Do:**
```tesl
api-test "GET /todos returns empty list when no todos exist" for TodoServer {
  let result = get "/todos"
  expect statusOk result.status
  expect result.body == []
}

api-test "POST /todos creates a new todo" for TodoServer {
  let newTodo = { title: "Buy groceries", description: "Milk, eggs, bread" }
  let result = post "/todos" body newTodo
  expect statusCreated result.status
  expect String.length result.body.id > 0
  expect result.body.title == "Buy groceries"
}

api-test "POST /todos fails with invalid title" for TodoServer {
  let result = post "/todos" body { title: "" }
  expect result.status == 400
  expect String.contains result.body "Title must be between 3 and 120 characters"
}

api-test "GET /todos/:id returns specific todo" for TodoServer {
  -- First create a todo
  let createResult = post "/todos" body { title: "Test todo", description: "Test" }
  expect statusCreated createResult.status
  
  -- Then get it by ID
  let id = createResult.body.id
  let getResult = get ("/todos/" ++ id)
  expect statusOk getResult.status
  expect getResult.body.id == id
}
```

**Key patterns:**
- The request path is any `String` expression — a literal, an interpolation (`get "/todos/{id}"`), a `let`-bound string, or a concatenation (`get ("/todos/" ++ id)`). That is what makes a create-then-read flow testable when the id is server-generated: read it off the create response and splice it into the follow-up path. A `?query=…` in a computed path is parsed exactly as in a literal one.
- Inside an `api-test`, bare `{…}` is an interpolation slot **only when the whole brace content is a single expression** (`{id}`, `{created.body.id}`). Anything else — `"{}"`, `"{\"id\": 1}"`, an unbalanced quote — is ordinary text, so a JSON literal in a path, a stub body, or an `expect` needs no escaping. Tesl's own `${…}` string interpolation works in an api-test too and is unaffected by this rule.
- Use `api-test` with a server name (e.g., `for TodoServer`)
- The server must be defined in your code with `server TodoServer for TodoApi` (the port is set on the `App` record, not on the `server`)
- Test the full HTTP cycle: request → handler → response
- Test both success and error responses
- Verify status codes, response bodies, and headers

### 4. Queue Tests

Background job processing is tested from inside an `api-test` — there is no separate
`queue-test` kind. Inside an `api-test` the queue workers run **synchronously**, so
HTTP → queue flows stay deterministic. Drive the queue with the `Tesl.ApiTest` helpers
`processNextJob`, `processNextDeadJob`, `drainQueue`, and `pendingJobCount`.

**✅ Do:**
```tesl
api-test "posting a registration enqueues and processes a job" for RegistrationServer {
  # The endpoint enqueues a job as a side effect of handling the request.
  let posted = post "/registrations" body { userId: "user-123", email: "test@example.com" }
  expect statusOk posted.status
  expect pendingJobCount RegistrationQueue == 1

  # Run the next worker synchronously, then assert on the job and DB state.
  let done = processNextJob RegistrationQueue
  let job = expectJobOk done
  expect job.userId == "user-123"
  expect pendingJobCount RegistrationQueue == 0
}
```

**Key patterns:**
- Test queues inside `api-test` (there is no `queue-test` kind)
- Trigger enqueues through the endpoint under test (or an `enqueue` statement in a handler)
- Run workers with `processNextJob <Queue>` or `drainQueue <Queue>`; assert queue depth with `pendingJobCount <Queue>`
- Drain the dead-letter queue with `processNextDeadJob <Queue>`
- Check database state after processing

### 4b. Outbound HTTP (stubbing what your code calls)

A handler or worker that calls an external service used to have an untestable
branch. Declare the answer in the test instead — `stubHttp` / `stubHttpFailure` /
`stubHttpTimeout` from `Tesl.ApiTest` intercept `Tesl.HttpClient` calls, and
`httpCalled` / `httpCallCount` / `httpLastBody` assert what your code actually
sent. `"*"` matches any method or URL; a trailing `*` matches a URL prefix.

**✅ Do:**
```tesl
test "a hung upstream fails the job rather than the worker" requires [webClient] {
  stubHttpTimeout "GET" "https://upstream.example.com/sync"
  expectFail syncNow "https://upstream.example.com/sync"
  expect httpCallCount "GET" "https://upstream.example.com/sync" == 1
}
```

**Key patterns:**
- Cover the branches a live upstream will not perform on request: an upstream
  500, a malformed body, a refused connection, a timeout
- The stub table is per test block, so nothing leaks between tests
- Once a block declares its first stub, an unmatched outbound call fails loudly
  instead of quietly hitting the real service
- Outbound calls also have deployment-tunable deadlines
  (`TESL_HTTP_CONNECT_TIMEOUT_MS`, `TESL_HTTP_TIMEOUT_MS`), so a hung upstream fails the *job* and
  the normal retry / dead-letter machinery runs

### 5. SSE/PubSub Tests

Real-time event streams are also tested inside an `api-test` — there is no separate
`sse-test` kind. Open a stream with `subscribe`, trigger a publish (typically through an
endpoint), then read the delivered events with `collect`. A bounded `collect` requires a
`count` and a `timeout`.

**✅ Do:**
```tesl
api-test "subscribers receive published room events" for ChatServer {
  let stream = subscribe "/events/rooms/room-1"

  # Publishing happens as a side effect of handling the request.
  let posted = post "/rooms/room-1/messages" body { text: "Hello world" }
  expect statusOk posted.status

  # Read the delivered events; count + timeout bound the collect.
  let events = collect stream count 1 timeout 2000ms
  expect hasLength 1 events
  let first = arrayAt 0 events
  expect first.fields.text == "Hello world"
}
```

**Key patterns:**
- Test SSE inside `api-test` (there is no `sse-test` kind)
- Open a subscription with `subscribe "<route>"`
- Read events with `collect <stream> count <n> timeout <ms>` (both clauses required)
- Trigger publishes through the endpoint under test
- Assert on event order (positional) and content

### 6. Load Tests

Test throughput and latency against a compiled server. `load-test` uses an open workload
model (a fixed arrival `rate`) and reuses the same request syntax as `api-test`.

**✅ Do:**
```tesl
load-test "list todos throughput" for TodoServer
  rate 100rps
  duration 10s
  requires [dbRead Todo] {
  get "/todos"

  assert p99 < 200ms
  assert p95 < 80ms
  assert errorRate < 0.01
  assert throughput > 80rps
}
```

**Key patterns:**
- Declare the arrival `rate` (`Nrps`) and measurement `duration` (`Ns`)
- Put a single `api-test`-style request in the body
- `assert` on histogram percentiles (`p50`/`p95`/`p99`/`p99.9`), `errorRate`, and `throughput`
- Compare against a stored baseline with `assert regressionVsBaseline <metric> < <n>`
- Reserve load tests for performance-critical endpoints

### 7. Mutation Testing

Mutation testing automatically modifies your validation functions and checks if your tests catch the bugs. This is critical for ensuring your validation logic is thoroughly tested.

**How it works:**
1. Tesl identifies all `check`, `establish`, and `auth` functions
2. For each function, it creates "mutants" (slightly modified versions)
3. Runs your tests against each mutant
4. Reports which mutants were **killed** (tests failed) and which **survived** (tests passed)

**✅ Do:**
```bash
# Run mutation testing on a single file
tesl mutate api.tesl

# Run mutation testing with specific test files
tesl mutate api.tesl tests/api.test.tesl

# Run mutation testing on all files
tesl mutate **/*.tesl
```

**Example output:**
```
Mutation testing: api.tesl

  [KILLED]   isValidEmail - changed condition from > to >=
  [KILLED]   isValidTitle - removed length check
  [SURVIVED] isValidAge - changed > 0 to >= 0  <-- NEEDS BETTER TESTS!
  [KILLED]   authenticateUser - removed password check

Mutation score: 85% (17/20 mutants killed)
```

**Interpreting results:**
- **Killed mutants**: Your tests caught the bug - good!
- **Survived mutants**: Your tests didn't catch the bug - you need better tests
- **Mutation score**: Percentage of mutants killed - aim for 80%+

**When a mutant survives:**
1. Look at what was changed (shown in the output)
2. Understand why your tests didn't catch it
3. Add or improve tests to catch this case
4. Re-run mutation testing

**Key patterns:**
- Run mutation testing regularly, especially before merging
- Aim for a mutation score of at least 80%
- Focus on critical validation functions first
- Survived mutants indicate missing test cases

### Test Best Practices

#### 1. The Testing Pyramid

Follow the testing pyramid principle:

```
          ┌─────────────┐
          │   Load      │  Few, slow, broad
          │   Tests     │
          └──────┬──────┘
                 │
          ┌──────▼──────┐
          │   Queue/    │  Moderate, async behavior
          │   SSE Tests │
          └──────┬──────┘
                 │
          ┌──────▼──────┐
          │  API Tests  │  Many, HTTP endpoints
          │             │
          └──────┬──────┘
                 │
          ┌──────▼──────┐
          │  Unit/Prop  │  Most, pure functions
          │   Tests     │
          └─────────────┘
```

#### 2. Test Naming

**✅ Do:**
```tesl
-- Good: describes behavior and expected outcome
api-test "POST /users returns 400 when email is invalid"

-- Good: describes the property being tested
test "isValidEmail returns Ok for valid emails"

-- Good: describes the scenario
api-test "ProcessPayment handles insufficient funds"
```

**❌ Don't:**
```tesl
-- Bad: too vague
test "test1"

-- Bad: doesn't describe what's being tested
test "user test"

-- Bad: uses implementation details
test "user controller create method"
```

#### 3. Test Structure

Follow the Arrange-Act-Assert pattern:

```tesl
api-test "POST /users creates user and returns 201" for TodoServer {
  -- Arrange: setup test data
  let newUser = { email: "test@example.com", name: "Test User" }
  
  -- Act: perform the operation
  let result = post "/users" body newUser
  
  -- Assert: verify the outcome
  expect statusCreated result.status
  expect result.body.email == "test@example.com"
}
```

#### 4. Test Isolation

- Each test should be independent of others
- Don't rely on state from previous tests
- Use setup/teardown patterns if needed
- Reset database state between tests

**✅ Do:**
```tesl
api-test "first test" for TodoServer {
  -- Create test data
  let todo1 = createTestTodo()
  -- Test with todo1
  -- Clean up
  deleteTodo todo1.id
}

api-test "second test" for TodoServer {
  -- Create fresh test data
  let todo2 = createTestTodo()
  -- Test with todo2
  -- Clean up
  deleteTodo todo2.id
}
```

#### 5. Testing Validation Functions

Validation functions (`check`, `establish`, `auth`) are critical and should be thoroughly tested:

1. **Test valid inputs** - ensure they pass
2. **Test invalid inputs** - ensure they fail with appropriate errors
3. **Test edge cases** - boundary values, empty strings, null, etc.
4. **Use mutation testing** - to catch subtle bugs

**✅ Do:**
```tesl
# Test valid inputs
test "isValidEmail accepts valid emails" {
  expect (isValidEmail("test@example.com")).isOk == true
  expect (isValidEmail("user@domain.co.uk")).isOk == true
}

# Test invalid inputs
test "isValidEmail rejects invalid emails" {
  expect (isValidEmail("")).isError == true
  expect (isValidEmail("not-an-email")).isError == true
  expect (isValidEmail("@example.com")).isError == true
}

# Test edge cases
test "isValidEmail handles long emails" {
  let longEmail = "a" ++ String.replicate 250 "x" ++ "@example.com"
  expect (isValidEmail(longEmail)).isError == true  # or true, depending on spec
}
```

#### 6. Testing Error Cases

Don't forget to test that errors are handled correctly:

```tesl
api-test "GET /todos/:id returns 404 for non-existent todo" for TodoServer {
  let result = get "/todos/nonexistent-id"
  expect result.status == 404
  expect String.contains result.body "not found"
}

api-test "POST /todos returns 400 for invalid title" for TodoServer {
  let result = post "/todos" body { title: "" }
  expect result.status == 400
  expect String.contains result.body "Title must be between 3 and 120 characters"
}
```

#### 7. Test Data Builders

Create helper functions to build test data:

```tesl
# In a test helper module
fn createTestUser(?email: String, ?name: String) -> User ::: FromDb (Id == user.id)
  requires [dbWrite User, time] =
  let user = {
    id: generatePrefixedId("test-user"),
    email: email | default "test@example.com",
    name: name | default "Test User",
    createdAt: nowMillis()
  } in
  insert User user

fn createTestTodo(?title: String, ?userId: String) -> Todo ::: FromDb (Id == todo.id)
  requires [dbWrite Todo, dbWrite User, time] =
  let todo = {
    id: generatePrefixedId("test-todo"),
    title: title | default "Test todo",
    userId: userId | default (createTestUser()).id,
    completed: false,
    createdAt: nowMillis()
  } in
  insert Todo todo
```

Then use them in tests:

```tesl
api-test "GET /users/:id/todos returns user's todos" for TodoServer {
  let user = createTestUser(email: "alice@example.com")
  let todo1 = createTestTodo(title: "First todo", userId: user.id)
  let todo2 = createTestTodo(title: "Second todo", userId: user.id)
  let todo3 = createTestTodo(title: "Other user's todo")
  
  let result = get ("/users/" ++ user.id ++ "/todos")
  expect statusOk result.status
  expect List.length result.body == 2
}
```

### Running Tests

```bash
# Run all tests in a file
tesl test my-api.test.tesl

# Run multiple test files
tesl test tests/*.test.tesl

# Run with verbose output
tesl test my-api.test.tesl  # Set TESL_VERBOSE=1 for more details

# Run a single named block
tesl test --test-name "my test" my-api.test.tesl

# Disambiguate same-named blocks of different kinds with --test-kind
# (<kind> is one of: test | api-test | load-test | doctest). This is also
# what lets a single api-test/load-test/doctest be run in isolation.
tesl test --test-name "my flow" --test-kind api-test my-api.test.tesl

# Check test syntax without running
tesl check my-api.test.tesl
```

> **Debugging note:** under `--test-name` only the selected block is compiled
> and emitted. Breakpoints set in *other* test blocks are therefore silently
> dead for the duration of a single-test debug session — they are not broken,
> just not part of the emitted program. Re-run without `--test-name` (or select
> the block that owns the breakpoint) to make them fire. This applies to
> `test`, `api-test`, and `doctest` blocks alike; `load-test` request bodies
> are never instrumented (they are throughput benchmarks).

### Test Configuration

**Tests are in-memory by default.** Test blocks run against an automatic in-memory store, so the vast majority of tests need no database setup. Add a `with database X` header clause only when a test needs a specific or real backend — it binds the named database `X` so queries in the block run against `X`'s configured backend:

```tesl
test "rejects duplicate emails" with database AppDb {
  -- queries here hit AppDb's configured backend instead of the in-memory store
}
```

Configure test behavior in your test files:

```tesl
-- Set up test database
beforeAll for TodoServer = 
  runMigration "test-migration.sql"

-- Clean up after all tests
afterAll for TodoServer = 
  runMigration "test-cleanup.sql"

-- Set up before each test
beforeEach for TodoServer = 
  clearTable Todo
  clearTable User

-- Clean up after each test
afterEach for TodoServer = 
  clearTable Todo
  clearTable User
```

### Test Utilities

Tesl provides several test utilities:

```tesl
-- Assertions
expect condition          -- Assert condition is true
expect condition message  -- Assert with custom message
expectEqual a b          -- Assert a equals b
expectNotEqual a b       -- Assert a does not equal b
expectError fn           -- Assert fn raises an error
expectSome option        -- Assert option is Some
expectNone option        -- Assert option is None
expectOk result          -- Assert result is Ok
expectErr result         -- Assert result is Err

-- HTTP assertions
expect statusOk status        -- 200
expect statusCreated status   -- 201
expect statusNoContent status  -- 204
expect statusBadRequest status  -- 400
expect statusNotFound status     -- 404

-- Matchers
String.contains haystack needle    -- Check if string contains substring
String.startsWith str prefix      -- Check if string starts with prefix
String.endsWith str suffix        -- Check if string ends with suffix
List.contains list item           -- Check if list contains item
List.length list == n             -- Check list length
```

### Debugging Tests

When tests fail, use these techniques:

1. **Read the error message** - Tesl provides detailed error messages
2. **Check the test output** - Use `TESL_VERBOSE=1` for verbose output
3. **Add temporary output** - Use `println` for debugging:
   ```tesl
   test "debug test" {
     let x = computeSomething()
     println "x is: " x  # Debug output
     expect x > 0
   }
   ```
4. **Run a single test** - Isolate the failing test
5. **Check the database** - Manually inspect the test database state

### Test Performance Tips

1. **Reuse test servers** - Start the server once and run multiple tests
2. **Reset state efficiently** - Use `beforeEach`/`afterEach` instead of `beforeAll`/`afterAll` when possible
3. **Parallelize tests** - Run different test files in parallel
4. **Mock external services** - Don't test external API integrations in unit tests
5. **Use test doubles** - For complex dependencies that are hard to test

### Test Coverage

Tesl doesn't have built-in coverage reporting, but you can:

1. Use mutation testing (`tesl mutate`) to measure test quality
2. Manually track which functions are tested
3. Aim for 100% coverage of validation functions
4. Aim for 80%+ coverage of business logic

### Common Test Anti-Patterns

**❌ Don't:**
```tesl
# Testing implementation details
test "handler uses selectOne" {
  # This tests HOW the handler works, not WHAT it does
  # Better: test the behavior, not the implementation
}

# Testing too much in one test
test "complex scenario with many assertions" {
  let result = doComplexOperation()
  expect result.a == 1
  expect result.b == 2
  expect result.c == 3
  expect result.d == 4
  # Better: split into multiple focused tests
}

# Slow tests in the wrong place
test "sleep test" {
  Thread.sleep 10000
  # Better: use load tests for timing tests
}

# Tests that depend on each other
test "first" { ... }   # creates data
test "second" { ... }  # depends on data from first — better: each test independent
```

**✅ Do instead:**
- Test behavior, not implementation
- Keep tests focused on one thing
- Use appropriate test types (unit, API, load, etc.)
- Keep tests independent

---

## Performance

### Minimize Allocations

- **Proof tracking is erased** on the standard path — in release and `--debug` alike (see
  [Proof Cost Model](#proof-cost-model)), so composing predicates or annotating values costs
  essentially nothing. The one exception is a proof-annotated *parameter*, which keeps ≤1
  `named-value` allocation so decomposition works (§4.3) — cheap, but not a bare zero.
- **Prefer value-level proofs** over free-floating proofs (`detachFact` / `attachFact`): a
  free-floating proof keeps a runtime carrier even in release builds, whereas a value-level
  annotation only ever retains at most that single parameter allocation.
- **Batch database queries** when possible.

### Caching

**✅ Do:** Cache expensive validation results. Consider using a database-backed cache for horizontal scaling.

### Database Indexing

Declare indexes on the entity, next to the fields they cover. They are created by the ordinary startup migration, so a fresh environment comes up indexed instead of quietly running sequential scans:

```tesl
entity Todo table "todos" primaryKey id {
  id:        String
  userId:    String
  slug:      String
  createdAt: PosixMillis

  # The shape of the query, not one index per column: an index on
  # [userId, createdAt] serves `where t.userId == uid order t.createdAt desc`
  # AND a filter on userId alone, so a separate [userId] index is dead weight.
  index [userId, createdAt]

  # `unique` declares an invariant, not just a lookup path — and it is what
  # makes `onConflict [userId, slug]` legal (see below).
  unique index [userId, slug]
}
```

**The linter finds these for you.** `tesl lint` compares every query in the file against the declared indexes and reports what is missing (**W092**) and what is unused (**W093**):

```
warning[W092]: 2 queries on `Todo` constrain `ownerId`, but no index on `Todo` can
serve it — every matching row is found by scanning the whole table; add
`index [ownerId]` to the entity
```

Few other languages can tell you this, because it needs the whole program's query set — which Tesl already has at compile time. The rules are deliberately quiet: they only speak up for entities backed by a Postgres `database` declared in the same file, they skip `test` blocks, they ignore `like`/`ilike` columns (a default-collation B-tree cannot serve those anyway), and an index counts as serving a query whenever its *leading* column is one the query constrains. W093 additionally stays silent in a schema-only module, since the queries needing those indexes may live elsewhere.

**✅ Do:** index the column combinations your `where`, `order` and `innerJoin` clauses actually use — the leading columns of a composite index serve prefix filters too.

**✅ Do:** use `unique index` when a combination must not repeat. It is enforced by PostgreSQL, and by the Memory backend during tests.

**❌ Don't:** index the primary key (already indexed), or add an index no query uses — every index costs write throughput.

**`upsert` needs one.** `onConflict [cols]` requires the primary key or a `unique index` on exactly those columns; PostgreSQL cannot infer a conflict target otherwise. The compiler rejects the mismatch, so this is caught at build time rather than in production.

**Adding an index to a table that already has rows** is deliberately not automatic: building an index locks out writes for the duration, and the safe `CONCURRENTLY` form cannot run inside the migration's transaction. The program prints the exact statement to run — a missing plain index only warns, while a missing `unique index` refuses to start, because that one is an unenforced invariant:

```sh
psql -c 'CREATE INDEX CONCURRENTLY IF NOT EXISTS "todos_user_id_created_at_idx" ON "public"."todos" ("user_id", "created_at");'
```

---

## Common Pitfalls and Solutions

### Problem: enqueued jobs are never processed, or published events reach nobody

**Solution:** List the queue or channel in your `main` function's `App` record. That is what starts a queue's workers and a channel's delivery — declaring it is not enough, and an unactivated queue still *accepts* work, so `enqueue` succeeds, the job row is written, and nothing ever drains it. There is no error, only a table that grows.

```tesl
main() -> App requires [appService] =
  App {
    database:    MainDatabase
    api:         AppServer
    port:        8086
    queues:      [EmailQueue]      # ← without this, EmailQueue never runs
    sseChannels: [UserEvents]      # ← without this, publishes reach no subscriber
  }
```

`tesl lint` reports this as **W094**. Activation refs must name a declaration in the same module, so whichever module declares the queue is the module that has to activate it. Test modules are exempt: inside an `api-test` the workers run synchronously (see [Queue Tests](#4-queue-tests)), so a module with no `main` is never reported.

### Problem: "Proof not found" errors

**Solution:** Ensure you're attaching proofs at the validation boundary:
```tesl
-- ✅ Correct
check validateEmail(email: String) -> email: String ::: ValidEmail email = ...

-- ❌ Incorrect (missing proof attachment)
fn validateEmail(email: String) -> String = ...
```

### Problem: "Cannot find proof for predicate X"

**Solution:** Make sure the proof is in scope and attached to the value. Use `detachFact` and `attachFact` for explicit proof manipulation.

### Problem: "Type mismatch" in API endpoints

**Solution:** Check that your API endpoint and handler signatures match the actual types. Use `:::` annotations to make proofs explicit.

### Problem: Database query type inference fails

**Solution:** Make sure your entity declaration has the correct fields and types, and your query references them correctly.

---

## See Also

- [Manual Index](MANUAL.md) - Back to the main manual
- [Stable Anchor Scheme](anchors.md) - Deep-link IDs (error messages cite this file's anchors)
- [Examples](examples.md) - Complete list of examples
- [LANGUAGE-SPEC.md](../LANGUAGE-SPEC.md) - Formal specification
- [Guided Feature Tour](tour.md) - The long-form language walkthrough
