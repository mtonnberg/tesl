# First-Class Units — compile-time dimensional quantities + Money

**Status: IMPLEMENTED (2026-07-08), all phases (P0–P3) in one pass.** Shipped as
designed below plus review upgrades found during implementation:

- **P0** `scripts/gen-currencies.py` → `compiler/lib/currencies.ml` (155 ISO 4217
  currencies with the load-bearing `minor_digits` column) + generated
  `dsl/private/currency-data.rkt` (`define-currencies` macro in hand-written
  `dsl/private/money-core.rkt` — data file stays pure data, per-currency
  `Money.usd`… constructors get static provides for the binding seam test).
- **P1 Money**: nominal `TCon "Money"`, integer minor units + intrinsic Currency
  struct; `Money.fromMinorUnits` (NOT `Money.of` — `of` is the case keyword,
  found live); proof-gated `add`/`subtract`/`compare` via `SameCurrency a b`
  rows in `stdlib_func_infos` (the Dict.get cross-param shape) minted by
  `Money.requireSameCurrency` (Dict.requireKey shape); `NonNegativeMoney`;
  `ExchangeRate` (decimal-faithful exact rate, e.g. 0.9155 → 1831/2000) +
  `Money.convert : Result Money String` with ONE half-even rounding +
  `RateFor`-gated `convertChecked`; **`Money.scaleBy` (Float factor,
  exactified, half-even)** for interest/VAT — named, not `*`, because it
  rounds; culture-INVARIANT `Money.display` (`"$10.50"`, `"¥1000"`,
  `"10.50 SEK"` — locale rendering is client-side `Intl`); two-column DB
  storage (`price_minor BIGINT + price_currency TEXT`, native `SUM`,
  mixed-currency/empty sum rejected, ordered where-ops rejected); agent-JSON
  enrichment `{minorUnits, currency, display}` (HTTP stays bare) + `APMoney`
  schema description; `IRMoney` + tolerant Elm/TS decoders; raw operators on
  Money are compile errors with proof-pointing hints.
- **P2 dimensions**: `units_catalog.ml` (7-exponent `dim`, canonical
  `§Q[l,m,t,c,K,mol,cd]` TCon names — ZERO unifier change, dimension equality
  is TCon equality); `infer_binop` split (quantity branch BEFORE the
  unify-to-Float default; `*` adds exponents, `/` subtracts, dimensionless
  collapses to Float, Int-scalar gets a "write 2.0" hint); `ty_is_ord/eq`
  opened for quantities only; 13 alias types (Length…Pressure) resolved in
  `ty_of_type_expr`; ~100 constructors/accessors (factors ONLY in
  `tesl/units.rkt`; full erasure to Float — quantity entity columns are
  `Real`); `BDiv` emit fix (`quotient` → real `/` for Float/quantity via the
  new structured `expr_ty_tbl`; also fixed latent Float division, lesson34
  snapshot regenerated); quantity agent-param schemas name the SI unit.
- **P3 polymorphic ops**: `Units.mul/div/square/sqrt/abs/negate/min/max/sum/
  requireNonZero` dimension-computed per application site (`infer_units_op`,
  decide-by-resolution) in BOTH the infer path and the check_expr tail path
  (the tail-position fail-open was found by doc-writing review and closed);
  `Units.sqrt` requires even exponents; `Units.requireNonZero` mints
  `FloatNonZero` so quantity division satisfies the same `/` proof rule as
  Float.
- **Import gating (found live, `type Speed = Slow | Fast` in the corpus)**:
  alias names + currency ctor lowering activate ONLY for modules importing
  Tesl.Units/Tesl.Money (`Units_catalog` active-alias state set per module by
  the checker; emit `currency_ctors_active`); collision WITH the import is a
  compile error — never silent hijack.
- **Duration bridge**: `Time.add/subtract : PosixMillis -> Duration ->
  PosixMillis`, `Time.diff : … -> Duration`, `Duration.toMillis/fromMillis`
  (half-even) — typed spans alongside the exact-Int ms forms, which stay
  canonical.

Verification: `./ci.sh` 13/14 green on a clean run — phase 4 (embedded-docs
sync) red only because it requires the regenerated `embedded_docs.ml` to be
COMMITTED; everything else green including exact-match snapshots, mutation,
PG suites, boot smoke. Tests: `compiler/test/test_units_money.ml` (58 checks,
29 positive / 29 negative, `§Q[` never leaks into diagnostics),
`tests/units-tests.tesl` (20) + `tests/money-tests.tesl` (19) runtime suites,
`tests/sql-money-tests.rkt` (39) + `tests/sql-money-pg-test.rkt` (18, real
temporary PostgreSQL parity incl. mixed-currency rejection and corrupt-code
fail-closed). Docs: LANGUAGE-SPEC §21.4/§21.5 + §10.5 + §14b.1,
lesson71-money + lesson72-units (byte-exact snapshots), manual
examples/overview/best-practices. Known deferred: the generic `check f x`
combinator collapses quantity types (use the bare `Units.requireNonZero`
mint); division by a compound expression needs a let-bound divisor;
user-written dimension-VARIABLE annotations (true ∀d) remain out of surface.

Original accepted design below.

---

**Status: PLANNED (2026-07-08).** Accepted design, staged. Full SI dimensional
analysis with **compile-time** dimension checking and derivation
(`m/s/s × 4s : m/s`), plus a **Money** sibling whose currency is a runtime
qualifier (like `TimeZone`) — deliberately *not* an SI dimension (no USD²). Chosen
architecture is the compile-time-typed path (the note's explicit "checked at
compile time" and the only option that is a real differentiator over the
inspirational libraries, which mostly check at runtime). Delivered in independently
shippable phases; time (`PosixMillis`/`TimeZone`) is left untouched and documented
as the first instance of this class. See sibling design [[time_bucketed_grouped_aggregates]],
[[time_posix_module]], [[issue_28_ordered_comparison_newtype]].

## Original ask

Great support for units (money, length, time, volume, …) because they are a
common bug source (km/h vs m/s) and LLMs hallucinate around them. Take inspiration
from unitpy / pint / elm-units / Haskell units / elm-money / currency libs, adding
"the Tesl twist with heavy use of proofs". All types checked at **compile time** to
minimize runtime bugs; the JSON-decoded value should aid LLMs and minimize
hallucination. Time is already partially solved — it is just one instance of this
class. Later user steers: units must **combine and derive** (`m/s`, `m²`, `m/s/s`;
`m/s/s × 4s : m/s`); full SI; money like Time/Date with a currency qualifier;
include **runtime-supplied currency exchange**.

Inspirational libraries (may or may not be a good fit): unitpy, pint, elm-units,
Haskell `units` / `units-defs` / goldfirere/units, elm-money, Haskell `currency`,
carlospalol/money.

## What is true today (mapped 2026-07-08)

- **Greenfield** — no dimension/quantity/currency machinery exists anywhere
  (`compiler/lib`, `dsl/`, `tesl/`); the time family is the only "unit".
- **Time is the exact template** — nominal `TCon` + `define-newtype` runtime +
  name-keyed DB codec + opt-in agent-JSON enrichment (`{epochMillis, iso}`) +
  baked qualifier ADT (`TimeZone`). Load-bearing distinction: `PosixMillis` carries
  **no** zone at runtime (the zone is a separate ADT argument). Money differs —
  currency is **intrinsic** to the amount, so Money is a two-valued runtime value
  (integer minor-units + `Currency`), reusing the *type-system mechanics* of the
  template but not its single-Int wrapper.
- **Minimal HM type system** — 4 `ty` constructors (`type_system.ml:20-24`);
  Robinson `unify` where `TCon c1 <> c2 → mismatch` (`type_system.ml:177`);
  monomorphic arithmetic in `infer_binop` (`checker.ml:2936-2965`) that forces both
  operands to one scalar and returns it; `ty_is_ord`/`ty_is_eq` fail **closed** for
  unknown `TCon` (`checker.ml:1675,1697`); newtypes are **not** parameterizable
  (`TypeNewtype` has no `params`, `ast.ml:260-262`); no typeclasses / operator
  overloading (`checker.ml:69-73`); no unit-literal syntax (`<` is `LT`,
  `lexer.mll:212`); the Eq/Ord constraint layer (`ord_eq_acc`/`ord_eq_constraints`/
  `ord_eq_calls`, `checker.ml:98-107`) is a reusable harvest-per-fn →
  discharge-per-callsite pattern.
- **Proofs** — a user `fact Name (params)` (`ast.ml:298-302`) is minted only by
  check/auth/establish at the LCF kernel boundary (`proof_kernel.ml:16-21`) and
  discharged generically by `proof_matches` (`validation_common.ml:527-541`). The
  `UUID.validate → IsUuid` pattern (`LANGUAGE-SPEC §21.1`, runtime
  `tesl/uuid.rkt:74-78,129-137`) is the check-mints-fact template.

## Design decision — why compile-time (Path A), and why staged

The note demands "checked at compile time" and "leverage our proof system". A
runtime-tracked quantity module would be far cheaper (a stdlib module + a Racket
engine, zero type-system change) but its dimension mismatches are runtime/`Result`
errors — which contradicts the stated goal and reduces Tesl to "just another units
library". So dimensions are **types**, checked by the compiler, erased at runtime.
Cost is contained by staging and by a representation that needs **no** change to
the unifier or the `ty` algebra (below).

## The key representation idea (phase 2 core)

A dimension is 7 signed SI exponents. Represent a dimensioned type as a
**canonical nominal `TCon`** whose name encodes the exponent vector, backed by a
`ctx.dims` side-table — the exact house pattern (newtype = nominal `TCon` +
`type_aliases`). Because every SI quantity erases to `Float`, the dimension fully
determines the type; no base-type parameter is needed.

```
type dim = { length:int; mass:int; time:int; current:int; temp:int; amount:int; lumin:int }
dim_name d = "§Q[l,m,t,c,temp,amt,lum]"      (* sigil chars illegal in identifiers → collision-proof *)
t_quantity d = TCon (dim_name d)
```

Consequences (all verified against source):
- **Zero unifier change.** Dimension equality = `TCon` string equality, already
  decided by `unify` (`type_system.ml:155,177`). Cross-dimension add/compare fails
  via the existing `TCon c1<>c2 → mismatch`.
- **Zero new `ty` arm** — avoids touching every exhaustive `ty` match across
  `type_system.ml`/`checker.ml`/`emit_*`/`ir.ml` (the codebase is deliberately
  wildcard-free).
- Only two predicates must be **opened** for quantity `TCon`s (else the
  fail-closed default rejects legitimate same-dimension compares):
  `ty_is_ord`/`ty_is_eq` (`checker.ml:1666-1698`).

## Phases (each ships independently; each exits on `./ci.sh` 13/13)

### Phase 0 — Currency ADT bake (prereq, tiny)
Clone `tz_zones`: `scripts/gen-currencies.py` → generated `compiler/lib/currencies.ml`
holding **`(ctor, iso_code, numeric_code, minor_digits)`** for the full active ISO
4217 set (`Usd`,`Eur`,`Jpy`,`Sek`,`Bhd`…; USD=2, JPY=0, BHD=3). The extra
`minor_digits` column (which `tz_zones` lacks) is authoritative for rounding and
display, so it must come from the ISO source, never hand-typed. Ctors typed
`: Currency` and appended to exports like `Tz_zones.ctor_names`. A typo'd currency
is a compile error; completion lists every currency.
*Exit:* `import Tesl.Money exposing [Currency, Usd, Eur]` typechecks; a
`currencies`-resolve test mirrors `tests/timezone-zones-test.rkt`.

### Phase 1 — Money (the committed near-term deliverable)
Money is a runtime struct `(money minor-units currency)`; nominal `TCon "Money"`.
Currency is **intrinsic** (a runtime qualifier carried in the value).

```
# Construction (per-currency → minor-unit count unambiguous at the call site)
Money.usd : Int -> Money        # 1000 -> $10.00 (2 minor digits)
Money.jpy : Int -> Money        # 1000 -> ¥1000  (0 minor digits)
Money.of  : Currency -> Int -> Money
Money.minorUnits : Money -> Int      Money.currency : Money -> Currency
Money.scale   : Money -> Int -> Money      # integer scaling, always exact
Money.compare : Money -> Money -> Order     # same-currency only
Money.display : Money -> String             # "$10.00" / "¥1000" (uses minor_digits)
Money.add / Money.subtract : Money -> Money -> Money   # same-currency only (proof-gated)
# NO Money.multiply — money² is meaningless (mirrors the USD² ban)
```

- **Integer minor-units only — money never becomes a Float.** That invariant is
  the point of the type. Anything lossy (percentage, division, FX) is out of the
  base MVP and must be proof-guarded.
- **Currency-match model = runtime qualifier** (per the "treat like Time" steer).
  Honest trade-off, stated up front: since a `Money`'s currency is not in its
  static type (just as a `PosixMillis`'s zone isn't), `usd + eur` is a
  **runtime/proof** error, *not* a compile error. The alternative (currency-in-type)
  gives compile-time currency safety but cannot model runtime-chosen currency,
  mixed-currency lists, or arbitrary-currency JSON decode — poor fit for real apps.
- **The proof superpower (headline).** Currency safety lands a full phase before
  any type-system change, via the `UUID.validate` mint pattern
  (`tesl/uuid.rkt:74-78,129-137`):
  ```
  fact SameCurrency (a: Money, b: Money)                       # two-subject fact
  check sameCurrency(a: Money, b: Money) -> (a,b) ::: SameCurrency a b =
    Money.requireSameCurrency a b
  fn add(a: Money ::: SameCurrency a b, b: Money) -> Money = Money.add a b
  # you literally cannot add USD to EUR without the minted proof in hand
  ```
  Ship phase-1 proofs: **`SameCurrency`** (two-subject — the only novelty, rides
  existing multi-subject proof machinery) and **`NonNegativeMoney`** (a byte-for-byte
  `IsNonNegative`/`IsUuid` clone). Both are user-facing stdlib predicates owned by
  `Tesl.Money` — no framework-predicate additions (`type_system.ml:758-763`
  untouched). Discharged generically by `proof_matches` — no operator special-casing.
- **Currency exchange (tight follow-on within phase 1).** Include it, but the rate
  is **runtime-supplied** (the timezone analogy holds in *shape* — an explicit
  qualifier passed to the op — but breaks on baking: FX rates are external,
  non-deterministic, lossy, and audit-relevant, unlike authoritative tzdata):
  ```
  ExchangeRate = { from: Currency, to: Currency, rate: <precise>, asOf: PosixMillis }
  Money.convert : ExchangeRate -> Money -> Result Money   # total; requires rate.from == m.currency
  ```
  The Tesl twist: the from-currency match is a proof obligation (`RateFor rate m`,
  minted by a check); the result carries `rate` + `asOf` as **provenance** so
  conversions are auditable; rounding stance explicit (documented, e.g. banker's).
  **Deliberately NOT:** any ambient/implicit conversion, any default rate, any
  `Money.add usd eur` that silently converts — that silent path is *the* money bug
  this feature kills. Tesl ships the type + total, provenance-carrying `convert`;
  it does **not** bundle a rate feed/source (app-level: fetch via `HttpClient`,
  store rates in an entity — same boundary as "Tesl bakes zones but doesn't fetch NTP").
- **DB storage = two columns** (`price_minor BIGINT`, reusing the `PosixMillis`
  BIGINT path, `+ price_currency TEXT`). Rationale: the prime use case is
  server-side aggregation and `SUM(price_minor)` is a native BIGINT sum that
  composes with the existing `groupBy`/`Time.trunc` machinery. This is the **first
  field spanning two columns** (SQL layer is one-field-one-column today,
  `sql.rkt:253-274,1118-1170`) — the main new SQL work in phase 1. Rejected:
  composite PG type (migration pain, no aggregation win); documented fallback:
  single `jsonb` (zero new machinery but loses native `SUM()` — defeats the point).
- **Agent-JSON enrichment (LLM anti-hallucination) — clone the PosixMillis path:**
  new `current-agent-money-enrichment?` param + `money-agent-jsexpr`
  `{minorUnits, currency, display}` + a `runtime-value->jsexpr` arm, set at the
  same two agent boundaries (`server-tools.rkt:213`, `agent.rkt:425-427`), **HTTP
  stays bare** (`{minorUnits, currency}`). Add `APMoney` to the `agent_prim`
  registry (`validation_common.ml:124-165`) carrying the load-bearing schema
  description ("integer MINOR UNITS + ISO-4217 code — never dollars, never a
  float; $10.00 USD is {minorUnits:1000, currency:USD}"). Add `IRMoney` + tolerant
  Elm/TS decoders that accept both bare and enriched (`display` optional),
  mirroring the PosixMillis `oneOf`/`union`.
- **Pure module — no capability** (confirmed: construction/arithmetic/compare/
  display/proofs are all pure; no `tesl_stdlib_cap_map` row).
*Exit:* all `./ci.sh` phases green incl. a new money PG-parity test (below) and the
byte-exact `lesson71-money` snapshot.

### Phase 2 — Monomorphic compile-time dimensions
- `type dim` + `dim_add/sub/neg` + `dim_name` + `t_quantity` + `ctx.dims`
  side-table.
- **Split the arithmetic arm** of `infer_binop` (`checker.ml:2940-2965`), quantity
  branch running **before** the existing unify-to-`num_ty` (else the dimension is
  lost to `Float`): `BMul` adds exponents; `BDiv` subtracts; scalar×quantity /
  quantity/scalar keep/invert the dimension (unify the scalar side to `Float`);
  `BAdd`/`BSub` require equal dimensions (else "cannot add quantities of different
  dimension `m` and `kg`", mirroring the existing `posix_hint`,
  `checker.ml:299-305`); `%` undefined on quantities. Comparisons need **no** new
  arm (nominal unification rejects cross-dimension); only open
  `ty_is_ord`/`ty_is_eq` for quantity `TCon`s.
- **Named constructors** (`Length.meters 5.0`, `Time.seconds 4.0`,
  `Speed.metersPerSecond 12.5`) via the existing qualified-name path — **no lexer/
  parser change**. Accessors `Length.inMeters : <m> -> Float`, etc.
- **Runtime erasure:** quantities are plain `Float`; constructors emit as identity
  (`tesl/units.rkt`), zero runtime cost. One required emit fix: `BDiv` currently
  lowers to `quotient` (integer division, `emit_racket.ml:3167`) — emit real
  Racket `/` when the binop's inferred type is a quantity/`Float`, consulting the
  structured `ty` already on `expr_type_info` (`checker.ml:47`,
  `emit_racket.ml:7219-7224`). This also fixes a latent plain-`Float` division
  quirk. `pp_ty` gains a sigil arm rendering `§Q[...]` as `m/s`, `m²` (before
  `TCon c -> c`, `type_system.ml:271`).
- **Quantity JSON enrichment — the erasure/enrichment reconciliation (flagged
  design point).** Because dimensions **erase to bare Float**, a runtime value has
  no unit, so the generic type-erased `runtime-value->jsexpr` walk *cannot* add
  `{value, unit}` the way it does for PosixMillis/Money. Resolve it by driving
  quantity enrichment from the **emit-time declared type**: the per-type codec/
  schema generator (which knows the field's dimension) bakes the unit string into
  the encoder and the `agent_prim` schema description. This covers typed boundaries
  (entity fields, codec records, tool params with a declared `Quantity` type). The
  generic ad-hoc agent-result walk over a bare quantity Float stays un-enriched
  **unless** phase 2 chooses to keep a lightweight runtime unit-tag on
  boundary-crossing quantities (partial de-erasure) — decide during phase 2 when
  the real usage is known. (Money has no such tension: currency is intrinsic
  runtime data.)
- Money's currency stays a qualifier — **not** folded into the dimension vector.
*Exit:* dimensioned arithmetic typechecks; `m/s/s × 4s : m/s`; `m + kg` rejected at
compile time; an `m/s` example rejects `m + s`.

### Phase 3 — Dimension polymorphism
Generic-over-unit functions (`abs : ∀d. Q d -> Q d`, `List.sum`,
`mul : Q d1 -> Q d2 -> Q (d1·d2)`) need a **dimension variable** — a separate sort
over the abelian group of exponent vectors, *not* a `ty`-level `TVar` (which would
wrongly unify with `Int`/`List`). Discharging exponent-linear obligations is
abelian-group / linear-Diophantine unification, which Robinson unification cannot
do and which is non-unitary — hence deferred. Reuse the `ord_eq` machinery
structurally (`checker.ml:98-107,4795-4829`): harvest per-fn dimension obligations
in rigid vars, discharge at each call site once argument dimensions are ground.
Adds user-defined units. *Exit:* polymorphic multiply/divide typecheck and compose.

## Implementation map (keyed on modules)

- **`compiler/lib/currencies.ml` + `scripts/gen-currencies.py`** (P0): baked ISO
  4217 4-tuple table; clone `tz_zones.ml`/`gen-tz-zones.py`.
- **`type_system.ml`**: (P1) `t_money`/`t_currency` `TCon`s beside `t_posix` (:42);
  `Money.*` schemes + currency ctors `@ Currencies.ctor_names` in `stdlib_env`;
  `Tesl.Money` row in `tesl_module_exports` (clone `Tesl.Time` :859-866);
  `"Tesl.Money"` in `tesl_known_module_names` (:1089). (P2) `type dim` + helpers +
  `t_quantity`; `Tesl.Units` exports; `pp_ty` sigil arm (:258-286).
- **`checker.ml`**: (P2) `dims` field on `ctx` + `dim_of_ty` helper near
  `ty_is_ord` (:1666); split the arithmetic arm of `infer_binop` (:2940-2965); open
  `ty_is_ord`/`ty_is_eq` for quantity `TCon`s (:1666-1698); `Length`/`Time`/`Mass`/… in
  `known_qualifier_modules` (:1521). (P3) dimension-variable obligations reusing
  `ord_eq_*`.
- **`emit_racket.ml`**: (P1) `add "Tesl.Money" "tesl/money.rkt"` (:104). (P2)
  `emit_binop` `BDiv` real `/` for quantity/`Float` via `expr_type_tbl`
  (:3165-3277, :7219-7224); register unit constructors as identity + `tesl/units.rkt`
  path.
- **`dsl/sql.rkt`** (P1): two-column Money codec — type annotation + encode-on-write
  + decode/auto-wrap-on-read (:145-161, :246-274, :402-411, :1118-1170).
- **`dsl/types.rkt`** (P1): `current-agent-money-enrichment?` + `money-agent-jsexpr`
  + `runtime-value->jsexpr` arm (clone :663-693); money-type marker registration.
- **`validation_common.ml`** (P1): `APMoney` in the `agent_prim` registry
  (:124-165); confirm **no** `tesl_stdlib_cap_map` row; `proof_matches` handles
  `SameCurrency`/`NonNegativeMoney` unchanged (:527-541).
- **`ir.ml` + `emit_elm.ml` + `emit_ts.ml`** (P1): `IRMoney` + tolerant decoders
  (clone PosixMillis `oneOf`/`union`, `emit_elm.ml:256`, `emit_ts.ml:79`).
- **New runtime `tesl/money.rkt`** (P1): Money struct, Currency ADT ctors (like
  `tesl-tz-*`), ops, proof mint (clone `uuid.rkt:74-78`), codecs, `ExchangeRate` +
  `convert`. **New `tesl/units.rkt`** (P2): unit constructors = identity on Float.
- **Docs** (per phase): `LANGUAGE-SPEC §21.4 Tesl.Money` (P1) / `§21.5 Tesl.Units`
  (P2) in the §21 template; module reference block (:641-643) + proof-facts §6.4
  (:221); `manual/overview.md` module list + `manual/best-practices.md` money note;
  `example/learn/lesson71-money.tesl` (+ byte-exact `.rkt` snapshot) exercising
  construction, `display`, a `SUM` over a money column, and `SameCurrency`-gated `add`.

## Non-goals

- `money × money`; currency as an SI dimension (no USD²).
- Unit-suffix literal syntax `5.0<m/s>` — collides with the `LT` token
  (`lexer.mll:212`); deferred to a phase-1.5 (contextual lexing / distinct bracket).
- Bundled FX rate **feed/source** (app-level); Tesl ships only the `ExchangeRate`
  type + total `convert`.
- Retrofitting `PosixMillis`/`TimeZone` under the units framework — left untouched,
  documented as the first instance of the class (no churn to the shipped
  DST/#29-bucketing/enrichment systems).
- Full abelian-group (E-)unification in phases 1–2 (only phase 3 introduces
  dimension variables).

## Risks & containment

- **`BDiv → quotient` regression** (highest severity — dimensional/float division
  would silently integer-truncate or fail at Racket load). Contain with a
  `raco`-run **characterization** test that compiles *and* runs a quantity division
  and asserts the numeric result — not just a type test.
- **Fail-closed compare default** (`checker.ml:1675,1697`) must be opened for
  quantity `TCon`s and **only** those two predicates; unification stays strict so
  cross-dimension compares still fail.
- **Premature unify-to-Float** — the quantity branch must run before the existing
  operand-unify; test that `Length.meters 1.0 + Time.seconds 1.0` is *rejected*, not
  coerced.
- **Nominal-name collision** — contained by construction (sigil chars illegal in
  identifiers); one test asserting `dim_name` output is not a valid identifier.
- **Two-column Money SQL is new machinery** — add a money PG-parity test cloning
  `tests/sql-group-by-pg-test.rkt`: grouped `SUM(price_minor)` agrees Memory ⇄ real
  PostgreSQL, **and** a mixed-currency aggregate is rejected (not silently summed).
  Note: PG tests self-skip without a server, but **SKIP ≠ PASS** (`ci.sh`) — CI must
  run it against real PG.
- **Stdlib binding drift** — every new `Tesl.Money`/`Tesl.Units` name must resolve
  to a real runtime `provide`; guarded by `test_stdlib_runtime_binding.ml` (no
  phantom names).
- No wildcard may route a quantity op back to the Int/Float default — one mismatch
  test per operator (mirror the codebase's no-wildcard discipline).

## Verification

Per-phase, the authoritative green-check is **`./ci.sh` (13/13)**. Specifically:
- **P0:** currency ctors typecheck + resolve test (mirror `timezone-zones-test.rkt`).
- **P1:** OCaml static tests (Money typing, `SameCurrency`/`NonNegativeMoney`
  minting, mixed-currency add rejected); Tesl test file (Memory-backend money sums +
  proof-gated add + `convert` provenance); money PG-parity test; agent-enrichment
  round-trip (bare HTTP vs enriched agent shape via tolerant Elm/TS decoders);
  `LANGUAGE-SPEC §21.4` + `lesson71-money` byte-exact snapshot.
- **P2:** dimension-algebra typing tests (`m/s/s × 4s : m/s`; `m + kg` rejected;
  cross-dimension compare rejected); the `raco` division-characterization test.
- **P3:** polymorphic `mul`/`div` compose; generic-over-unit fn typechecks.

## Open questions to confirm before/at build

- Currency-match model: **runtime qualifier** (chosen, matches "treat like Time";
  `usd + eur` is a runtime/proof error). Flip to per-currency types only if
  compile-time currency safety is wanted more than runtime-chosen currency — a
  different Money shape.
- Phase-2 quantity agent-enrichment: emit-time/type-driven vs a lightweight runtime
  unit-tag — decide in phase 2 from real usage.
- ISO 4217 generation source for `gen-currencies.py` (authoritative registry vs a
  curated ~25-currency hand-list fallback with identical 4-tuple shape).
