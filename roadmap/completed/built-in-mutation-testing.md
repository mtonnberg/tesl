## Built-in Mutation Testing (`tesl --mutate`)

Tesl's value proposition rests on the soundness of its GDP boundary functions: `check`, `establish`, and `auth`. A type error in these functions is caught at compile time, but a logic error (e.g. `>` instead of `>=`) silently produces an insecure boundary. Built-in mutation testing closes this gap by systematically verifying that the developer's test suite actually exercises and kills every plausible logic fault in these critical functions.

---

### Goal

Single command, zero configuration:

```
tesl --mutate file.tesl
```

Reports which logic faults in `check`/`auth`/`establish` bodies are killed by the existing `test` block, and exits non-zero if any survive.

---

### Design

#### Target scope

Only `check`, `auth`, and `establish` function bodies are mutated. `fn` bodies are excluded because:
- `fn` functions are pure helpers; their correctness is covered by downstream `check`/`auth`/`establish` tests.
- Restricting scope keeps the run fast and the output focused on the security boundary.

#### Mutation operators

| Original | Variants generated |
|----------|-------------------|
| `>`      | `>=`, `<`, `<=`   |
| `<`      | `<=`, `>`, `>=`   |
| `>=`     | `>`, `<=`, `<`    |
| `<=`     | `<`, `>=`, `>`    |
| `==`     | `!=`              |
| `!=`     | `==`              |
| `&&`     | `\|\|`              |
| `\|\|`    | `&&`              |
| `+`      | `-`               |
| `-`      | `+`               |

Each mutant replaces exactly one binary operator in one function body.

#### Execution model

1. Parse and type-check the `.tesl` file (identical to `--check`).
2. Collect all `BinOp` nodes in `check`/`auth`/`establish` bodies, in pre-order traversal, assigned a 0-based index.
3. For each (function, site_index, replacement_op) triple:
   a. Clone the module AST.
   b. Replace the single operator at `site_index` in that function.
   c. Compile the mutant to a temporary `.rkt` file.
   d. Run `raco test --quiet <temp.rkt>`.
   e. Exit code `0` → **SURVIVED** (test gap); exit code `≠ 0` → **KILLED**.
4. Print a per-mutant summary and a final score.

#### Output format

```
checkAge  line 12  >= → >    KILLED
checkAge  line 12  >= → <=   KILLED
checkAge  line 12  >= → <    KILLED
checkPos  line 8   > → >=    SURVIVED  ← test gap

Mutation score: 3/4 (75%)
```

Exit code `0` when score is 100%; exit code `1` when any mutant survives or no tests exist.

#### NO TESTS result

If the `.tesl` file has no `test` block, every mutant reports `NO TESTS` and exit code is `1`. This is intentional: an untested boundary is a failing boundary.

---

### Implementation

#### Files

| File | Role |
|------|------|
| `compiler/lib/mutate.ml` | AST mutation engine: site collection, operator replacement, mutant generation, result types |
| `compiler/lib/compile.ml` | `mutate_file` function: orchestrates parse → typecheck → mutant loop → raco execution |
| `compiler/bin/main.ml` | `--mutate` CLI handler: colored output, summary, exit code |
| `compiler/test/test_mutation.ml` | 8 integration tests covering all result variants |

#### Key implementation notes

**Index-based replacement — avoid OCaml evaluation order trap**

`collect_sites` assigns indices using sequential `walk left; walk right` (guaranteed left-to-right in OCaml). `replace_binop_at` must use explicit `let` bindings when constructing record values:

```ocaml
(* CORRECT — let bindings guarantee left-to-right *)
let left' = walk left in
let right' = walk right in
{ op; left = left'; right = right'; loc }

(* WRONG — OCaml record field initializers are evaluated right-to-left *)
{ op; left = walk left; right = walk right; loc }
```

The mismatch would cause site indices to be off-by-reverse, making mutations hit the wrong operators (often a no-op).

**Temporary file cleanup**

`Fun.protect` ensures the temp `.rkt` file is deleted even if `raco test` throws or returns an error.

**Raco invocation**

```
raco test --quiet <temp.rkt> 2>/dev/null
```

`2>/dev/null` suppresses raco's own stdout/stderr; only the exit code is used.

---

### Limitations

- Requires `raco` (Racket) to be installed; skips gracefully if not available.
- One `raco test` invocation per mutant. For modules with many operators this can be slow (O(n) where n = number of binary operators in check/auth/establish bodies).
- Does not mutate string, integer, or boolean literals (only binary operators).
- Does not cover `fn` bodies; a future flag `--mutate-all` could extend scope.

---

### Testing

The test suite (`test_mutation.ml`) covers:

| Test | Scenario |
|------|----------|
| `all mutants killed` | Strong test suite kills all 3 variants of `>` |
| `off-by-one survives` | Weak test (no boundary input) lets `> → >=` survive |
| `no-test block` | Every mutant reports NO TESTS |
| `compound condition` | `&&` and `>=`/`<=` mutations all killed with full coverage |
| `fn not mutated` | `fn helper` body not mutated, only `check` body is |
| `no mutable operators` | Module with no binary ops in check body: 0 mutants, exit 0 |
| `parse error` | Invalid `.tesl` input: clean error message, exit 1 |
| `raco availability` | Graceful skip when raco is not installed |
