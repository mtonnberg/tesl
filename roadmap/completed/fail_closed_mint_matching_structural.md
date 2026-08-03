# Fail-closed: mint-side proof matching is string-based, not structural (P5, robustness)

> **Status:** DONE 2026-08-03.
>
> `Proof_checker.mint_proof_equal` (flatten → `Validation_common.proof_key` → sorted set) replaced
> the canonical-string comparison at all three `proof_expr` mint arms (CheckKind, AuthKind,
> RetMaybeAttached — the last of which was the order-SENSITIVE `pp_proof` outlier, so reversed
> conjunctions in a `Maybe` return now compile). The four ForAll/ForAllValues/ForAllKeys sites, where
> only a RENDERED inner survives, go through `mint_proof_equal_rendered`: it re-parses the inner via
> the new `Parser.parse_proof_snippet` and compares structurally, falling back to the string
> comparison only when the text does not parse (so an unparseable inner can never be MORE permissive
> than before). `normalize_conj_str` — now the fallback only — was fixed to do what its docstring
> already claimed: split on TOP-LEVEL `&&` only (paren- and string-literal-depth aware) and strip one
> layer of parens per atom.
>
> Tests: `compiler/test/test_mint_structural_proof_eq.ml`, 22 checks. The load-bearing ones are the
> UNIT tests over the matcher, for the reason the Verification section gives — an end-to-end `.tesl`
> exhibiting a collision is rejected by the ARITY guard whether or not the mint matcher works, so a
> "this file fails to compile" assertion would stay green through a total regression. `dune test`
> green; corpus gate green (the tightening rejected nothing that was previously accepted).

Sibling of [[fail_closed_checker_hardening]] (umbrella). **Discharge-side**
(check/auth MINT), not one of the 7 non-discharge judgments — logged here because it
is the same fail-closed-consistency class. Also relates to [[discharge-refactor-plan]]
(the mint side that a future fold would bring under the structural discharge judgment).

## Honest status: consistency gap, NOT a demonstrated hole

The carry side of discharge (`proof_discharge.ml`) matches proofs **structurally**
via the injective `proof_key` (`validation_common.ml:381`) / `proof_matches`. The
**mint** side (`proof_checker.ml:validate_check_return`) matches by canonical
**string**:

```ocaml
if normalize_conj normalized <> normalize_conj expected then <reject>   (* :666 CheckKind, :697 AuthKind *)
```

`normalize_conj` (`:63`) = flatten the conjunction, sort atoms by their `pp_proof`
rendering, join with `" && "`. And the RetMaybeAttached mint arm is weaker still —
plain `pp_proof x <> pp_proof y` (`:805`), order-**sensitive**, not even
`normalize_conj`.

This was investigated 2026-07-06 and **re-investigated empirically 2026-08-03**.
**No exploitable forgery was demonstrated**, and the conclusion stands — but the
2026-07-06 *reasoning* for it was wrong and is corrected below, because it
under-stated the fragility.

### Correction: space-bearing proof args ARE constructible

The 2026-07-06 note said "the surface syntax appears to forbid a space inside a
proof arg". It does not. There are two routes, and the in-tree B6 comment
(`validation_common.ml:415-426`) already names both as the reason the CARRY side
was moved off string matching:

- **Parenthesised opaque capture** (`parser.ml:352-373`): a `(...)` proof arg is
  captured verbatim as ONE string containing spaces (`Pred (Id == x) y` →
  args `["(Id == x)"; "y"]`).
- **Escaped quotes in a string arg** (`lexer.mll:235-239` decodes `\"` and `\\`;
  `parser.ml:425-431` re-wraps the decoded string in quotes): source
  `Tagged "a\" \"b" n` yields the ONE-arg `["\"a\" \"b\""; "n"]`, which
  `pp_proof`-renders as `Tagged "a" "b" n` — byte-identical to the THREE-arg
  `Tagged "a" "b" n`.

So a rendering collision between two structurally different proofs is
constructible at the surface, and the carry side was fixed (B6) precisely
because of it. The mint side is the remaining string-matching copy.

### Why there is still no exploit: two INDEPENDENT guards, in other files

Every such collision necessarily **changes arity** — a hidden space merges two
argument slots into one — and arity is validated separately from the string
match:

- **User-declared facts:** `validation_capabilities.ml:1640` rejects arity
  mismatch before the mint comparison matters. Verified 2026-08-03: the probe
  above (`ok n ::: Tagged "a\" \"b" n` against a declared
  `-> n: Int ::: Tagged "a" "b" n`) fails with
  `error[V001]: proof \`Tagged\`: argument count mismatch — expected 3, got 2`.
- **Kernel / builtin facts:** the arity check explicitly SKIPS these
  (`| None -> () (* Not a user-declared fact — skip *)`,
  `validation_capabilities.ml:1643`) — but those are exactly the predicates a
  user cannot mint at a check site. Verified: `ok n ::: FromDb …` in a user
  `check` fails with `error[T001]: fact ownership violation: \`FromDb\` can only
  be produced (via check/establish/auth) in the module that declares it`, plus a
  second refusal on the unrecognised provenance spelling.

So mint-side soundness today rests on an **accidental conjunction** of the string
match with two guards that exist for unrelated reasons and live in different
files — not on one trusted relation. That is the finding, and it is a stronger
argument for doing this work than the original "near-injective renderer" claim.

This remains **fail-closed consistency hardening**, **not** a known-hole closure.
Do not describe it as a soundness fix without first demonstrating an exploit.

## Why it is still worth doing (eventually)

- **The load-bearing guards are one exemption away from not being load-bearing.**
  The arity check that actually blocks the collision already carries exemptions
  (`forall_inner` allows `n_args = 0 || n_args = n_params - 1`; `entity_implicit`
  skips entirely; non-user-declared facts skip entirely). Each future exemption is
  a chance to hand the string matcher sole responsibility for a case it cannot
  handle — and nothing in `validation_capabilities.ml` tells its next editor that
  `proof_checker.ml`'s mint comparison is depending on it. A structural mint
  relation removes that invisible coupling.
- **Drift resistance:** two matchers for one relation (structural on carry, string on
  mint) is exactly the divergent-copy class the discharge work exists to remove. The
  string matcher gets genuinely weaker as the proof grammar grows (args already
  admit spaces — see the correction above — and qualified/nested forms are coming).
- **The `:820` outlier** (RetMaybeAttached; was `:805` before the file shifted) is
  independently worth fixing: order-sensitive `pp_proof` equality means `A && B`
  vs `B && A` mismatch (an over-reject / false positive today, the safe direction —
  but inconsistent with the `normalize_conj` siblings).
- **`normalize_conj_str` does not do what its docstring says** (found 2026-08-03,
  `proof_checker.ml:75-87`). The comment claims it "splits on top-level `&&`" and
  "trims + strips parens per atom"; the implementation scans for `&&` with **no
  paren-depth tracking** and only `String.trim`s — no paren stripping. So a nested
  `ForAll (P && (Q && R))` inner splits at the inner `&&` too. Over-reject
  direction (safe), but fix it in the same pass rather than leaving a comment that
  lies about a security-relevant matcher.

## Fix (when scheduled)

Replace the string comparison with an **order-insensitive structural** equality:
flatten both sides to atoms (`flatten_proof_conj`), map each atom to `proof_key`,
sort the key lists, compare. Strictly stronger than sorting by `pp_proof` (no
rendering collisions). Apply to the CheckKind (`:681`), AuthKind (`:712`), and
RetMaybeAttached (`:820`) arms so all mint matching uses one structural relation.
Note: mint requires proof **equality** (minted == declared), NOT the entailment
relation `proof_matches` uses on the carry side — do not swap in `proof_matches`.

The four `normalize_conj_str` call sites (`:761`, `:771`, `:788`, `:801` — the
ForAll / ForAllValues / ForAllKeys inner comparisons) are the harder half: they
compare pre-RENDERED inner strings because that is all the return spec carries.
Either parse each inner back to a `proof_expr` and use the structural relation, or
keep them string-based but fix the paren-depth bug noted above. Do not leave them
as the one string-matching island after the other three arms move.

## Verification

`dune build && dune test`, `./ci.sh` 13/13. Tightening to structural can only reject
MORE, so the Validate oracle (accept every shipped `.tesl`) is load-bearing. Keep the
mint negatives green (`G45`, `proof-soundness-boundary`, `fn-cannot-mint`,
`forall-ok-proof`).

Add a **seam test that does not depend on the arity check**: assert the mint
comparison itself rejects the escaped-quote collision
(`ok n ::: Tagged "a\" \"b" n` against declared `Tagged "a" "b" n`). Today that
file is rejected by `validation_capabilities.ml`'s arity guard, so a test asserting
only "this file fails to compile" would stay green even if the mint matcher
regressed — assert on the mint diagnostic, or unit-test the matcher directly.
That test is what converts the accidental two-guard conjunction into an
intentional one.
