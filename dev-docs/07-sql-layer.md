# 07 — SQL Layer: Entities, Parameterized Queries, Newtype Coercion

The SQL layer lives in `dsl/sql.rkt`. It bridges Tesl's GDP proof system with
PostgreSQL (and provides an in-memory fallback for tests).

---

## Entity macro: `define-entity`

When the compiler encounters an `entity` declaration:

```tesl
entity Note table "notes" primaryKey id {
  id:        NoteId @db(text)
  title:     String @db(text)
  createdAt: PosixMillis
}
```

It emits:

```racket
(define-entity Note
  #:table "notes"
  #:primary-key id
  [Id        id        : NoteId     #:db-type text]
  [Title     title     : String     #:db-type text]
  [CreatedAt createdAt : PosixMillis])    ; no #:db-type — auto-mapped
```

The `define-entity` macro (in `sql.rkt`) creates:

- `Note-id-field`, `Note-title-field`, `Note-createdAt-field` — `field-spec` structs
- `Note-id`, `Note-title`, etc. — accessor functions returning the field-spec
- `Note?` — a predicate that checks if a hash has all required fields
- Registers `Note` as a runtime type

### `field-spec` struct

```racket
(struct field-spec
  (entity      ; symbol: 'Note
   proof-name  ; symbol: 'Id, 'Title, etc. (for GDP proofs)
   key         ; symbol: 'id, 'title, etc.
   type        ; type-datum: type-ref or symbol (for Maybe fields, this is the inner type)
   primary-key?; bool
   column      ; symbol or #f (defaults to snake_case of key)
   db-type     ; symbol or #f (from @db annotation)
   nullable?)  ; bool — true when the Tesl field type is (Maybe T)
  #:transparent)
```

`nullable?` is `#t` when the entity field is declared as `Maybe T` in Tesl. For these fields:
- The SQL column is created as `<inner-type> NULL` instead of `NOT NULL`.
- On read, SQL `NULL` → `(Nothing)` runtime value; non-NULL → `(Something v)`.
- On write, `Nothing` → SQL `NULL`; `Something v` → the inner value.
- The `type` field stores the *inner* type (e.g., `'String` for `Maybe String`).

### DB type annotation resolution

`field-db-type-annotation` determines the PostgreSQL column type for a field:

```racket
(define (field-db-type-annotation field)
  (or (field-spec-db-type field)           ; explicit @db(bigint) → 'bigint
      (default-field-db-type-annotation field)
      (error "needs explicit #:db-type")))

(define (default-field-db-type-annotation field)
  (define type-datum (field-spec-type field))
  (or (hash-ref built-in-db-type-registry type-datum #f)   ; String → text
      ; Newtype lookup: PosixMillis → Integer → bigint
      (let ([base (hash-ref newtype-registry type-datum #f)])
        (and base (hash-ref built-in-db-type-registry base #f)))
      (and (field-adt-type? field) 'jsonb)   ; ADT fields → jsonb
      #f))
```

The newtype lookup path handles `PosixMillis` (and any user-defined newtype
wrapping a built-in type) without requiring an explicit `@db` annotation.
For `nullable?` fields (`Maybe T`), the annotation is computed from the inner
type `T` and the column is emitted as `<type> NULL` in `CREATE TABLE`.

---

## Parameterized SQL queries

All user-supplied values go through `$1`, `$2`, … placeholders. The key is
`compile-predicate-sql`:

```racket
(define (compile-predicate-sql predicate index)
  ; Returns: (sql-fragment, list-of-params, next-index)
  (match predicate
    [(eq-predicate field operand)
     (values (format "\"~a\" = $~a"
                     (field-column-name field)
                     index)
             (list (field-runtime-value->db-value field operand-value))
             (add1 index))]
    [(comparison-predicate field operator operand)
     ...]
    [(or-predicate left right)
     ...]))
```

`compile-where-sql` accumulates multiple predicates:

```racket
(define (compile-where-sql predicates [start-index 1])
  ; Returns: (" WHERE col = $1 AND col2 = $2", params, next-index)
```

Then the actual query execution:

```racket
(apply query-rows conn sql params)
;; e.g. (query-rows conn "SELECT id, title FROM notes WHERE id = $1" "note-123")
```

The `db` library (Racket's database driver) handles parameter binding,
preventing SQL injection structurally.

---

## Reading from the database: `field-db-value->runtime-value`

When a row is read from PostgreSQL, each column's value is processed:

```racket
(define (field-db-value->runtime-value field value)
  (cond
    ; ADT field (stored as jsonb) → deserialize to adt-value
    [(field-adt-type? field)
     (jsexpr->typed-value (field-spec-type field) ...)]
    ; Newtype field (e.g. PosixMillis) → wrap in newtype
    [(hash-ref newtype-registry (field-spec-type field) #f)
     (jsexpr->typed-value (field-spec-type field) value 'sql)]
    ; Plain value → return as-is
    [else value]))
```

The `jsexpr->typed-value` for a newtype calls `(PosixMillis value)` or
`(UserId value)` to wrap the raw DB value.

---

## Writing to the database: `field-runtime-value->db-value`

The reverse: unwrap any Tesl value to a plain DB-compatible value:

```racket
(define (field-runtime-value->db-value field value [who 'sql])
  (cond
    ; ADT → serialize to JSON string
    [(field-adt-type? field)
     (bytes->string/utf-8 (jsexpr->bytes (runtime-value->jsexpr value)))]
    ; Newtype → unwrap to raw value
    [(newtype-value? value)
     (newtype-value-value value)]    ; PosixMillis(123) → 123
    [else value]))
```

---

## FromDb proofs

After a `select` or `insert`, the SQL layer automatically attaches GDP proofs:

```racket
(define (attach-query-proofs entity row predicates)
  (define entity-subject (gensym (entity-spec-name entity)))
  ; For each WHERE predicate (field == operand):
  ;   Creates fact: (FromDb (Id == operand-subject) entity-subject)
  ;   where operand-subject is the gensym of the WHERE value
  (attach-row entity row facts bindings entity-subject))
```

So `selectOne note from Note where note.id == noteId` produces a `Note`
named-value with subject `note-gensym` and fact:
`(FromDb (Id == noteId-gensym) note-gensym)`

This is the proof that the caller's `note` return type `Note ? FromDb (Id == noteId)`
checks at function return time.

---

## Auto-migration on startup

`ensure-database-ready!` runs when a `with database` block first activates:

1. `(create schema if not exists schema-name)` — creates the schema
2. For each entity: `postgres-ensure-entity!`
   - If table doesn't exist → `CREATE TABLE IF NOT EXISTS`
   - If table exists → compare columns, add missing NOT NULL columns if table is empty, verify types match
3. `ensure-queue-tables!` — creates `tesl_jobs` and `tesl_pubsub_outbox`

---

## Transaction support

`(call-with-queue-transaction thunk)` in `queue.rkt` wraps a database
transaction. Inside a `with transaction { }` block:
1. `call-with-transaction conn thunk` opens a real PostgreSQL transaction
2. Queue `enqueue!` and pub-sub `publish-event!` calls defer their `pg_notify`
   to commit time using a `deferred` box
3. On commit, NOTIFY fires, waking LISTEN threads in other processes

---

## In-memory fallback

When `current-database-runtime` is `#f` (no database context), the SQL
operations fall back to in-memory hash tables. Entity operations use
`entity-spec-source` — a mutable hash provided at entity definition time
(or `#f` for production entities that require a real DB).

Tests can provide an in-memory source:

```racket
(define-entity TestNote
  #:source (lambda () (make-hash))  ; fresh hash each time
  #:primary-key id
  [Id id : String]
  [Title title : String])
```
