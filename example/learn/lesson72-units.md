# Lesson 72: Units — Compile-Time Dimensions, Runtime Floats

> **Implemented — full SI dimensional analysis, erased at runtime.**
> - If your app has a `topSpeed` column and an AI agent calls your tool with `110` — km/h? mph? m/s? — this lesson is for you.
> - The ordinary operators derive dimensions: `Acceleration * Duration : Speed` (m/s² × 4 s = m/s).
> - Wrong-unit code **does not compile** — the km/h-vs-m/s bug class dies at the type checker.
> - Zero runtime cost: every quantity is a plain Float in the compiled program.
> - See `example/learn/lesson72-units.tesl` for the runnable version of everything below, and `LANGUAGE-SPEC.md` §21.5 for the reference.

---

## The mental model — three rules

Units confuse people because most libraries make you *manage* them. Tesl makes them *impossible to mismanage* instead, with a model small enough to hold in your head:

1. **ENTER through a constructor.** `Length.miles 3.0` converts *into* the SI canonical unit. Inside your program every `Length` **is** meters, every `Duration` **is** seconds, every `Speed` **is** m/s. One value, one ruler.
2. **ALGEBRA happens in the types.** `*` and `/` derive new dimensions; `+`, `-` and comparisons demand the *same* dimension. You never convert mid-formula, because mid-formula everything already is canonical SI.
3. **EXIT through an accessor.** `Speed.inKilometersPerHour v` converts back *out*, naming the unit at the boundary.

Raw unit numbers exist only at the two edges — construction and reading — so there is nowhere *in between* for a unit mix-up to hide. And at the edges, the constructor or accessor names its unit right at the call site, where a reviewer can see it.

```tesl
fn finalSpeed(a: Acceleration, t: Duration) -> Speed =
  a * t
```

That is the whole feature in one line. No conversion calls, no unit registry, no runtime tax — and annotating the result as anything but `Speed` is a compile error.

## Why does `a * t` know it's a Speed?

A dimension is seven integer exponents over the SI base dimensions (length, mass, time, current, temperature, amount, luminosity). The familiar names are just labels for exponent vectors:

| Type | Exponents | Read as |
|---|---|---|
| `Length` | L¹ | m |
| `Area` | L² | m² |
| `Duration` | T¹ | s |
| `Speed` | L¹ T⁻¹ | m/s |
| `Acceleration` | L¹ T⁻² | m/s² |
| `Force` | L¹ M¹ T⁻² | newton |
| `Energy` | L² M¹ T⁻² | joule |

`*` **adds** the exponent vectors, `/` **subtracts** them. So `Acceleration * Duration` is L¹T⁻² + T¹ = L¹T⁻¹ — a `Speed`, mechanically. Formulas fall out of the arithmetic, business ones included:

```tesl
# "when does the delivery arrive?" — Length / Speed = Duration
fn deliveryEta(remaining: Length, avg: Speed) -> Duration =
  let safe = Units.requireNonZero avg
  remaining / safe

# ½·m·v² : Mass × Speed × Speed = L²M¹T⁻² = Energy
fn kineticEnergy(m: Mass, v: Speed) -> Energy =
  0.5 * m * v * v
```

Two consequences worth pausing on:

- **The aliases are structural, not nominal.** `Speed` and "the result of `Length / Duration`" are *the same type*. You can compute a value one way and annotate it the other; annotations are documentation the compiler verifies, not casts.
- **Dimensionless results collapse to `Float`.** `Length / Length` has every exponent at zero — a ratio has no unit, so it is a plain `Float` again.

## Mixed units just work — that's rule 1 paying off

```tesl
let mixed = Length.meters 1.0 + Length.feet 1.0    # 1.3048 m — both are meters inside
let far   = Length.kilometers 1.0 > Length.feet 3000.0   # True
```

The classic "added kilometers to miles" bug is not a runtime hazard you test for; it is *unrepresentable*. Either both sides are `Length` (and therefore both canonical meters), or the program doesn't compile.

## Entities, JSON, and agents — where this pays rent

Quantities erase all the way down, so putting one in your data model costs nothing:

```tesl
entity Vehicle table "vehicles" primaryKey id {
  id: String
  topSpeed: Speed          # a plain Real column holding canonical m/s
}

handler addVehicle(...) requires [dbWrite] =
  insert Vehicle { id: newId, topSpeed: Speed.kilometersPerHour 110.0 }

# reading back: exit through the accessor of your choice
# Speed.inMilesPerHour v.topSpeed
```

| Boundary | What a `topSpeed: Speed` field is |
|---|---|
| Entity column | plain `Real` (double precision) — canonical m/s |
| JSON wire | bare number — `{"topSpeed": 30.556}` |
| Elm / TS client | `Float` / `number` |
| Agent tool parameter | number whose JSON schema says *"a Speed expressed in SI units: m/s — ALWAYS supply the value in m/s, never in km/h, mph…"* |

The schema description is the anti-hallucination channel: a model calling your tool is told the unit every time, the same way `PosixMillis` params are told "milliseconds, not seconds". Inside your handlers the checker enforces the rest.

Store SI, exit through accessors at display boundaries — the same "canonical inside, explicit at the edges" discipline as `PosixMillis` (UTC ms inside, `formatTime` at the edge) and `Money` (minor units inside, `Money.display` at the edge). Time, money, and units are one design, three instances.

## The five things that trip people up

**1. Printing shows the raw SI number.** Quantities erase — print a `Speed` and you see its m/s value. Always exit through an accessor before showing a number to a human. (Same discipline as `Money.display`.)

**2. Scalars are Floats, never Ints.** `2.0 * len` scales, `2 * len` is a compile error with a hint — Tesl never auto-promotes Int to Float. Any Float *expression* scales: `factor * len` is fine when `factor: Float`.

**3. Division wants a proof — minted with the bare call, not `check`.** Like every Tesl `/`, a variable divisor needs a non-zero proof. `Units.requireNonZero` mints the same `FloatNonZero` fact that guards Float division:

```tesl
fn pace(d: Length, t: Duration) -> Speed =
  let safe = Units.requireNonZero t
  d / safe
```

Habit from the proof lessons says `check Units.requireNonZero t` — don't: the generic `check` combinator collapses the quantity to a bare Float, the division stops cancelling dimensions, and you get a compile error like `cannot unify Length with Speed`. Call it directly. Also: the divisor must be a **named value** — dividing by `(2.0 * a)` directly gives V001 ("no trackable proof"); let-bind the expression first:

```tesl
fn brakingDistance(v: Speed, a: Acceleration) -> Length =
  let vSquared = v * v         # (m/s)² = L²T⁻²
  let twoA = 2.0 * a
  let safe = Units.requireNonZero twoA
  vSquared / safe              # v²/(2a) : L²T⁻² / L¹T⁻² = Length
```

**4. `Units.sqrt` needs even exponents.** It halves them: `sqrt Area : Length`. The square root of a bare `Length` would need L^½ — not a physical quantity, compile error.

**5. Temperature is affine.** `Temperature.celsius 100.0` applies the +273.15 *offset* and stores absolute kelvin. Adding two absolute temperatures type-checks (same dimension) but is rarely meaningful — dimensional analysis catches unit mistakes, not every physics mistake.

## What does NOT compile

```tesl
Length.meters 3.0 + Mass.kilograms 1.0   # ❌ error: cannot add quantities of different
                                          #    dimension: `Length` and `Mass`
Length.meters 3.0 + 1.0                   # ❌ error: wrap the number in a unit constructor first
2 * Length.meters 3.0                     # ❌ error: write a Float literal (`2.0`, not `2`)
Length.meters 1.0 < Duration.seconds 1.0  # ❌ error: cross-dimension comparison
Units.sqrt (Length.meters 4.0)            # ❌ error: sqrt needs even exponents
fn f(x: Speed) -> Area = x * x            # ❌ error: x*x is L²T⁻², not Area — annotation verified
```

Error messages name the *dimensions*, never internal encodings — you'll see `` `Length` and `Mass` `` or `` `m/s^2` ``, and the hints point at the fix.

## Import gating — why `Speed` is safe to export

`Length`, `Speed`, `Area`… are common words. They resolve to quantity types **only in a module that imports them from `Tesl.Units`**. A module that never asked keeps its own `type Speed = Slow | Fast` working unchanged; a module that imports the alias *and* declares a colliding type gets a compile error — never a silent hijack. Internally each dimension's canonical name uses characters that cannot appear in a Tesl identifier, so user types can never collide with (or forge) a quantity type.

## The Duration bridge

`PosixMillis` timestamps stay exact-integer ms (lesson 26). `Duration` is the *typed span* between them:

```tesl
let deadline = Time.add start (Duration.hours 2.0)   # reads as intended
let waited   = Time.diff start deadline               # : Duration
```

`addMs ts 7200000` still exists and stays exact — but the typed form cannot be misread as seconds, by a model or by you at 3am. `Duration.toMillis : Duration -> Int` (half-even rounding) and `Duration.fromMillis : Int -> Duration` convert explicitly when an API wants integer ms.

## FAQ

**Where do I put the unit conversion in a formula?** Nowhere. Convert at construction and at reading; the middle is all canonical SI.

**How do I get the raw number out?** Through an accessor: `Length.inMeters d`, `Speed.inKilometersPerHour v`. Pick the accessor for the unit you want — that choice is independent of how the value was constructed.

**How do I display a value with its unit?** There is no auto-display — which unit to show is your UI's choice, not the value's. Exit through the accessor and label it yourself: `"${Speed.inKilometersPerHour v} km/h"`.

**What if I pass a feet value to `Length.meters`?** The checker cannot know what a raw `110.0` means — that is exactly why raw numbers are confined to the two edges, where the constructor or accessor names the unit inline. A wrong-unit entry is a one-line, greppable, reviewable mistake at a named call site — instead of a bug diffused through every formula that ever touches the value.

**Why Float comparisons with a tolerance in the tests?** Unit factors like feet (0.3048) are not exact in binary floating point. Values that stay in one exact unit compare exactly; values that crossed a non-exact factor should be compared with a tolerance (`approxEqual` in the lesson).

**Can I define my own units or dimensions?** Not yet — the catalog is fixed (16 quantity types; see `LANGUAGE-SPEC.md` §21.5 for the full constructor/accessor list), and user-defined dimension *variables* (a function generic over any dimension) are not in the surface language. `Units.mul`/`Units.div`/`Units.sum`… cover the generic-over-dimension cases by computing the dimension at each call site.

**Is there a runtime check anywhere?** Only the division proof. Everything dimensional is compile-time; the compiled program computes with bare Floats.
