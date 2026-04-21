# 09 — Adding Tests

Tesl has three test layers.  The most important rule is: **write tests in
`.tesl` files first.**  Drop to Racket or OCaml only when the Tesl surface
cannot express what you need. If you need to write tesl that *should* not compile (you should), then use OCaml tests, see compiler/tests/test_review47_antagonistic.ml for inspiration. 

---

## Test layers — when to use each one

| Layer | Files | When to use | How to run |
|---|---|---|---|
| **Tesl test blocks** (primary) | `example/learn/*.tesl`, `tests/*.tesl`, `example/*.tesl` | All user-facing behaviour: proofs, types, ADTs, SQL, queues, SSE, codecs, pattern matching, stdlib | `tesl test <file>` |
| **OCaml compiler tests** | `compiler/test/*.ml` | To write **should not compile** tests. Compiler internals: parser, lexer, emitter, type-system, proof-checker, IR, diagnostics | `cd compiler && dune runtest` |
| **Racket runtime tests** | `tests/*.rkt` | Runtime substrate: `named-value` structs, `define-checker` machinery, `dispatch-with-server` HTTP boundary, PostgreSQL integration | `racket tests/all.rkt` |

### Why Tesl-first?

The `.tesl` surface is what users write.  A test in a `.tesl` file exercises
the full pipeline: parser → checker → proof-checker → linter → emitter →
Racket runtime.  If a `.tesl` test passes, you know the feature works
end-to-end.  If it only passes in Racket or OCaml, you know nothing about
whether a Tesl user can actually use it.

Racket tests exist for cases where you need to test the runtime substrate
directly (e.g. `named-value` struct internals, HTTP dispatch, PostgreSQL
connection pooling).  OCaml tests exist for compiler-internal invariants
(parser edge cases, emitter output shape, diagnostic formatting).

---

## Default stance: write it in Tesl, then run it

When you touch any user-facing surface — parser, type checker, proof system,
emitter, stdlib, SQL layer, queue, SSE — follow this procedure:

1. **Write a `.tesl` test** that exercises the exact behaviour you changed.
2. **Compile it**: `tesl validate <file>` (catches parse, type, proof, lint errors).
3. **Run it**: `tesl test <file>` (actually executes the test and checks `expect` assertions).
4. **Verify the result.** A test that compiles but is never run proves nothing.

> **Compiling is not testing.** `tesl validate` confirms the program is
> well-formed.  `tesl test` confirms it produces the right answers.  Always
> do both.

---

## Writing a Tesl test block

```tesl
test "my feature works" {
  let result = myFunction 42
  expect result == 84
}

test "my feature rejects bad input" {
  expectFail myFunction -1
}

test "property holds" with 100 runs {
  property "always positive" (n: Int where n > 0 && n < 10000) {
    myFunction n > 0
  }
}
```

### Tesl test assertions

| Form | Meaning |
|---|---|
| `expect expr == expr` | Equality check |
| `expect expr != expr` | Inequality check |
| `expect expr` | Truthy check |
| `expectFail expr` | Must raise / fail |
| `expectHasProof fn arg ProofName` | Check that `fn arg` produces a specific proof |
| `property "name" (params) { body }` | Property-based test |

### Running Tesl tests

```bash
# Single file:
tesl test example/learn/lesson05-intro-to-proofs.tesl

# Validate (compile + lint + format check) without running:
tesl validate example/learn/lesson05-intro-to-proofs.tesl

# Full corpus (validate + run + mutation + Racket aggregate):
bash compile-examples.sh
```

---

## Adding a regression test

When fixing a bug:

1. **Create a minimal reproducing `.tesl` snippet** — isolate the bug to the
   smallest possible test case.
2. **Write the test before fixing the bug** — confirm it fails.
3. **Fix the bug.**
4. **Run the test** — confirm it now passes with `tesl test`.
5. **Run the full CI** — confirm nothing else broke:
   ```bash
   bash compiler/ci.sh
   ```

For review-found issues, name the test file `tests/critical-review-NN-tests.tesl`
and prefix test names with `RNN-XX:` (e.g. `R48-13: conjunction passes for
valid values`).

---

## When to use Racket tests

(This should be very uncommon these days).
Drop to Racket (`tests/*.rkt`) when you need to:

- Test the `named-value` / `detached-proof` / `check-ok` struct internals
- Test `dispatch-with-server` HTTP routing directly
- Test PostgreSQL integration with `call-with-temporary-postgres`
- Test runtime proof-checking edge cases that cannot be expressed in Tesl

### Racket test infrastructure

#### `compile-tesl-source`

Compiles a Tesl source string and returns a path to the compiled `.rkt` file:

```racket
(define my-module-path
  (compile-tesl-source
   (string-append
    "#lang tesl\n"
    "module MyTest exposing [myFn]\n"
    "import Tesl.Prelude exposing [Int, String]\n"
    "fn myFn(s: String) -> Int =\n"
    "  String.length(s)\n")))

(define myFn (tesl-module-value my-module-path 'myFn))
(check-equal? (myFn "hello") 5 "myFn basic")
```

#### `compile-tesl-error`

Compiles a Tesl snippet expected to fail.  Returns the error message:

```racket
(let ([err (compile-tesl-error bad-source)])
  (check-true (regexp-match? #rx"expected.*error" err)))
```

#### `dispatch-with-server`

Dispatches a mock HTTP request against a compiled server:

```racket
(define response
  (dispatch-with-server MyServer (list myCapability)
                        'GET '("items" "123")
                        #:cookie "user=alice"))
(check-equal? (dsl-response-status response) 200)
```

#### PostgreSQL integration

```racket
(if (postgres-tooling-available?)
    (call-with-temporary-postgres
      (lambda (config)
        ; Tests here run with a real PostgreSQL connection
        ...))
    (displayln "Skipping PostgreSQL tests"))
```

---

## When to use OCaml compiler tests

Use OCaml tests (`compiler/test/*.ml`) when you need to:

- Verify exact emitter output (e.g. a specific Racket form is emitted)
- Test parser edge cases at the token/AST level
- Test type-checker diagnostics formatting
- Test proof-checker error messages
- Verify IR snapshot output

Run with:

```bash
cd compiler && dune runtest -f
```

---

## CI commands reference

| Command | What it does |
|---|---|
| `tesl validate <file>` | Compile + lint + format-check (no execution) |
| `tesl test <file>` | Compile + run test blocks |
| `bash compiler/ci.sh` | Build OCaml compiler + run all OCaml tests + verify all `.tesl` files compile |
| `bash compile-examples.sh` | Full pipeline: validate + Tesl tests + mutation testing + Racket aggregate suite |
| `racket tests/all.rkt` | Racket aggregate test suite |

---

## Naming conventions

| Prefix | Category |
|---|---|
| `RNN-XX` | Review adversarial tests (e.g. `R48-13`) |
| `STD-NNN` | Standard library function tests |
| `SQL-INJ-NNN` | SQL injection adversarial tests |
| `PG-Q-NNN` | PostgreSQL queue integration tests |
| `Q-NNN` | In-memory queue tests |

---

## What makes a good test

### Test the happy path, the edge, and the error

```tesl
test "happy path" {
  let port = 80
  let v = check isValidPort port
  expect listenOnPort v == "listening on port 80"
}

test "boundary" {
  let port1 = 1
  let v = check isValidPort port1
  let port65535 = 65535
  let w = check isValidPort port65535
  expect 1 == 1
}

test "rejects invalid" {
  expectFail check isValidPort 0
  expectFail check isValidPort 65536
}
```

### For proof system changes: test that invalid code is rejected

If you fix a soundness bug where invalid code was previously accepted,
add a compile-error regression.  The OCaml compiler tests or Racket
`compile-tesl-error` are appropriate here since the program should not
compile at all.

### For every bug fix: add a regression test

The test should have failed before your fix and pass after.  Label it
with the bug description.
