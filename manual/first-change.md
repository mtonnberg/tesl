# Your First Change

You have run `tesl init` and the scaffold works. This page is the next 15 minutes: **add one real
feature to it, hit a proof error on purpose, and understand why the compiler is right.**

`tesl help manual first-change` prints this page from the CLI.

Prerequisites: [GETTING-STARTED.md](GETTING-STARTED.md) through step 2 — a scaffolded project you
can `tesl run`. This page assumes the **`api`** template (the `tesl init` default: a PostgreSQL
`entity`, cookie auth, an input proof and an output proof).

---

## The feature

The scaffold gives you `POST /todos` (create) and `GET /todos/:todoId` (read). The obvious third
endpoint is **rename**: `PUT /todos/:todoId`. Building it is four edits, and the third one is where
Tesl says something interesting.

### Edit 1 — a body record and its decoder

Open `app.tesl`. Find the `fact TodoId` line (just below the `NewTodo` codec) and paste this
*above* it:

```tesl
record TodoRename {
  title: String
}

codec TodoRename {
  toJson_forbidden
  fromJson [
    {
      title <- "title" with_codec stringCodec
    }
  ]
}
```

### Edit 2 — the handler

Find `api AppApi {` and paste this *above* it:

```tesl
handler renameTodo(requestUser: User ::: Authenticated requestUser, todoId: String ::: TodoId todoId, rename: TodoRename)
  -> Todo ? FromDb (Id == todoId)
  requires [appDbRead, appDbWrite] =
  let existing = selectOne todo from Todo where todo.id == todoId
  case existing of
    Nothing ->
      fail 404 "Todo not found"
    Something todo where todo.ownerId != requestUser.id ->
      fail 403 "Todo not owned by request user"
    Something _ ->
      update todo in Todo
        where todo.id == todoId
        set todo.title = rename.title
        returning one
```

### Edit 3 — the route and the wiring

Inside `api AppApi { … }`, after the existing `get "/todos/:todoId"` block:

```tesl
  put "/todos/:todoId"
    auth requestUser: User ::: Authenticated requestUser via cookieAuth
    capture todoId: String ::: TodoId todoId via todoIdCapture
    body rename: TodoRename
    -> Todo ? FromDb (Id == todoId)
```

and in `server AppServer for AppApi { … }`, next to `getTodo = getTodo`:

```tesl
  renameTodo = renameTodo
```

Now:

```bash
tesl check app.tesl
```

**It compiles.** Silence means success.

---

## The problem the compiler did *not* stop

Your new endpoint works, and it accepts a 4 000-character title — while `POST /todos` rejects
anything outside 4–120 characters. The two paths that write the same column now disagree about what
is allowed.

Tesl did not complain, and that is correct: you never claimed the rename title was validated.
`record TodoRename { title: String }` is an honest declaration of an unvalidated string. **The
compiler does not stop you from writing an unvalidated endpoint. It stops you from pretending one is
validated.**

So make the claim. Change one line in `record TodoRename`:

```tesl
record TodoRename {
  title: String ::: TitleSafe title
}
```

`String ::: TitleSafe title` means "a string that carries proof it is a safe title" — the same
declaration the scaffold's `NewTodo` uses. Run it again:

```bash
tesl check app.tesl
```

## The error

```text
error[V001]: codec 'TodoRename': decoder field 'title' requires proof predicates TitleSafe but has no `via` validation
Hint: add `via <checkFn>` so field 'title' is validated before decoding succeeds
  --> app.tesl:125:7

  read more: tesl help manual best-practices#validation-patterns  (explain: tesl help V001)
```

The line number depends on where you pasted; the span points at the `title <- "title" …` line inside
`fromJson`, not at the record. That is deliberate, and it is the whole point of the next section.

---

## Why the compiler is right

This is the part worth reading twice.

**1. A fact is a claim, and only a `check` can mint it.** `TitleSafe` is declared in the scaffold as
`fact TitleSafe (title: String)`, and exactly one function in the program can produce it:

```tesl
check isSafeTitle(title: String) -> title: String ::: TitleSafe title =
  if 4 <= String.length title && String.length title <= 120 then
    ok title ::: TitleSafe title
  else
    fail 400 "Title must be between 4 and 120 characters"
```

There is no cast, no assertion, no `unsafeAssume`. If a value carries `TitleSafe`, control passed
through `isSafeTitle` and took the `ok` branch. That is the only history it can have.

**2. Your record demanded the proof; your decoder never earned it.** After that one-line change,
every `TodoRename` in the program is required to carry `TitleSafe`. The decoder is the *only* place a
`TodoRename` is ever built — it is how untrusted JSON becomes a typed value. With no `via`, the
decoder takes a raw string from the wire and hands back a value the type says is proven. That is a
forged proof, and it is the exact bug class the language exists to eliminate.

**3. That is why the span is on the decoder line, not the record line.** The record is not wrong.
Asking for proof is the good decision. The *boundary* is wrong: it is the one place with the raw
input in hand and the obligation to validate it, and it is the only place a fix can go. Tesl points
at where the mistake is repairable, not at where the requirement was written.

**4. Nothing downstream has to defend itself.** `renameTodo` does not re-check the title. The
`update` does not re-check it. Neither *can* be reached with an unproven title, so a defensive
re-check would be dead code. This is the trade: one enforced check at the boundary buys you the
absence of validation logic everywhere else.

---

## The fix

Add the `via`:

```tesl
      title <- "title" with_codec stringCodec via isSafeTitle
```

```bash
tesl check app.tesl
```

Silence. The rename endpoint now enforces the same 4–120 rule as create, and it enforces it *before*
`renameTodo` runs — a bad title is a 400 from the decoder, not a guard clause you remembered to
write.

### A near miss, and why it also fails

The compiler checks *which* proof you established, not merely that a `via` is present. Point it at
the wrong check — the scaffold's `isTodoId`, which establishes `TodoId` — and:

```text
error[V001]: codec 'TodoRename': decoder field 'title' requires proof predicates TitleSafe that are not established by any `via` function
Hint: via functions provided: isTodoId
  --> app.tesl:125:7

  read more: tesl help manual best-practices#validation-patterns  (explain: tesl help V001)
```

A different message for a different mistake. Proofs have identity; "I validated *something*" is not
an argument.

---

## Every diagnostic has a code

That `V001` is not decoration. **Every diagnostic the compiler can emit carries a stable code**, a
precise span, a manual deep-link, and — where the edit is mechanical — a machine-applicable fix your
editor can apply.

```bash
tesl explain V001                                     # the full explanation for one code
tesl help manual best-practices#validation-patterns   # the deep-link the error printed
tesl help codes                                       # every code the compiler can emit
```

`tesl explain V001` prints (long paragraph re-wrapped here for page width):

```text
V001  [structure]
  validation error

A semantic validation pass rejected the program. This covers a family of checks that run after
parsing/typing: call-site proof satisfaction, capability declarations, codec/SQL field coverage,
server binding completeness, and structural rules (channels, databases, tests). The message
describes the specific rule; `tesl help manual` links below point at the most relevant section for
the kind of error.

read more: tesl help manual best-practices#validation-patterns
```

The codes are stable across releases, which is what makes them worth putting in a commit message, a
bug report, or an AI agent's prompt. The same information reaches tooling as JSON —
`tesl agent-context app.tesl` gives an agent the diagnostics, symbols and outstanding proof
obligations in one call (see [AGENTS.md](../AGENTS.md)).

---

## Run it

```bash
tesl run app.tesl
```

In another terminal — create a todo, then rename it, then try to rename it to something too short:

```bash
curl -sS -X POST http://localhost:8086/todos \
  -H 'content-type: application/json' -H 'Cookie: user=demo' \
  -d '{"title":"Read the Tesl tutorial"}'

curl -sS -X PUT http://localhost:8086/todos/todo-1 \
  -H 'content-type: application/json' -H 'Cookie: user=demo' \
  -d '{"title":"Read the Tesl manual instead"}'

curl -sS -X PUT http://localhost:8086/todos/todo-1 \
  -H 'content-type: application/json' -H 'Cookie: user=demo' \
  -d '{"title":"no"}'
```

The last one is a 400 from the decoder. No handler code ran.

Before committing, run the whole loop:

```bash
tesl validate app.tesl    # check + lint + format check
tesl test app.tesl        # the file's test blocks
```

---

## What to take away

- **Declare the guarantee on the data shape.** `title: String ::: TitleSafe title` is where the
  requirement lives; every boundary that builds that shape then has to satisfy it.
- **Validate at the boundary, once.** A codec `via`, a `capturer via`, or an `auth` — never a
  re-check in a handler.
- **The error points at the repairable place.** When a proof is missing, look at the boundary that
  produced the value, not at the code that consumed it.
- **Unproven is allowed; *falsely* proven is not.** Adding proofs is incremental. Start with one
  fact, add more as the domain gets sharper.

---

## Next

1. **[Best Practices](best-practices.md)** — the idiomatic version of everything above, including
   [naming conventions](best-practices.md#naming-conventions) and the
   [proof cost model](best-practices.md#proof-cost-model)
2. **[Guided Feature Tour](tour.md)** — the long read: typed SQL, capabilities, queues, SSE, agents,
   `ForAll` proofs
3. **[Examples](examples.md)** — the bundled examples and the `example/learn/` lesson corpus
4. **[FAQ](FAQ.md)** — when something does not behave the way this page implies

---

## See Also

- [Getting Started](GETTING-STARTED.md) — the page before this one
- [Manual Index](MANUAL.md) — back to the manual
- [Deploying a Tesl web API](deploy.md) — `tesl build` and the Docker image
- [dev-docs/README.md](../dev-docs/README.md) — changing the Tesl compiler instead
