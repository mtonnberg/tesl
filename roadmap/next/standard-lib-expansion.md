# Standard Library Expansion Roadmap

Focused on modules that cover the most common web-API needs not yet in `Tesl.Prelude`.

---

## 1. `Tesl.Http.Client` — HTTP Client

**Use case:** Calling external APIs (payment processors, third-party services, internal microservices).

**API surface:**

```tesl
fn Http.get    (url: String, headers: List (Tuple2 String String)) -> Response
fn Http.post   (url: String, headers: List (Tuple2 String String), body: String) -> Response
fn Http.put    (url: String, headers: List (Tuple2 String String), body: String) -> Response
fn Http.delete (url: String, headers: List (Tuple2 String String)) -> Response

type Response = { status: Int, body: String, headers: List (Tuple2 String String) }
```

**capabilities** All of http calls should require a new capability "http-client".

**Example:**

```tesl
let res = Http.post
  "https://api.stripe.com/v1/charges"
  [Tuple2 "Authorization" "Bearer sk_live_..."]
  "amount=2000&currency=usd"
let ok = res.status == 200
```

**Json** remember to support json decoding and proofs using the via syntax, just as the api declaration does
---

## 2. `Tesl.Auth.JWT` — JWT / Auth Tokens

**Use case:** Issuing and verifying JSON Web Tokens for stateless authentication. Currently requires boilerplate calling raw crypto functions.

**API surface:**

```tesl
type JwtClaims = { sub: String ::: IsNonEmpty sub && IsTrimmed sub, exp: PosixMillis, role: String ::: IsNonEmpty role && IsTrimmed role}
# JWT.Token is nominal String Type
# JWT.Secret is nominal String Type
fn JWT.sign   (claims: JwtClaims, secret: JWT.Secret) -> JWT.Token
fn JWT.verify (token: JWT.Token, secret: JWT.Secret) -> JwtClaims
fn JWT.decode (token: JWT.Token) -> JwtClaims   # no signature check
```

**Example:**

```tesl
# Issue a token at login
let token = JWT.sign { sub: userId, exp: nowPlusOneHour, role: "user" } jwtSecret

# Verify at a protected endpoint
let claims = JWT.verify authHeader jwtSecret
let userId = claims.sub
```

`JWT.verify` fails with HTTP 401 if the signature is invalid or the token has expired, so no explicit error-handling boilerplate is needed.

**capabilities** using JWT.sign/verify should require a new capability "jwt"
---

## 3. `Tesl.UUID` — UUID Generation

**Use case:** Generating entity IDs, idempotency keys, file names, and correlation IDs for distributed tracing.

**API surface:**

```tesl
fn UUID.v4     () -> String          # random UUID (most common)
fn UUID.v7     () -> String          # time-ordered UUID (better for DB primary keys)
uuidV4Codec
uuidV7Codec
```

**Example:**

```tesl
# Assign a UUID primary key before insert
let id  = UUID.v4()
let row = { id: id, name: productName, createdAt: now }
insert Product row
```

`UUID.v7` is preferred for database primary keys because it encodes a timestamp prefix, giving sequential inserts better B-tree locality than random v4 UUIDs.

**capabilities** using uuid generation should require the time and random capabilities (and any other that is suitable).

---

## Priority Order

| # | Module | Complexity | Impact |
|---|--------|------------|--------|
| 1 | `Tesl.UUID` | Low | High |
| 2 | `Tesl.Auth.JWT` | Low | High |
| 3 | `Tesl.Http.Client` | Medium | High |

## General notes

Remember to utilize heavy use of proofs in the standard libs wherever makes sense/is possible. Write a lot of tests. Remember that functions should require appropiate capabilities (time, random etc)