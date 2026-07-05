# Fail-closed: mint-side proof matching is string-based, not structural (P5, robustness)

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

This was investigated 2026-07-06. **No exploitable forgery was demonstrated.** For a
forgery, two *structurally different* proofs must render to the *same* string. Over
this grammar (`pred` + space-joined args), `pp_proof` is near-injective; the only
constructed collision is an arg containing a space (`Pred "a b"` renders like the
two-arg `Pred a b`), and the surface syntax appears to forbid a space inside a proof
arg. So this is **fail-closed consistency hardening** (align mint with the trusted
structural primitive so it cannot drift, and remove the order-sensitive outlier),
**not** a known-hole closure. Do not describe it as a soundness fix without first
demonstrating an exploit.

## Why it is still worth doing (eventually)

- **Drift resistance:** two matchers for one relation (structural on carry, string on
  mint) is exactly the divergent-copy class the discharge work exists to remove. The
  string matcher could become genuinely weaker as the proof grammar grows (e.g. if
  args ever admit spaces, qualified names, or nested structure).
- **The `:805` outlier** is independently worth fixing: order-sensitive `pp_proof`
  equality means `A && B` vs `B && A` mismatch (an over-reject / false positive today,
  the safe direction — but inconsistent with the `normalize_conj` siblings).

## Fix (when scheduled)

Replace the string comparison with an **order-insensitive structural** equality:
flatten both sides to atoms (`flatten_proof_conj`), map each atom to `proof_key`,
sort the key lists, compare. Strictly stronger than sorting by `pp_proof` (no
rendering collisions). Apply to the CheckKind (`:666`), AuthKind (`:697`), and
RetMaybeAttached (`:805`) arms so all mint matching uses one structural relation.
Note: mint requires proof **equality** (minted == declared), NOT the entailment
relation `proof_matches` uses on the carry side — do not swap in `proof_matches`.

## Verification

`dune build && dune test`, `./ci.sh` 13/13. Tightening to structural can only reject
MORE, so the Validate oracle (accept every shipped `.tesl`) is load-bearing. Keep the
mint negatives green (`G45`, `proof-soundness-boundary`, `fn-cannot-mint`,
`forall-ok-proof`). If severity is ever in question, first attempt to construct a
forgery through the string match (option B from the 2026-07-06 discussion).
