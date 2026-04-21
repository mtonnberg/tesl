# Auth the Compiler Enforces

In most frameworks, auth is a middleware, a decorator, an attribute. If you forget to apply it, nothing tells you until a request hits production.

In Tesl, **auth produces a proof**. A handler that requires authentication declares it in its signature. The compiler rejects any wiring that leaves auth out.

---

## Auth produces a proof

```tesl
fact Authenticated (user: User)

auth cookieAuth(request: HttpRequest) -> user: User ::: Authenticated user
  requires [readCookies] =
  case request.cookies.user of
    Nothing  -> fail 401 "not logged in"
    Something uid -> ok (User { id: uid }) ::: Authenticated user
    #                                       ^^^
    #                           stamp: this User is now Authenticated
```

`auth` is the special form for authentication. It reads the request and either produces a value with `Authenticated` proof, or fails with a 401. The proof is unforgeable — only `auth` functions can introduce it.

---

## Handlers declare what they need

```tesl
handler listMyTodos(user: User ::: Authenticated user)  # requires the stamp
  -> List Todo
  requires [dbRead] =
  select todo from Todo where todo.ownerId == user.id
```

You cannot call `listMyTodos` with a plain `User` — the compiler rejects it. Not a runtime check. A type error.

---

## The API wires it together

```tesl
api TodoApi {
  get "/todos/mine"
    auth user: User ::: Authenticated user via cookieAuth   # declared here
    -> List Todo

  get "/todos/public"
    -> List Todo   # no auth declared — handler must not require Authenticated
}
```

`via cookieAuth` tells the compiler which auth function produces the proof. Remove the `auth` line from an endpoint whose handler requires `Authenticated user` → compile error. Wire the wrong auth function that produces a different proof → compile error.

---

## A complete auth chain, step by step

```
HTTP request
    │
    ▼ cookieAuth runs — reads the "user" cookie
    │   Missing  → 401 returned to client
    │   Present  → User ::: Authenticated user
    │
    ▼ Handler receives user with proof already attached
    │
    ▼ Business logic runs — user.id is provably from a real auth check
```

---

## Why this matters at scale

| Approach | How auth is enforced |
|---|---|
| Express middleware | Runtime — forget to attach, it silently doesn't run |
| Spring `@PreAuthorize` | Runtime annotation — misconfigure and it fails open |
| ASP.NET `[Authorize]` | Runtime attribute — must be applied manually everywhere |
| **Tesl** | **Compile time — missing auth is a type error** |

Refactor a handler? The compiler tells you if you lost auth. Add a new endpoint? You can't accidentally make it public if the handler requires `Authenticated`. The requirement is visible in the handler signature — not buried in a middleware chain.

---

*Next: [Explicit side effects →](04-capabilities.md)*
