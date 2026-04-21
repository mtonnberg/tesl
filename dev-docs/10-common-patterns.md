# 10 — Common Patterns, Gotchas, and Quick Reference

A collection of things that bite language contributors. Read this before
spending hours debugging a confusing error.

---

## Compiler gotchas

### ADT must be multi-line

```tesl
# WRONG — parsed as type alias "Color = Red | Green | Blue"
type Color = Red | Green | Blue

# RIGHT — parsed as ADT with three constructors
type Color
  = Red
  | Green
  | Blue
```

The parser checks whether `=` is on the same line as `type`. Same-line `=`
triggers the type-alias branch.

### Function bodies must be indented on the next line

```tesl
# WRONG
fn double(n: Int) -> Int = *n * 2

# RIGHT
fn double(n: Int) -> Int =
  *n * 2
```

### `if/then/else` must be multi-line

```tesl
# WRONG — "empty expression" or "missing if/then/else" error
if n > 0 then "pos" else "neg"

# RIGHT
if n > 0 then
  "pos"
else
  "neg"
```

### `exposing [...]` must be on one line

Multi-line export/import lists don't parse:

```tesl
# WRONG
module Foo exposing [
  bar, baz
]

# RIGHT
module Foo exposing [bar, baz]
```

### Proof-returning functions cannot be used inline in arithmetic

```tesl
# WRONG — String.trim returns a named-value, raw-value not applied to call results
if String.trim(s) == "" then ...

# RIGHT
let t = String.trim(s)
if String.isEmpty(t) then ...
```

The compiler's `raw_default=True` mechanism applies `raw-value` to variable
*references* (e.g. `*name`) but not to function call *results*. Assigning to
a `let` binding first is always safe.

### Record with record-level proof requires a ghost witness

```tesl
record Pair {
  a: Int ::: Pos a
  b: Int ::: Pos b
} ::: Gt a b

# WRONG — compile error: "constructing `Pair` requires a ghost witness"
fn makeIt(a: Int ::: Pos a, b: Int ::: Pos b, proof: Fact (Gt a b)) -> Pair =
  { a: a, b: b }

# RIGHT — ghost witness via `{ ... } ::: witnessVar`
fn makeIt(a: Int ::: Pos a, b: Int ::: Pos b, proof: Fact (Gt a b)) -> Pair =
  { a: a, b: b } ::: proof
```

The `:::` on a record literal is **zero-cost** — it compiles to the plain record
constructor with no `attach-proof` call. Its only purpose is to satisfy the
compiler's requirement that the caller holds a proof of the cross-field invariant.

For HTTP input, the cross-field check goes in the codec block with `} via checker`,
not on the record declaration itself.

### `case` fall-through: multiple constructors sharing one body

An arm with no body is a **fall-through** arm — it shares the body of the next non-empty arm. This is the idiomatic way to handle multiple constructors identically:

```tesl
case status of
  Done       -> handleDone()
  Backlog    ->
  Todo       ->
  InProgress -> handleOther()   # Backlog, Todo, and InProgress all execute this body
```

**Rules:**
- Every field must be explicitly bound or wildcarded: `Circle _ ->`, `AlternativeA _ s ->`. Omitting binders is an arity error.
- Fall-through arms may have named binders (`AlternativeA _ s ->`) — they are **documentation only** and ignored at runtime. Only the body arm's binders are accessed.
- Safety check (field label): every field label the body arm binds must also exist in every pending fall-through constructor.
- Safety check (field type): if the label exists, its type must also match exactly. `StrVal s:String -> IntVal s:Int -> *s` is rejected because `s` has different types.
- The last arm in the entire `case` must have a body — a trailing empty arm is an error.

```tesl
type Bepa
  = AlternativeA x:Int s:String
  | AlternativeB s:String
  | AlternativeC t:Int

# VALID — all pending constructors (AlternativeA) have field 's'
fn f(b: Bepa) -> String =
  case b of
    AlternativeA _ s ->    # fall-through; binder 's' is just documentation
    AlternativeB s ->      # body: 's' exists in both AlternativeA and AlternativeB
      *s
    AlternativeC _ ->
      "no-string"

# ERROR — AlternativeC has 't' but not 's'; body binds 's'
fn g(b: Bepa) -> String =
  case b of
    AlternativeC _ ->
    AlternativeB s ->      ← compile error: AlternativeC lacks field 's'
      *s

# ERROR — trailing empty arm
case status of
  Done ->
  Cancelled ->             ← no body follows: compile error
```

### ADT fields in codecs require an `adtJson` codec, not `stringCodec`

Using a builtin codec (`stringCodec`, `intCodec`, etc.) on an ADT-typed field is caught as a compile error since `validate_codec_field_types` was added:

```tesl
type Priority = Low | Medium | High

# WRONG — compile error: field `priority` is declared as `Priority`
#          but `with_codec stringCodec` produces `String`
codec NewTask {
  toJson_forbidden
  fromJson [
    { priority <- "priority" with_codec stringCodec }
  ]
}

# RIGHT — declare adtJson codec first, then reference it
codec Priority {
  adtJson
}

codec NewTask {
  toJson_forbidden
  fromJson [
    { priority <- "priority" with_codec Priority }
  ]
}
```

### `-> String ? IsTrimmed` not `-> String ::: IsTrimmed result`

```tesl
# WRONG — `result` is unbound in this position
fn f(s: String) -> String ::: IsTrimmed result =
  String.trim(s)

# RIGHT — entity-append rule fills in the subject automatically
fn f(s: String) -> String ? IsTrimmed =
  String.trim(s)
```

---

## Racket runtime gotchas

### `raw-value` does NOT unwrap newtypes

```racket
(raw-value (PosixMillis 42))    ; → (newtype-value 'PosixMillis 42) — NOT 42!
(newtype-value-value (PosixMillis 42))  ; → 42  ✓
```

`raw-value` unwraps `named-value`, `check-ok`, and symbol lookups — but not
`newtype-value`. Always use `newtype-value-value` to extract the inner value
from a newtype.

### `type-ref` structs vs plain symbols in registries

`define-newtype` registers the type in `newtype-registry` using a `type-ref`
struct key (not a plain symbol):

```racket
; The key is #s(type-ref "/path/to/time.rkt" PosixMillis)
; NOT the plain symbol 'PosixMillis
(hash-ref newtype-registry 'PosixMillis #f)      ; → #f
(hash-ref newtype-registry (newtype-value-type-name (PosixMillis 0)) #f) ; → Integer ✓
```

This matters when writing SQL field type lookups or any code that needs to
check type properties by name. Always use `newtype-value-type-name` to get
the key, not a plain symbol.

### `field-spec-type` is a `type-ref`, not a plain symbol

After `define-entity` processes a field with type `PosixMillis`, the
`field-spec-type` is a `type-ref` struct. Code that looks up the type in
any registry must account for this.

The `default-field-db-type-annotation` function in `sql.rkt` handles this
by checking `newtype-registry` as a fallback:

```racket
; First try direct lookup (works for String, Integer, Boolean):
(hash-ref built-in-db-type-registry type-datum #f)
; Then try newtype base type lookup (works for PosixMillis, UserId, etc.):
(let ([base (hash-ref newtype-registry type-datum #f)])
  (and base (hash-ref built-in-db-type-registry base #f)))
```

### `split_top_level` must track all three bracket types

`split_top_level(text, sep)` and related functions track `()`, `{}`, AND `[]`
depth. Before the `depth_bracket` fix (2026-03-16), only `()` and `{}` were
tracked, causing nested list literals `[["a","b"],["c","d"]]` to split at inner
commas. If you add a new string-splitting utility, make sure it tracks all three.

---

## Module system gotchas

### Special module metadata uses plain symbol exports

`make_special_module_metadata` takes a `set[str]` of export names as plain
Python strings (e.g. `{"String.length", "String.trim"}`). These are used
for the Python-level reference validation only.

The Racket runtime names are set by the `[String.length thsl_import_String_length]`
renaming in the generated `(only-in ...)` require form.

### Proof predicates must be in `exported_names` to be importable

If an `establish` function in module A declares predicate `IsValid`, other modules
can only import it if:
1. Module A lists `IsValid` in its `exposing [...]`
2. The importing module lists `IsValid` in its `import A exposing [IsValid]`

If you forget either step: `missing IsValid in module B`.

### Module-only imports do NOT expose proof predicates

A bare `import Tesl.String` (no `exposing` clause) gives access to `String.length`,
`String.trim`, etc. via qualification, but does NOT bring `IsTrimmed`, `IsNonEmpty`,
or any other stdlib predicate into scope for `:::` annotations:

```tesl
# WRONG — IsTrimmed not in scope
import Tesl.String
fn f(s: String ::: IsTrimmed s) -> String = s   # compile error

# RIGHT
import Tesl.String exposing [String.trim, IsTrimmed]
fn f(s: String ::: IsTrimmed s) -> String = s
```

The same rule applies to user modules: `import MyModule` alone does not
expose `MyModule`'s predicates. Always list predicates in `exposing [...]`.

### Bare `check` statements are compile errors

A `check` call used as a bare statement (not bound to `let`) is rejected:

```tesl
fn demo(raw: Int) -> Int =
  check isPositive raw   # ERROR — proof silently discarded, 42 always runs
  42
```

Use `let` to bind the result:

```tesl
fn demo(raw: Int) -> Int =
  let _ = check isPositive raw   # ERROR — _ binder loses the subject
  42                              # still wrong: proof is orphaned

fn demo(raw: Int) -> Int =
  let checked = check isPositive raw   # CORRECT — proof bound to 'checked'
  42
```

### `fn` cannot mint new proofs in its return type

A `fn` may only declare a proof-carrying return spec (`name: T ::: P`) if
`name` was received with that proof on input (passthrough). Fabricating a
new proof inside the fn body and claiming it in the return type is rejected:

```tesl
# WRONG — n has no proof on input
fn forge(n: Int) -> n: Int ::: IsPositive n =
  let pf = proveAny n    # proveAny is an establish
  n ::: pf               # compile error at the return type declaration

# RIGHT — passthrough
fn pass(n: Int ::: IsPositive n) -> n: Int ::: IsPositive n = n

# RIGHT — use check or establish as the proof-minting boundary
check checkPositive(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then ok n ::: IsPositive n else fail 400 "neg"
```

### Optional proof-carrying values: `Maybe (v: T ::: P v)`

When a function may or may not produce a proof-carrying value, use the
named-binding form inside `Maybe`. Pattern-matching `Something v` automatically
gives `v` the declared proof:

```tesl
fn maybePos(n: Int) -> Maybe (v: Int ::: IsPositive v) =
  if n > 0 then
    let p = check checkPositive n
    Something p
  else
    Nothing

fn use(n: Int) -> Int =
  let m = maybePos n
  case m of
    Nothing -> 0
    Something v -> needPos v   # v carries IsPositive v
```

The older `Maybe (Fact (P x))` form still works for detached-proof transport,
but `Maybe (v: T ::: P v)` is the idiomatic form when the value is produced
at the proof boundary.

### Circular imports work — but both modules must be correct independently

When modules A and B import each other, they form an SCC and are compiled to
a single `.rkt` file. Both modules' forms are emitted into that file, with
name mangling to avoid collisions. If either module has an error, both fail.

---

## Testing gotchas

### Inline Tesl strings need explicit `\n`

Every line in a `compile-thsl-source` string must end with `\n`:

```racket
; WRONG — no newlines between lines
"fn double(n: Int) -> Int = n + n"

; RIGHT
"fn double(n: Int) -> Int =\n  n + n\n"
```

### `require` inside `let` is not allowed

```racket
; WRONG
(let ([x (begin
           (require (only-in "../tesl/time.rkt" PosixMillis))
           (PosixMillis 42))])
  ...)

; RIGHT — require at top level
(require (only-in "../tesl/time.rkt" PosixMillis))
(let ([x (PosixMillis 42)]) ...)
```

### Background threads from PG tests outlive the test

Tests that call `start-workers!` or `start-pubsub-listen!` spawn background
threads. When the PostgreSQL server shuts down after the test, these threads
attempt reconnection and may print error messages. This is expected behaviour
— the threads are not cleaned up by the test infrastructure.

If you see `#%app: missing procedure expression` errors in the test output
after PG tests, they are usually from these background threads and can be
ignored if all test assertions passed.

---

## Quick reference: what emits what

| Tesl form | Racket macro |
|---|---|
| `fn f(x: T) -> R =` | `(define/pow (f [x : T]) #:returns R ...)` |
| `check f(x: T) -> r: T ::: P r =` | `(define-checker (f [x : T]) #:returns [r : T ::: P] ...)` |
| `establish f(x: T) -> Fact (P x) =` | `(define-trusted (f [x : T]) #:returns (Fact (P x)) ...)` |
| `auth f(req: H) -> u: U ::: A u =` | `(define-auther (f [req : H]) #:returns [u : U ::: A] ...)` |
| `handler f(x: T) -> R requires [...] =` | `(define-handler (f [x : T]) #:capabilities [...] #:returns R ...)` |
| `worker f(j: J ::: FromQueue ...) =` | `(define/pow (f [j : J ::: ...]) ...)` |
| `type Foo = Bar` | `(define-newtype Foo Bar)` |
| `type Foo = V1 \| V2` (multi-line) | `(define-adt (Foo) [V1] [V2])` |
| `record R { f: T }` | `(define-record R [f : T])` |
| `entity E table "t" primaryKey id { ... }` | `(define-entity E #:table "t" #:primary-key id ...)` |
| `database D { ... }` | `(define-database D ...)` |
| `api A { get "/path" ... }` | `(define-api A ...)` |
| `server S for A { ... }` | `(define-server S ...)` |
| `let x = check f(n)` | `(let/check ([tmp (f n)]) (let ([x (attach-proof ...)]) ...))` |
| `{ a: a, b: b } ::: proof` | `(R #:a *a #:b *b)` — ghost witness, zero-cost |
| `let (x ::: p) = y` | proof decomposition with `detach-all-proof` |
| `ok v ::: P v` | `(accept (P v))` |
| `fail 400 "msg"` | `(reject "msg" #:http-code 400)` |
| `[1, 2, 3]` | `(list 1 2 3)` |
| `[]` | `(list)` |
| `*x` | `(raw-value x)` or `star-x` in `define/pow` |
| `String.trim(s)` | `(thsl_import_String_trim s)` |

---

## Useful diagnostic commands

```bash
# See what a .tesl file compiles to:
dune exec --root compiler -- bin/main.exe example/todo-api.tesl

# Check a file for errors only:
dune exec --root compiler -- bin/main.exe --check my-file.tesl

# Lint a file:
dune exec --root compiler -- bin/main.exe --lint my-file.tesl

# Print the import graph:
dune exec --root compiler -- bin/main.exe --deps example/todo-api.tesl

# Run a single test file:
nix-shell --run "raco test tests/sql-test.rkt 2>&1"

# Load and inspect a compiled module:
racket -e '
(define mod (dynamic-require (file "example/todo-api.rkt") #f))
(displayln "loaded OK")
'
```

---

## Proof validation gotchas

### Proof-total stdlib functions require prior proof acquisition

Several stdlib functions are proof-total — they require a proof on an argument
and are compile-time errors without it. Always acquire the proof first with the
corresponding check function:

```tesl
# WRONG — Int.divide requires IsNonZero on the divisor
fn unsafeDivide(a: Int, b: Int) -> Int = Int.divide(a, b)  # compile error

# RIGHT
fn safeDivide(a: Int, b: Int) -> Int =
  let divisor = check Int.nonZero(b)    # fails if b == 0, proof on success
  Int.divide(a, divisor)
```

Full list of proof-total stdlib functions:

| Function | Required proof | Check function |
|---|---|---|
| `Int.divide(a, b)` | `b ::: IsNonZero b` | `Int.nonZero(b)` |
| `Float.div(a, b)` | `b ::: FloatNonZero b` | `Float.requireNonZero(b)` |
| `List.take(n, xs)` | `n ::: IsNonNegative n` | `Int.nonNegative(n)` |
| `List.drop(n, xs)` | `n ::: IsNonNegative n` | `Int.nonNegative(n)` |
| `List.repeat(x, n)` | `n ::: IsNonNegative n` | `Int.nonNegative(n)` |
| `Dict.get(key, dict)` | `dict ::: HasKey key dict` | `Dict.requireKey(key, dict)` |

### `establish` bodies use direct proof constructors, not `ok`

`establish` functions return `Fact (P args)` by returning the proof constructor
directly. Using `ok` inside `establish` is a compile-time error:

```tesl
# WRONG — ok is not valid in establish
establish bad(n: Int) -> Fact (IsPositive n) =
  ok <| IsPositive n   # compile error: use direct return

# RIGHT
establish good(n: Int) -> Fact (IsPositive n) =
  IsPositive n
```

### `check` functions: `ok` must return the binding name

The expression after `ok` in a `check` function must be the declared binding
name, and the proof must match exactly:

```tesl
# WRONG — ok returns a literal, not the binding 'n'
check bad(n: Int) -> n: Int ::: Positive n =
  ok 0 ::: Positive n   # compile error

# WRONG — proof args in wrong order
check bad2(lo: Int, hi: Int) -> lo: Int ::: InRange lo hi =
  ok lo ::: InRange hi lo  # compile error: proof does not match

# RIGHT
check good(n: Int) -> n: Int ::: Positive n =
  if n > 0 then ok n ::: Positive n
  else fail 400 "not positive"
```

### Case `where` guards are emitted, not dropped

A `where` clause after a case pattern is compiled into the cond condition —
it does NOT run the arm body before checking:

```tesl
case existing of
  Something todo where todo.ownerId != user.id ->
    fail 403 "forbidden"     # only fires if ownerId != user.id
  Something todo ->
    todo                     # fires for all other Something cases
```

Both arms can bind `todo`. The guard in the first arm can reference bound
variables from the pattern.

### Test block let bindings are proof-checked

A `let` binding with a type annotation in a test block is validated at compile
time — the declared proof predicates must actually be returned by the function:

```tesl
test "correct" {
  let x: Int ::: IsPositive x = checkIsPositive 5  # OK
}

test "wrong proof — compile error" {
  let x: Int ::: IsPositive x && IsSmall x = makePositiveOnly 5
  # compile error: makePositiveOnly doesn't return IsSmall
}
```
