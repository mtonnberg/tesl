# Typed SQL — No ORM Magic, No Raw Strings

Tesl doesn't generate SQL from object graphs (ORM-style) and doesn't ask you to write raw SQL strings. You write SQL-shaped queries using your entity's field names, and the compiler checks every reference at compile time.

---

## One declaration, everything derived from it

```tesl
entity Todo table "todos" primaryKey id {
  id:        String
  title:     String
  ownerId:   String        @db(text)
  status:    Status        # ADT — stored as JSONB automatically
  createdAt: PosixMillis   # stored as BIGINT, no annotation needed
}
```

This is the single source of truth: table name, column names, types, storage mapping. Misspell a field anywhere that references `Todo` → compile error, not a 3am production crash.

---

## Queries that compile

```tesl
# select — returns List Todo, proof-annotated with the query predicate
let mine = select todo from Todo where todo.ownerId == user.id

# selectOne — returns Maybe Todo (Nothing case must be handled)
let found = selectOne todo from Todo where todo.id == todoId

# insert — returns proof that the row now exists in the database
insert Todo { id: todoId, title: newTodo.title, ownerId: user.id,
              status: Open, createdAt: nowMillis() }

# update
update todo in Todo
  where todo.id == todoId
  set   todo.status = Done
  returning one
```

Misspell `ownerId` as `ownerID`? Compile error. Reference a field you removed from the entity? Compile error across every query that touched it.

---

## SQL injection: structurally impossible

User data never appears as literal SQL text. Tesl always generates parameterized queries:

```sql
-- What Tesl generates for: where todo.ownerId == user.id
SELECT * FROM todos WHERE owner_id = $1
```

There is no query builder, no string concatenation, no escape function to forget. The structural model makes injection impossible rather than merely discouraged.

---

## Transactions

```tesl
with transaction {
  let _ = insert User { id: userId, name: name }
  insert Profile { userId: userId, bio: "" }
}
```

Any exception inside rolls back everything. And **a transaction inside another transaction is a compile error** — no silent nesting, no "did this really commit?"

Enqueuing a job inside a transaction is valid: if the DB write fails, the job is never enqueued. If everything succeeds, both commit atomically.

---

## The FromDb proof

Every `select` and `insert` automatically attaches a proof that the data came from the database:

```tesl
handler getTodo(todoId: String ::: TodoId todoId) -> Todo ? FromDb (Id == todoId)
  requires [dbRead] =
  let found = selectOne todo from Todo where todo.id == todoId
  case found of
    Nothing    -> fail 404 "not found"
    Something t -> t   # t carries FromDb (Id == todoId) — return type satisfied
```

A function that accepts `Todo ::: FromDb` cannot receive a hand-crafted struct — the proof is unforgeable except through the SQL layer. No one can accidentally bypass the database and pass raw data in.

---

## ADTs stored as JSONB — no ceremony

```tesl
type JobResult
  = Delivered messageId: String
  | Failed    reason:    String
  | Pending

entity Task table "tasks" primaryKey id {
  id:     String
  result: JobResult   # stored as {"tag":"Delivered","fields":{"messageId":"msg-1"}}
}
```

Variants with data round-trip correctly. The same JSON encoding used for HTTP responses is used for database storage — one format across the stack, no mismatch.

---

*Next: [ForAll proofs — lists that remember their origin →](05b-forall-proofs.md)*
