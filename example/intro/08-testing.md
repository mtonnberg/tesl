# Testing Built Into the Language

Tesl has two testing primitives: `api-test` blocks that exercise the full HTTP boundary, and built-in mutation testing for validation functions. No testing framework to install, no test runner to configure.

---

## api-test: the full HTTP stack in one block

```tesl
api-test "creates a todo and returns it" for TodoServer
  requires [dbRead, dbWrite, time, random] {

  let resp = post "/todos"
    cookie "user=mikael"
    body { "title": "Write the first Tesl program" }

  expect statusOk resp.status
  expect resp.body.title == "Write the first Tesl program"
  expect resp.body.status == "Open"
}
```

`api-test` runs against a fresh in-memory database — no setup, no teardown. It exercises routing, auth, codec parsing, database writes, and response serialization. This is the wire contract your clients actually see.

---

## Seed state for complex scenarios

```tesl
api-test "cannot access another user's todo" for TodoServer
  requires [dbRead, dbWrite] {

  seed {
    insert Todo { id: "todo-1", title: "Anna's note", ownerId: "anna",
                  status: Open, createdAt: 0 }
  }

  let resp = get "/todos/todo-1" cookie "user=mikael"
  expect statusClientError resp.status   # 403, not 404 — ownership check ran
}
```

`seed` inserts data directly without going through the API — useful for state that's hard to build through endpoints.

---

## Test queues and SSE together

```tesl
api-test "message notification reaches the room stream" for ChatServer
  requires [chatRead, chatWrite, chatPubSub, chatQueue, notifyCap] {

  seed {
    insert ChatUser { id: "usr-alice", username: "alice" }
    insert Room { id: "room-1", name: "General", createdAt: 0 }
  }

  let stream = subscribe "/events/rooms/room-1" cookie "chatUserId=usr-alice"

  let _ = post "/rooms/room-1/messages"
            cookie "chatUserId=usr-alice"
            body { "content": "hello" }

  expect pendingJobCount NotificationQueue == 1
  let job = expectJobOk (processNextJob NotificationQueue)
  expect job.content == "hello"

  let events = collect stream count 1 timeout 1500ms
  expect includesWhere { "tag": "NewMessage", "fields": { "content": "hello" } } events
}
```

Queue jobs and SSE events are testable in the same block, deterministically, without timing hacks.

---

## Mutation testing for validation functions

Because `check` and `auth` functions are where critical bugs hide, Tesl has built-in mutation testing for them:

```tesl
fact ValidAge (n: Int)

check checkAge(n: Int) -> n: Int ::: ValidAge n =
  if n >= 18 && n <= 120 then   # mutation sites: >=  &&  <=
    ok n ::: ValidAge n
  else
    fail 422 "age must be 18–120"
```

```
$ tesl --mutate api.tesl

Mutations for checkAge:
  ✓ KILLED   line 4: >= → >   (boundary test caught it)
  ✓ KILLED   line 4: && → ||  (combined-condition test caught it)
  ✓ KILLED   line 4: <= → <   (boundary test caught it)
Mutation score: 100%  — every plausible logic fault is caught
```

A SURVIVED mutant means a real bug at that exact spot would go undetected by your test suite. It's a direct, actionable signal of a test gap — not a coverage percentage.

Mutation testing only targets `check`/`auth`/`establish` functions — the GDP security boundary — because that's where wrong operator choices cause security or correctness bugs.

---

*Next: [A complete Tesl API →](09-full-picture.md)*
