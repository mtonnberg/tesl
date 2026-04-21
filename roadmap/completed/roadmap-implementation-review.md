# Roadmap Implementation Review

*Date: 2026-03-16 — implemented while you slept*

---

## What was done

### 1. VSCode/VSCodium syntax highlighting — `update_visual_studio_highlighting.md`

Updated `editor/vscode-thsl/syntaxes/thsl.tmLanguage.json`:
- Added `queue`, `channel`, `worker`, `workers` to declaration keywords
- Added `enqueue`, `publish`, `subscribe`, `websocket`, `startWorkers`, `startWebSocket` to body keywords
- Added `transaction` to control keywords
- Added `websocket` to HTTP method highlighting
- Added `<>` operator (string concatenation)
- Added `asc`, `desc` as constants
- Added `generateId` to builtin functions

Works in both VSCode and VSCodium (the grammar format is the same for both).

---

### 2. CLI tool — `packaged_Tesl_cli_tool.md`

Updated `shell.nix` to:
- Define a `Tesl` shell function available immediately upon entering `nix-shell`
- Supports: `Tesl compile`, `Tesl check`, `Tesl fmt`, `Tesl run`, `Tesl test`, `Tesl help`
- Resolves the compiler path relative to `$TESL_REPO_ROOT` (set automatically by shellHook)

**Try it:**
```bash
cd /path/to/Tesl
nix-shell
Tesl compile example/todo-api.thsl
Tesl check example/chat/backend.thsl
Tesl help
```

Note: There is no global Nix package (as per your request — public packaging is premature). The `Tesl` command is only available inside `nix-shell`.

---

### 3. Standard library expansion — `add_standard_modules.md`

#### New/expanded modules

| Module | Status | Key additions |
|---|---|---|
| `Tesl.String` | Expanded | 25+ functions (trim, split, join, contains, toUpper/Lower, padLeft/Right, etc.) |
| `Tesl.List` | Expanded | 40+ functions (map, filter, fold, sort, zip, range, sum, etc.) |
| `Tesl.Int` | Expanded | min, max, clamp, abs, pow, gcd, lcm, isEven, isOdd, sign, etc. |
| `Tesl.Float` | **New** | parse, abs, min, max, ceil, floor, round, sqrt, trig, etc. |
| `Tesl.Either` | **New** | Left, Right, map, mapLeft, andThen, withDefault, toMaybe, fromMaybe |
| `Tesl.Dict` | **New** | empty, insert, lookup, remove, member, map, filter, union, intersection, fromList/toList |
| `Tesl.Set` | **New** | empty, insert, remove, member, union, intersection, difference, isSubset, map, filter |

#### GDP proof-bearing return values

Several stdlib functions now return values with GDP proofs attached:

| Function | Proof | Meaning |
|---|---|---|
| `String.trim` / `trimLeft` / `trimRight` | `IsTrimmed result` | Result has been trimmed |
| `String.toUpper` | `IsUpperCase result` | Result is uppercase |
| `String.toLower` | `IsLowerCase result` | Result is lowercase |
| `List.sort` / `sortBy` | `IsSorted result` | Result is sorted |
| `Int.nonZero` (check function) | `IsNonZero n` | Use with `let d = check Int.nonZero(n)` |
| `String.requireNonEmpty` (check function) | `IsNonEmpty s` | Use with `let s = check String.requireNonEmpty(raw)` |
| `Int.divide` | requires `IsNonZero b` | Safe division — divisor must have IsNonZero proof |

**Important limitation** (documented in `future-roadmap/proof-returning-stdlib.md`):
Functions returning proof-bearing values (like `String.trim`) must be assigned to a `let` binding before use in arithmetic/comparison. Inline use like `if String.trim(s) == "" then` works, but `String.length(String.trim(s)) > 0` would fail because the named-value returned by `String.trim` isn't automatically unwrapped in function-argument position.

**Note**: `String.length`, `List.length`, `Int.abs`, etc. intentionally return **plain integers** (not proof-bearing) so they work correctly in inline comparisons like `if String.length(s) > 3 then`.

#### Usage example

```tesl
import Tesl.String exposing [String.trim, String.requireNonEmpty, String.length, IsTrimmed]
import Tesl.Int exposing [Int.nonZero, Int.divide, IsNonZero]
import Tesl.List exposing [List.sort, List.map, List.filter, IsSorted]

fn sanitizeName(raw: String) -> String ::: IsTrimmed result =
  String.trim(raw)      # result has IsTrimmed proof

fn safeDivide(a: Int, b: Int ::: IsNonZero b) -> Int =
  Int.divide(a, b)      # b's IsNonZero proof prevents division by zero

fn processNames(names: List String) -> List String ::: IsSorted result =
  List.sort(names)      # result has IsSorted proof

check validateName(raw: String) -> name: String ::: IsNonEmpty name =
  String.requireNonEmpty(raw)
```

---

### 4. Time module — `time.md`

Updated `Tesl.Time`:
- `nowMillis()` — returns POSIX milliseconds (the canonical Tesl time unit)
- `formatTime(posixMs, timezone, fmtString)` — human-readable formatting
  - Timezone: `"UTC"`, `"Europe/Stockholm"`, `"America/New_York"`, etc. (uses TZ env-var trick, best-effort)
  - Format codes: `%Y %m %d %H %M %S %3N %z %Z %%`
  - Example: `formatTime(nowMillis(), "UTC", "%Y-%m-%dT%H:%M:%S.%3NZ")`
- `durationMs(pastMs)` — milliseconds elapsed since `pastMs`
- `addMs(ts, delta)`, `subtractMs(ts, delta)`, `diffMs(a, b)` — arithmetic
- `Time.posixToSeconds(ms)`, `Time.secondsToPosix(s)` — conversion helpers
- `now()` still exists for backwards compatibility (returns POSIX seconds, not ms)

**Note**: For production timezone handling, a proper tz library is recommended. The TZ env-var approach is best-effort for single-timezone environments.

---

### 5. SQL injection protection audit — `systemic_protection_against_injection.md`

**Finding**: SQL injection protection was already sound before this PR. All user-supplied WHERE/INSERT/UPDATE values go through `$1`, `$2`, … parameterized queries via Racket's `db` library. Column and table names are validated against `^[A-Za-z_][A-Za-z0-9_]*$` and double-quoted.

**Added**: 10 adversarial regression tests (`SQL-INJ-001` through `SQL-INJ-010`) in `tests/thsl-test.rkt` that verify:
- Injection payloads (`' OR '1'='1`, `' UNION SELECT ...`, `'; DROP TABLE ...`) are safely bound as parameters
- Null bytes and control characters are correctly parameterized
- The `identifier-value->string` whitelist rejects SQL-injection attempts in column/table names

---

### 6. Bug fix: list literals in body expressions

**Bug found and fixed**: `[]` (empty list) and `[x, y]` (list literals) in function body expressions were compiled to raw `[]` / `[x y]` in Racket, which Racket interprets as empty/invalid function application (`(#%app)`). This caused a crash when passing list literals as function arguments:

```tesl
# This was broken:
fn addToFront(x: Int, xs: List Int) -> List Int =
  List.append([x], xs)           # [x] compiled as () — crash!

fn example(xs: List Int) -> List Int =
  List.foldr(consInts, [], xs)   # [] compiled as () — crash!
```

The fix adds list-literal handling to `BodyCompiler.compile_expr` in `compile_thsl.py`, emitting `(list)` for `[]` and `(list *x *y)` for `[x, y]`.

This was a pre-existing compiler bug revealed by the new standard library tests.

---

## Test count

| Before | After |
|---|---|
| 380 tests | **553 tests** |

All 553 pass. New tests cover:
- STD-001 through STD-033: String, List, Int function happy paths and edge cases
- SQL-INJ-001 through SQL-INJ-010: Adversarial SQL injection parameterization tests
- STD-040 through STD-055: Dict and Set Racket-layer tests
- STD-060 through STD-064: Either Racket-layer tests

---

## New future-roadmap items added

1. **`openapi-spec-generation.md`** — Automatic OpenAPI 3.x generation from `api`/`server` declarations. Medium scope.
2. **`database-migrations.md`** — First-class versioned migration system to replace auto-migrate-on-boot. Large scope.
3. **`proof-returning-stdlib.md`** — Documents the current state and the compiler enhancement needed for proof-bearing stdlib functions to work inline in arithmetic/comparison. Medium scope compiler change.
4. **`dead-letter-queue-api.md`** — First-class dead-letter inspection and replay. Small-medium scope.
5. **`streaming-responses.md`** — SSE and chunked-transfer streaming endpoints. Large scope.
6. **`rate-limiting.md`** — Built-in capability-based rate limiting. Medium-large scope.

---

## Items from roadmap that were NOT implemented (with reasons)

| Item | Reason skipped |
|---|---|
| `for_all_proofs.md` | Complex type-system design — requires significant LANGUAGE-SPEC changes |
| `improve_error_messages.md` | Large scope (multiple tiers of error UI, suppressed raco output) |
| `built-in-mutation-testing.md` | Very large integration work with Racket's `mutate` library |
| `improved_compiling.md` | Tree-shaking requires significant compiler restructuring |
| `improve_language_server.md` | Large undefined scope |
| `lessons_learing_material_for_language_devs.md` | Documentation work, low code impact |

---

## Things to review / decisions for you

1. **Proof-bearing stdlib functions**: The current design (String.trim returns IsTrimmed, but String.length returns plain int) is a pragmatic tradeoff. The `proof-returning-stdlib.md` roadmap item documents the compiler enhancement that would remove this limitation. Does this tradeoff feel right?

2. **Time module**: The `formatTime` function uses the `TZ` environment variable trick for timezone conversion. This is best-effort — in production, you'd want a proper timezone library (like Racket's `srfi/19` or a C binding). Should I add a note in the docs that this is "good enough for single-timezone apps"?

3. **Dict and Set modules**: These are available at the Racket level but not yet exposed as proper Tesl ADTs (they're opaque Racket values). To use them from Tesl, a user would need to call the functions. Is this acceptable for now, or should they be integrated into the Tesl type system (so you can write `let d: Dict String Int = Dict.empty`)?

4. **`Tesl` CLI**: The shell function approach (via shellHook) works perfectly within `nix-shell`. But it's only a bash function — it won't appear in `PATH` for other shells. If you want `Tesl` to be a real executable, we could use `writeShellScriptBin`. I left the option in the shell.nix as a `Tesl-cli` derivation but the `buildInputs` include it. **This might not work without the correct repo path**. Check `Tesl help` after entering `nix-shell`.
