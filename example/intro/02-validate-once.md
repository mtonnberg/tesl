# Validate Once, Trust Everywhere

Tesl's core idea: when you validate data, it gets a **proof stamp** attached to it. That stamp travels with the value through your entire call graph. Functions that need validated data declare it in their signature — and the compiler enforces it.

---

## Step 1: define the rule once

```tesl
fact ValidTitle (title: String)   # declare the proof predicate — a named guarantee

check isSafeTitle(title: String) -> title: String ::: ValidTitle title =
  if 3 <= String.length title && String.length title <= 120 then
    ok title ::: ValidTitle title   # stamp: this String now carries ValidTitle proof
  else
    fail 400 "Title must be 3–120 characters"
```

`check` is like a function that either succeeds — returning the value **with a proof stamp** — or fails with an HTTP error. The `:::` is the stamp operator.

---

## Step 2: require the proof in consumers

```tesl
# This function requires the stamp — a plain String won't compile
fn saveTitleToDb(title: String ::: ValidTitle title) -> ...

# Call it with a stamped value: works
let validated = check isSafeTitle rawTitle
saveTitleToDb validated          # ✓ proof is there

# Call it with a plain String: compile error
saveTitleToDb "some raw string"  # ✗ "missing proof: ValidTitle"
```

Forgetting to validate is a **compile error**, not a runtime incident.

---

## Step 3: wire validation into the HTTP boundary

```tesl
record NewTodo {
  title: String ::: ValidTitle title   # the field carries the proof
}

codec NewTodo {
  fromJson [
    { title <- "title" with_codec stringCodec via isSafeTitle }
    #                                             ^^^^^^^^^^^ runs at decode time
  ]
}
```

When Tesl decodes a request body:
- `isSafeTitle` runs automatically
- Fails → **400 before your handler ever runs**
- Passes → `title` carries `ValidTitle` everywhere inside the handler

---

## Inside the handler: nothing to re-check

```tesl
handler createTodo(
  user:    User    ::: Authenticated user,   # from auth — already proven
  newTodo: NewTodo                            # codec ran isSafeTitle — already proven
) -> Todo
  requires [dbWrite] =
  insert Todo {
    title:   newTodo.title,   # ValidTitle proof is already here — use it directly
    ownerId: user.id,
    ...
  }
```

No defensive guards. No `if (isValid(x))`. No "trust me, the caller checked it." The compiler already knows.

---

## The difference

| | Traditional | Tesl |
|---|---|---|
| Validation runs | Once (hopefully) | Once, guaranteed at the boundary |
| Proof it ran | None (convention) | Type-level stamp |
| Forgetting it | Runtime bug | Compile error |
| Re-checking downstream | Common pattern | Never needed |
| Refactoring breaks it | Silently | Compile error |

---

*Next: [Proofs that span two values →](02b-cross-value-proofs.md)*
