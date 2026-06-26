# Standard Library Expansion

Focused on modules that cover the most common web-API needs not yet in `Tesl.Prelude`.

---

## 1. `Tesl.UUID` — UUID Generation

**Use case:** Generating entity IDs, idempotency keys, file names, and correlation IDs for distributed tracing.

**API surface:**

```tesl
fn UUID.v4     () -> String   # random UUID (most common)
fn UUID.v7     () -> String   # time-ordered UUID (better for DB primary keys)
uuidV4Codec                   # codec for JSON serialization
uuidV7Codec
```

UUID v7 is preferred for database primary keys because it encodes a timestamp prefix, giving sequential inserts better B-tree locality than random v4 UUIDs.

**Example:**

```tesl
# Assign a UUID primary key before insert
let id  = UUID.v4()
let row = { id: id, name: productName, createdAt: now }
insert Product row
```

**Capabilities:** `uuid` (covers both v4 and v7). `UUID.validate` requires no capability (pure function).

**Proof support:**
- `UUID.validate` check function: returns `s ::: IsUuid s`
- `IsUuid` predicate usable as proof annotation on String parameters

**Codecs:** `uuidV4Codec` and `uuidV7Codec` — serialize as plain JSON string, decoder validates UUID format.

---

## 2. `Tesl.Auth.JWT` — JWT / Auth Tokens

**Use case:** Issuing and verifying JSON Web Tokens for stateless authentication. Currently requires boilerplate calling raw crypto functions.

**API surface:**

```tesl
# JwtToken and JwtSecret are nominal newtypes wrapping String
fn JWT.sign   (claims: a, secret: JwtSecret) -> JwtToken      # HS256
fn JWT.verify (token: JwtToken, secret: JwtSecret) -> a        # fails 401 if invalid/expired
fn JWT.decode (token: JwtToken) -> a                            # no signature check
```

`JWT.verify` fails with HTTP 401 if the signature is invalid or the token has expired.

`JwtToken` and `JwtSecret` are nominal types — they are NOT interchangeable with plain `String` or with each other. This prevents accidentally passing a raw string where a token is expected and vice versa.

**Example:**

```tesl
# Issue a token at login
let token = JWT.sign { sub: userId, exp: nowPlusOneHour, role: "user" } jwtSecret

# Verify at a protected endpoint
let claims = JWT.verify authToken jwtSecret
let userId = claims.sub
```

**Capabilities:** `jwt` (required for sign, verify, and decode).

**Implementation:** HMAC-SHA256 (HS256) using `openssl/libcrypto` FFI (same pattern as `sasl-lib`). Base64url encoding via `net/base64`.

---

## 3. `Tesl.HttpClient` — HTTP Client

**Use case:** Calling external APIs (payment processors, third-party services, internal microservices).

**Note on naming:** The `Http` prefix is already used for the server-side HTTP module (`Tesl.Http`). Use `HttpClient` prefix to avoid conflict.

**API surface:**

```tesl
fn HttpClient.get    (url: String, headers: List (Tuple2 String String)) -> HttpResponse
fn HttpClient.post   (url: String, headers: List (Tuple2 String String), body: String) -> HttpResponse
fn HttpClient.put    (url: String, headers: List (Tuple2 String String), body: String) -> HttpResponse
fn HttpClient.delete (url: String, headers: List (Tuple2 String String)) -> HttpResponse

# HttpResponse is a record
type HttpResponse = { status: Int, body: String, headers: List (Tuple2 String String) }
```

**Capabilities:** `http-client` (required for all four functions). Field access on `HttpResponse` requires no capability.

**Example:**

```tesl
let res = HttpClient.post
  "https://api.stripe.com/v1/charges"
  [Tuple2 "Authorization" "Bearer sk_live_..."]
  "amount=2000&currency=usd"
let ok = res.status == 200
```

**Implementation:** Racket `net/http-client` for HTTP/HTTPS. SSL via `openssl`. `HttpResponse` is a stdlib record type with fixed fields.

**JSON decoding:** Use the existing codec/`via` syntax to decode `res.body` into a typed record.

---

## Priority Order

| # | Module | Complexity | Impact |
|---|--------|------------|--------|
| 1 | `Tesl.UUID` | Low | High |
| 2 | `Tesl.JWT` | Low–Medium | High |
| 3 | `Tesl.HttpClient` | Medium | High |

## Test target

At least 100 tests per module across OCaml compiler tests, Racket runtime tests, and .tesl test files. See the main implementation plan for full test lists.

## General notes

- Use proofs wherever they make sense (`IsUuid`, JWT nominal types)
- All functions should require appropriate capabilities
- New lesson files: `example/learn/lesson28.tesl` (UUID), `lesson29.tesl` (JWT), `lesson30.tesl` (HttpClient)
