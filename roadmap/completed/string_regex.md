# `Tesl.Regex` — regex on `String`, with the pattern checked at compile time

**Status: IMPLEMENTED (2026-07-29).** Item 4 of
`roadmap/next/primitive_gaps_and_outbound_hardening.md`.

The roadmap item left three questions open — compile-time-checked patterns,
ReDoS posture, and the capture-group return type. All three are answered below,
each with its reasoning, because each is a decision a future change could
quietly undo.

---

## What shipped

A new pure stdlib module, `Tesl.Regex` (`LANGUAGE-SPEC.md` §21.6):

| Function | Signature |
|---|---|
| `Regex.matches` | `(pattern: String, input: String) -> Bool` |
| `Regex.find` | `(pattern: String, input: String) -> Maybe String` |
| `Regex.findAll` | `(pattern: String, input: String) -> List String` |
| `Regex.captures` | `(pattern: String, input: String) -> Maybe (List String)` |
| `Regex.replace` | `(pattern: String, input: String, replacement: String) -> String` |
| `Regex.split` | `(pattern: String, input: String) -> List String` |

No capability — the module is pure.

Four stable diagnostic codes, all in `Error_codes.registry`:

| Code | Rule |
|---|---|
| `VREGEX001` | the pattern must parse in Tesl's subset of `pregexp` |
| `VREGEX002` | the pattern must be a **string literal at the call site** |
| `VREGEX003` | the pattern must not be able to backtrack catastrophically |
| `VREGEX004` | every capture group must participate in every successful match |

Files:

| Path | Role |
|---|---|
| `compiler/lib/regex_lint.ml` | the pattern parser, the character-set algebra, the four rules, and the AST pass |
| `compiler/lib/compile.ml` | `regex_literal_diagnostics` — runs alongside the other surface passes, so `tesl check`, `--check-json` and `agent-context` all report it |
| `compiler/lib/emit_racket.ml` | fail-closed backstop: emission refuses a `Regex.*` call whose pattern is not a literal |
| `compiler/lib/type_system.ml` | `stdlib_env` rows, the `Tesl.Regex` export list, `tesl_known_module_names` |
| `compiler/lib/checker.ml` | `Regex` added to `known_qualifier_modules` |
| `compiler/lib/stdlib_docs_entries.ml` | the `tesl doc` / hover catalog rows |
| `tesl/regex.rkt` | the runtime: memoised compilation, the execution deadline, the input bound |
| `compiler/test/test_regex_surface.ml` | 58 checks — accepted patterns, each rejection class, the literal rule in several expression positions, and the table invariants |
| `tests/regex-runtime-tests.rkt` | the ReDoS bound and the other runtime-only properties (gated in `ci.sh` phase 11) |
| `example/learn/lesson75-regex-validation.tesl` | the lesson: regex inside `check` functions that mint `ValidEmail` / `ValidSlug` |

---

## Decision 1 — a literal pattern that does not compile is a **compile error**

`Regex.matches "[a-z" s` is `error[VREGEX001]`, not a runtime raise.

The pattern is not data the program happens to hold; it is a piece of the
program, and Tesl's whole proposition is that pieces of the program are checked
when the program is checked. A malformed pattern is a typo, and a typo that
only shows up on the unlucky request — inside a `check` function, the one place
a program most wants to be right — is exactly the class of bug the language
exists to move earlier.

The validator is a hand-written recursive-descent parser over Tesl's subset of
`pregexp`, not a call into a host regex engine. That is deliberate: the compiler
must **reject** constructs the host would happily accept (backreferences,
lookaround, inline flags, lazy quantifiers), and it must understand the pattern
structurally to enforce decisions 2 and 3. Everything the validator accepts is
valid `pregexp`, so the runtime never sees a pattern it cannot compile.

The subset is documented in §21.6. One consequence worth restating: a Tesl
string literal already processes escapes (§8.5), so a regex backslash is written
doubled (`"\\d+"` is the pattern `\d+`), and `\n`/`\t`/`\r`/`\\` are excluded
from the subset because their spelling inside a pattern would be ambiguous.
Character classes are the recommended style anyway — `[0-9]` and `[.]` need no
escaping at all.

---

## Decision 2 — ReDoS is fail-closed: **no dynamic patterns, and ambiguous repetition does not compile**

Two rules, and one operational bound behind them.

### 2a. The pattern must be a string literal (`VREGEX002`)

There is no dynamic-pattern function, no separately-gated escape hatch, and no
"advanced" variant. `Regex.matches userPattern input` cannot be written.

The reasoning, in the order it matters:

1. **A pattern from request data is the hole.** The roadmap called this out
   (audit gap L6) and it is not a hypothetical: with a backtracking engine, a
   forty-character request field is a CPU bomb. Removing the form removes the
   hole outright, which is strictly stronger than any amount of bounding.
2. **It is what makes the other rules real.** `VREGEX001/003/004` are
   properties of a pattern the compiler can see. Allow a runtime pattern and
   all three degrade from guarantees to advice, and the honest signature for
   `Regex.captures` degrades with them (see decision 3).
3. **The lost use case is smaller than it looks, and better served another
   way.** The genuine need behind "user-supplied patterns" is usually
   user-supplied *search*, which wants substring/prefix matching
   (`String.contains`, SQL `LIKE`, full-text search), not a regex language
   handed to anonymous callers.

We considered a gated `Regex.matchesUnchecked` behind a capability plus a hard
timeout, and rejected it. A capability makes the effect visible but does not
make it safe, the timeout only converts "hangs forever" into "burns the budget
on every request", and — decisively — its mere existence would force
`Regex.captures` to return `Maybe (List (Maybe String))` for everyone, because
an unchecked pattern can have non-participating groups. One escape hatch would
have made the honest signature impossible for the 99% who do not need it. If a
dynamic surface is ever added it must be a *separate* module with its own
(weaker) capture type, not a back door into this one.

The rule is enforced twice on purpose. `Regex_lint.module_diagnostics` produces
the user-facing diagnostic; `Emit_racket` independently refuses to emit a
`Regex.*` call whose first argument is not a literal. The diagnostic pass walks
the expression-bearing declaration kinds, and "a kind was forgotten" is a
fail-open shape — so emission, which is total over the program, carries the same
rule as a backstop.

One wrinkle worth recording: a Tesl string containing `$` lexes as an
interpolation even with no `${…}` hole, so `"^ab$"` arrives as a single-literal
`LInterp`. Since `$` is the end anchor, the literal test accepts that shape;
anything with a real hole is `VREGEX002`.

**Naming.** Because the pattern must be written at the call site, a pattern
cannot be given a name — and that is the better idiom regardless. Name the
*predicate*: `fn isSlug(s: String) -> Bool = Regex.matches "…" s`. Callers read
`requireSlug`, not a regex. Even a top-level binding holding a literal is
rejected, so there is exactly one shape to look for and no constant folding to
trust.

### 2b. Ambiguous repetition does not compile (`VREGEX003`)

Catastrophic backtracking needs *ambiguity under repetition*. The rule:

> For a group repeated two or more times (`*`, `+`, `{n,}`, or `{n,m}` with
> m ≥ 2), the body may not match the empty string, may not contain a top-level
> `|`, and may not contain its own quantifier — **unless** the body begins with
> an unquantified single-character atom whose character set is disjoint from
> every other character atom in the body (and the body contains no nested
> group).

A quantifier that repeats at most once (`?`, `{0,1}`, `{1}`) is exempt: one
iteration introduces no repetition ambiguity, so `(?:ab+c)?` is fine.

The exception is the part that makes the feature usable rather than merely
safe. A leading fixed separator that cannot be consumed by anything else in the
body forces every iteration to start at a determined position, so the input
decomposes exactly one way and the matcher has nothing to backtrack over. It is
a sufficient condition, checked exactly, with a small code-point range algebra
(`cset` in `regex_lint.ml`) doing the disjointness test:

```
"^[a-z0-9]+(?:-[a-z0-9]+)*$"    accepted — '-' cannot appear in [a-z0-9]
"^(?:\.[a-z]+)+$"               accepted — same shape
"^(?:ab+)+$"                    accepted — 'a' cannot appear in 'b'
"^(a+)+$"                       VREGEX003 — the body starts with a quantifier
"^(?:aa+)+$"                    VREGEX003 — the sets overlap
"^(?:a|a)*$"                    VREGEX003 — alternation under a quantifier
"^(?:x*)*$"                     VREGEX003 — nullable body under a quantifier
"^(?:[a-z]+\.)+[a-z]+$"         VREGEX003 — separator is at the wrong end
```

Two *neighbouring* unbounded repetitions over overlapping sets (`[0-9]+[0-9]*`)
are also rejected: that is the common accidental quadratic.

**What this does not catch, stated honestly.** The rules eliminate *exponential*
backtracking. Polynomial ambiguity spread across several non-adjacent
quantifiers is not detected syntactically; it is bounded operationally (2c).
Alternation branches that overlap without a quantifier (`(?:ab|abc)`) are linear
and left alone. A full regular-expression ambiguity analysis would catch more,
and would also reject far more real patterns and be much harder to explain in an
error message; that trade was made deliberately in favour of a rule a user can
read once and predict.

### 2c. The runtime bound (defence in depth)

`tesl/regex.rkt` runs every match in its own Racket thread under a wall-clock
deadline (`TESL_REGEX_TIMEOUT_MS`, default 1000) over a bounded input
(`TESL_REGEX_MAX_INPUT_BYTES`, default 1 MiB). Exceeding either raises a clean
`raise-user-error 'Regex …`, so a handler returns an error instead of pinning a
request thread (and, inside a `transaction`, a DB pool slot — cf. issue #31).

This works because Racket CS implements its regexp engine in Racket and its
threads are preemptible, so `kill-thread` genuinely stops a runaway match. That
is not folklore here: `tests/regex-runtime-tests.rkt` hands the runtime `^(a+)+$`
against forty `a`s and a `!` — a pattern the *compiler* rejects, reachable only
by calling the runtime module directly — and asserts the call returns a deadline
error in roughly the budget rather than never. Compiled patterns are memoised,
so the steady-state per-call cost is a hash lookup plus one green-thread spawn.

`Regex.replace` inserts its replacement **literally**: `$1`, `\1` and `&` are
ordinary characters. A replacement is the one argument that legitimately comes
from user data, and a second mini-language evaluated over user data is the same
class of mistake as the dynamic pattern. Group-referencing replacement is a
deliberate omission, not an oversight.

---

## Decision 3 — capture groups return `Maybe (List String)`, and that is honest

`Regex.captures : (pattern: String, input: String) -> Maybe (List String)`.
The outer `Maybe` is "did the pattern match". The list holds one `String` per
capture group, in source order, with the whole match **excluded** (use
`Regex.find` for the whole match). A pattern with no groups yields
`Something []` on a match.

The obvious objection is that this type is a lie in every other language: a
group under `?` or inside a losing alternation branch does not participate, and
the engine reports "no capture", which `List String` cannot express. The usual
answers are `List (Maybe String)` (honest, tedious for everyone) or `""` for a
non-participating group (a silent lie).

Tesl takes the third option, which only a compile-time-checked pattern makes
available: **rule `VREGEX004` rejects the patterns where a group can fail to
participate.** There are exactly two such shapes, and both are syntactic:

- a capture group under a quantifier (`(a)?`, `(a)+`, `(a){2}`) — it captures
  only its last repetition, or nothing at all at count zero;
- a capture group inside an alternation branch (`(a)|(b)`) — the other branch
  may win.

Rule out both and every capture group of an accepted pattern captures a string
on every successful match. The type is then exactly right, and the list length
is statically the number of groups the author wrote. The fix in both cases is a
non-capturing `(?: … )`, which the diagnostic names.

`tesl/regex.rkt` still maps a `#f` group to `""` defensively, and says in a
comment that the branch is unreachable for a compiler-checked pattern — the
runtime module stays total on its own, but it is not where the guarantee lives.

**Why not something richer** (a `RegexMatch` record with `matched`, `groups`,
`index`; or named groups)? A record buys the whole-match text, which
`Regex.find` already gives, and a byte offset, which nothing in the surface
consumes. Named groups would want a `Dict String String`, which reintroduces
partiality (`Dict.lookup` returns a `Maybe`) — the exact thing the rule just
removed — and needs `(?<name>…)`, which is outside the subset. Both are
strictly-additive later if a use case appears; neither is needed for the case
this feature exists to serve, which is minting facts.

---

## Argument order

The pattern is argument 1 of every function, including `Regex.replace`
(`pattern, input, replacement`), even though `String.replace` is
`(s, from, to)`. Uniformity is load-bearing here: the literal rule is stated,
enforced and tested as "argument 1 of every `Tesl.Regex` function", and
`test_regex_surface.ml` asserts it as a table invariant. It is also the ordinary
Tesl convention for a "how" argument (`List.map f xs`, `Dict.get key dict`).

## Why a new module rather than `String.*`

`String.replace` and `String.split` already exist with literal-substring
semantics; a regex version would either collide or need awkward names. A
separate module also gives one import to reason about, one place to state the
pattern rule, and one qualifier that makes a regex call visible when reading
code.

## Verification

- `compiler/test/test_regex_surface.ml` — 58 checks: twelve accepted patterns
  (including the email and slug idioms), every rejection class with its code,
  the literal rule in a `fn` / `test` block / lambda / `check` function, and the
  table invariants (every export typed, exports ≡ the lint table, pattern always
  argument 1, `Regex.captures` has no inner `Maybe`, all four codes registered).
- `tests/regex-runtime-tests.rkt` — the ReDoS bound, the input bound, clean
  failure on an uncompilable pattern, the semantics of all six functions, the
  literal-replacement guarantee, and pattern memoisation. Gated in `ci.sh`
  phase 11.
- `example/learn/lesson75-regex-validation.tesl` — byte-exact snapshot in the
  integration gate; its five `test` blocks run in the Tesl test phase.
- The standing seam tests carry the new surface with no new escape hatches:
  `test_stdlib_runtime_binding.ml` (every export resolves to a real Racket
  provide), `test_stdlib_signature_coverage.ml` (every export is typed),
  `test_stdlib_docs.ml` (every export is documented), `test_error_codes.ml`
  (the four codes are registered and their manual anchors resolve),
  `test_spec_anchors.ml` (§21.6 resolves).

## Follow-ups (not done, deliberately)

- **Case-insensitive matching.** `(?i:…)` is outside the subset. Today: lowercase
  the input first, or spell the class (`[Aa]`). Worth revisiting as an explicit
  `Regex.matchesCaseInsensitive`, which keeps the pattern semantics fixed.
- **Named capture groups.** Would want a `Dict`-shaped return; see decision 3.
- **A pattern that must match the whole string.** `Regex.matches` is unanchored;
  users write `^…$`. A `Regex.matchesWhole` would remove a common footgun.
- **Polynomial-ambiguity analysis.** Only the adjacent-pair case is caught
  statically; the rest is bounded by the deadline.
