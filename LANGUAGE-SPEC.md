# Tesl language specification (draft)

## 1. Purpose and scope
This document is the canonical draft specification for the `.tesl` surface language.

Its primary job is to describe **what Tesl should be as a language**. When the current implementation diverges from that goal, the intended language should remain normative and the implementation difference should be called out explicitly.

This document uses three status words:

- **Accepted design**: part of the intended language design.
- **Implemented**: already present in the current compiler/runtime.
- **Open**: not yet settled, or not yet implemented on the `.tesl` surface.

Unless stated otherwise, examples use intended `.tesl` syntax. Known implementation divergences are collected near the end of the document.

The `.tesl` frontend is the primary user-facing language. The underlying Racket DSL is an elaboration target and runtime substrate, not the main public surface.

Important implementation note on guarantees: when this specification says that something is enforced at compile time, that is the intended `.tesl` surface contract. The current implementation still contains runtime integrity checks in the Racket substrate, especially around trusted/internal boundaries and handler return validation. Those checks are defense in depth and an implementation divergence, not the desired long-term public model.

## 2. Product goals (non-normative, but guiding)
The following are not syntax rules, but they are part of the intended identity of Tesl and should guide language review.

- Tesl is a pragmatic GDP-inspired DSL for secure web APIs.
- The primary authoring surface should be readable, explicit, and unsurprising.
- The language should make important API knowledge visible in declarations rather than hiding it in handler bodies.
- The language should make invalid states hard to express without attempting full dependent typing.
- Proofs should be easy to work with, but not magical or theory-free.
- Hidden GDP names should be present by default; value unwrapping is handled implicitly by the compiler.
- Trusted proof introduction should happen at clear, auditable boundaries.
- The language should be intentionally opinionated and should move toward a built-in linter/formatter so Tesl code has one obvious style.
- The long-term surface should borrow the type-level clarity of Servant while improving readability and ergonomics in the direction of Elm and TypeScript.
- Ordinary side effects should be capability-governed. Telemetry is the deliberate ambient exception.
- Observability should be OpenTelemetry-first and OpenTelemetry-only.

Earlier architectural notes may use older syntax such as `unchecked-name`, `Requires`, `*name`, or older route notation. Those notes remain useful as design context, but they are not normative syntax. As the language is in active development when we introduce breaking changes we should *not* have any backward compatibility. We want to keep the language as tight and small as possible.

## 3. Reference lineage (non-normative)
Tesl is directly inspired by two lines of work:

- the GDP paper, *Ghosts of Departed Proofs*, especially the idea that preconditions should be checked early and then carried as ghost evidence rather than forcing repeated optional-value handling;
- the earlier `servant-gdp` work, especially the idea that API declarations can carry named route inputs and rich domain facts.

Tesl is not a direct syntax clone of either reference. They are conceptual ancestors, not exact templates.

### Proofs vs Facts
Proofs and Facts are used interchangeably in this document. In GDP they are called proofs but in Tesl they are called facts in an attempt to make the subject of using them less daunting.

## 4. Language layers
Tesl currently has three relevant layers.

### 4.1 Surface `.tesl` layer
This is the intended authoring surface. Users write modules, imports, records, entities, functions, captures, APIs, servers, and `main` blocks here.

### 4.2 Elaborated Racket DSL layer
The `.tesl` compiler lowers surface forms into Racket DSL forms such as `define/pow`, `define-checker`, `define-auther`, `define-handler`, `define-trusted`, `define-record`, `define-entity`, `define-api`, and `define-server`.

### 4.3 Runtime evidence layer (erased by default; retained under `--debug`)

Proof-relevant information *can* be carried at runtime through evidence-bearing values:

- named values (`named-value` struct: name, raw value, fact list, bindings);
- successful check results (`check-ok`);
- detached proofs (`detached-proof`);
- existential packages.

**By default this layer is erased.** For standard `check`/`fn`/`handler` paths the param-binding machinery (struct wrapping, `validate-runtime-argument`, the proof-environment `parameterize`) is dropped during macro expansion, so a release build allocates nothing for proof tracking. The flip to default-on followed a full differential audit: the emitted Racket is byte-identical regardless of the setting, and the erased program behaves identically to the runtime-checked one across the whole corpus (80/80), backed by ~1,150 negative tests.

**Retained pieces ("(almost)"):** free-floating proofs (`detached-proof`, via `detachFact`/`attachFact`) and cross-boundary proof transport keep their carriers; a proof-annotated parameter keeps one allocation so decomposition still works; `establish`/trusted facts, existential packages, newtype nominal wrappers, and `FromDb` proofs retain their representation.

**Erased under `--debug` too.** For a sound checker the runtime structs are redundant — a binding's proof is compile-time information. So `--debug` also erases; the debugger shows the raw runtime value and overlays proof/type from compile-time type info, and breakpoints (`thsl-src!` checkpoints, emitted separately by the OCaml emitter) are unaffected. `TESL_ZERO_COST_PROOFS=0` restores the runtime evidence layer for regression comparison.

### 4.4 Public interface

The only level that should be seen as "front facing" is the tesl-files. What is possible to do in the racket-files with manual changes is not interesting - if the language can prove its stated guarantees if a api web developer only works with the tesl files that is good enough. The racket files are an implementation detail - perhaps we will change it to a Rust och Zig layer in the future(or something else or keep it Racket). The compile layer should catch all errors except inherent runtime problems, such as database not available etc and they should only exist at the bounderies.

## 5. Effect model and operational stance
This section is normative for the public language design.

### 5.1 Capabilities govern ordinary side effects
**Accepted design.**

The capability system is the only public mechanism for ordinary side effects.

This means:

- effectful operations should be introduced through capability-governed primitives or helpers;
- code that performs ordinary side effects should declare the relevant capabilities;
- unrestricted ambient side effects are not part of the intended language model.

### 5.2 Telemetry is the ambient exception
**Implemented.**

Telemetry is the one deliberate exception to the ordinary capability rule.

The intended model is:

- Tesl is OpenTelemetry-first;
- telemetry is ambient and does not require an explicit capability in ordinary code;
- this exception exists because observability is considered part of the platform foundation rather than an arbitrary user-defined effect.

### 5.3 Opinionated foundation
**Accepted design.**

Tesl is intentionally opinionated. The language should reduce the number of stylistic and architectural decisions each developer must make.

That includes:

- explicit imports for unqualified names; module imports (`import Module`) for qualified-only access;
- a small number of canonical ways to express the same idea;
- a built-in opinionated linter and auto-formatter (`--lint`, `--fmt`, `--fmt-check`) enforcing a single canonical style.

## 6. Core semantic model
This is the most important part of the specification for soundness review.

### 6.1 Raw values
A raw value is an ordinary runtime payload with no attached proof facts.

Examples: an integer, a string, a record payload, a list.

### 6.2 Hidden subjects / GDP names
**Implemented.**

Every ordinary bound value in proof-aware Tesl code is associated with a hidden fresh subject identity.

The important point is that this subject identity is not the same thing as the surface spelling of the variable.

- Two values with the same raw payload still have different subjects if they were bound separately.
- Renaming a variable does not change what subject a proof is about.
- Shadowing is forbidden because it would blur the mapping from visible names to hidden subjects.

### 6.3 Named values
A named value is a runtime value together with:

- its hidden subject identity;
- its raw payload;
- zero or more attached proof facts;
- a binding environment that lets detached proofs continue to talk about the subject they were originally about.

A named value is the default proof-relevant carrier in the runtime.

### 6.4 Proof facts
A proof fact is a GDP expression such as:

- `ValidPort port`
- `Positive x`
- `OwnedBy user task`
- `FromDb taskId`
- `Positive x && ValidPort x`

The proof vocabulary is open. Tesl does not hard-code a closed set of propositions.

### 6.5 Detached proofs
A detached proof is a first-class proof value. It carries:

- one fact (can be a combined value since Proofs are recursive, such as `IsPositive x && IsBelow20 x`);
- the hidden-subject bindings needed to interpret that fact later.

Detached proofs exist so proofs can be transported explicitly when needed.

### 6.6 Existential packages
An existential package contains:

- one or more hidden witness bindings;
- a body value whose proof meaning may mention those witnesses.

Witnesses are scoped. They are not allowed to escape.

## 7. Global soundness invariants
These invariants should be treated as the backbone of Tesl's proof/name design.

### 7.1 Fresh hidden subjects for ordinary values
**Accepted design, Implemented.**

Every ordinary non-raw binder introduces or preserves a hidden subject identity.

### 7.2 Users may not fabricate or replay hidden subjects directly
**Accepted design. Implemented**

The user never writes the actual hidden name. Surface code only writes ordinary variable names, and the compiler/runtime map them to hidden subjects internally.

### 7.3 Facts attach to subjects, not to surface spellings
**Accepted design, Implemented.**

A proof about `x` is a proof about the hidden subject currently denoted by `x` at the point where the proof was formed. It is not a fungible proof that can be retargeted by reusing the same surface spelling elsewhere.

### 7.4 Name shadowing is illegal
**Accepted design, Implemented.**

Shadowing is forbidden for proof-relevant binders. This is a deliberate language rule, not a style preference.

The reason is semantic, not cosmetic: once values implicitly carry hidden subjects, reusing a visible name in the same scope chain becomes proof-relevant ambiguity.

### 7.5 `forgetFact` drops proofs but preserves the subject
**Accepted design, Implemented.**

`forgetFact(v)` removes attached facts from `v`, but it does not change which subject the value refers to.

This means `forgetFact` is not the same thing as dropping to raw space. It forgets evidence, not identity.

### 7.6 `detachFact` preserve the original subject identity
**Accepted design, Implemented.**

Detached proofs continue to refer to the subject they were originally attached to, even after transport.

### 7.7 `attachFact` does not retarget a proof to a new subject
**Accepted design, Implemented.**

A detached proof may be physically attached to another named value, but that does not change what subject the proof fact is about. Therefore reattachment is not a way to forge a proof obligation for a different subject.

### 7.8 Unbound GDP names in proof templates are rejected
**Accepted design, Implemented.**

Proof annotations and proof templates must only refer to names that are in scope under the relevant proof-binding rules.

### 7.9 Existential witnesses may not escape
**Accepted design, Implemented**

A hidden existential witness is scoped to its package/elimination context. Returning or storing it directly is a Skolem escape and is rejected.

### 7.10 Static checking and runtime checking are both part of the alpha contract
**Accepted design, Implemented.**

The `.tesl` frontend performs proof-aware static checking when it has enough information. In the current implementation, structural type checking and proof-aware checking run as separate frontend passes before lowering to the Racket DSL.

**Proof verification is compile-time** (excluding the retained carriers noted in §4.3). The runtime evidence structs are erased for standard `check`/`fn` paths — in release and `--debug` alike — so proof verification is a purely compile-time guarantee with zero runtime cost. `TESL_ZERO_COST_PROOFS=0` restores the runtime evidence layer as a regression-comparison safety net.

### 7.11 Newtype nominal identity is enforced at runtime
**Accepted design, Implemented.**

`type Name = BaseType` creates a nominal wrapper. Two newtypes over the same base type are distinct runtime types. The runtime predicate for `Name` checks for the `newtype-value` wrapper with the correct type tag, not just for a value satisfying `BaseType`. This ensures `UserId` and `ProjectId` (both wrapping `String`) cannot be accidentally interchanged.

### 7.12 Proof fabrication via `:::` is restricted to trusted function kinds
**Accepted design, Implemented.**

The `:::` operator in expression context outside `establish`, `check`, and `auth` function bodies may only attach existing proof values. Using a raw GDP predicate expression (e.g. `value ::: IsPositive x`) in a `fn` or `handler` body is rejected at compile time. This closes the bypass path that would otherwise let any function kind fabricate a proof fact without passing through a validation boundary.

### 7.13 The `?` pack operator for named return values
**Accepted design, Implemented.**

`-> Todo ? FromDb (Id == todoId)` declares a **named-pack** return. The returned value is automatically named by the caller's `let` binder:

```tesl
-- function declaration (new canonical infix syntax)
handler getTodo(...) -> Todo ? FromDb (Id == todoId) requires [...] = ...

-- callsite: the let binder `todo` becomes the GDP name
let todo = getTodo(requestUser, todoId)
-- todo :: Todo todo ::: FromDb (Id == todoId) todo

-- functions requiring the named 2-arg proof
fn process(t: Todo ::: FromDb (Id == id) t) -> ...
process(todo)   -- works: todo carries FromDb (Id == todoId) todo
```

**Syntax.** The canonical form is `Type ? EntityProofs [::: OtherProofs]`:

- `Type ? EntityProofs` — entity proof group only; `_entity` is auto-appended to every leaf predicate
- `Type ? EntityProofs ::: OtherProofs` — entity proof group plus independent proofs
- `Int ? Positive && Small` — compound entity proof; both get `_entity` appended
- `Int ? Positive ::: Admin user` — entity proof `(Positive _entity)` plus independent proof `(Admin user)`

**The entity-append rule.** Every leaf predicate in the `?` group (left of `:::`) gets `_entity` appended as its last argument. `&&` distributes:

```
FromDb (Id == todoId)  →  (FromDb (Id == todoId) _entity)
Positive               →  (Positive _entity)
Positive && Small      →  ((Positive _entity) && (Small _entity))
```

The `:::` group (other proofs) is left untouched — no `_entity` appended.

**Removed syntax.** The old prefix syntax `-> ?Type ::: proof` has been removed. Use the canonical infix syntax `-> Type ? Proof` instead.

The `?` annotation auto-extends the proof with the entity's own subject identifier. The SQL layer produces **two-argument `FromDb` facts** `(FromDb (Id == pk-subject) entity-subject)` so that both the primary-key binding and the entity identity appear in the proof. A backward-compatible one-argument fact `(FromDb (Id == pk-subject))` is also produced, so existing code using `binding` return specs (`-> item: Todo ::: FromDb (Id == id)`) continues to work.

The `?` annotation is also valid in `api` endpoint declarations:

```tesl
api MyApi {
  get "/todos/:todoId"
    capture todoId: String ::: TodoId todoId via todoIdCapture
    -> Todo ? FromDb (Id == todoId)
}
```

**Relationship to `check` functions.** For the common pattern of "validate an input and return the same value with proof," `check` functions are the right tool — their binding return spec already returns the same GDP identity as the input:

```tesl
check isSafeTitle(title: String) -> title: String ::: TitleSafe title =
  if String.length(title) <= 120 then ok title ::: TitleSafe title
  else fail 400 "title too long"
```

The `?` operator is for cases where the value is already proof-carrying and the caller needs to receive it named. For non-optional validation, `check` is preferred.

**Proof-carrying `Maybe` return** — `-> Maybe (v: T ::: P v)`.
**Accepted design, Implemented.**

When a function may or may not produce a proof-carrying value, use the named-binding
form inside `Maybe`. This is most useful with ADTs or domain types where the value and
its proof are produced together inside the function:

```tesl
# A binary tree where every node value is positive
type Tree
  = Leaf
  | Node left:Tree value:Int right:Tree

fact AllPositive (t: Tree)

check checkAllPositive(t: Tree) -> t: Tree ::: AllPositive t =
  case t of
    Leaf -> ok t ::: AllPositive t
    Node l v r ->
      if v <= 0 then fail 400 "node value not positive"
      else
        let l2 = check checkAllPositive l
        let r2 = check checkAllPositive r
        ok t ::: AllPositive t

# Returns the tree only if every node value is positive — proof flows through case
fn validateTree(t: Tree) -> Maybe (v: Tree ::: AllPositive v) =
  if True then                     # real implementation would examine the tree
    let valid = check checkAllPositive t
    Something valid
  else
    Nothing

fn processPositiveTree(t: Tree ::: AllPositive t) -> Int = 42

fn useTree(raw: Tree) -> Int =
  let m = validateTree raw
  case m of
    Nothing -> 0
    Something v ->
      processPositiveTree v   # v carries AllPositive v — proof flows automatically
```

**Syntax**: `-> Maybe (binder: T ::: P binder)` — the inner binder name identifies the
proof subject. The proof annotation is compile-time only; at runtime `Maybe (v: T ::: P v)`
is plain `Maybe T`.

The older `Maybe (Fact (P x))` idiom works when the caller already holds `x` and needs
only the detached fact to attach elsewhere. The `Maybe (v: T ::: P v)` form is idiomatic
when the returned value itself is produced at the proof boundary and the caller pattern-matches
on the result.

## 8. Lexical structure
### 8.1 File prologue
**Accepted design, Implemented.**

A Tesl source file may begin with:

- `#lang tesl`

The module header must still appear explicitly inside the file.

### 8.2 Comments
**Accepted design, Implemented.**

`#` starts a single-line comment, except:

- the `#lang` line is preserved;
- `#` inside string literals is preserved.

### 8.3 Indentation and braces
**Accepted design, Implemented.**

Tesl uses two structural mechanisms:

- indentation for function bodies and nested body constructs such as `if`, `case`, and existential packing bodies;
- braces for top-level blocks such as `record`, `entity`, `database`, `api`, `server`, `main`, and for body blocks such as `with database { ... }` and `with capabilities { ... }`.

Unexpected indentation is a parse error.

### 8.4 Identifiers and qualification
**Accepted design, Implemented.**

Informally:

- `identifier ::= [A-Za-z_][A-Za-z0-9_]*`
- `dotted-identifier ::= identifier ("." identifier)+`

Module names are dotted identifiers.

Dotted identifiers are used for **qualification and namespacing**, not for receiver-style extension methods. For example:

- `String.length title` is in scope as a desired form;
- `title.length` is not part of the intended language;
- `title.startsWith("x")` is not part of the intended language.

Explicit import/export names may additionally use the constructor-family form `Type(..)`.

### 8.5 Literals

**Accepted design, Implemented.**

**Integer literals** (`Int`): arbitrary decimal sequences, optionally preceded by a minus sign. Integer values are represented as Racket fixnums (63-bit signed integers on 64-bit platforms):

- **Range**: `−4611686018427387904` to `4611686018427387903` (i.e., `−2^62` to `2^62 − 1`).
- Integer literals outside this range are a **compile-time error**.
- Arithmetic on `Int` values in Tesl is fixnum arithmetic; values exceeding the range are not silently promoted to bignums.

**Float literals**: decimal literals containing a `.` (e.g., `3.14`, `-0.5`). Maps to Racket inexact floats (IEEE 754 double precision).

**String literals**: delimited by `"`. Support `\n`, `\t`, `\\`, `\"` escape sequences. Multi-line strings are not supported; embed `\n` for newlines.

**Bool literals**: `True` and `False` (capitalised). Lower-case `true`/`false` are not keywords.

**List literals**: `[e1, e2, e3]`. Nested lists require explicit brackets.

Tesl currently uses one lightweight GDP expression grammar for both type expressions and proof facts.

### 9.1 GDP expressions
**Accepted design, Implemented.**

```text
<gdp-expr> ::= <gdp-infix>
<gdp-infix> ::= <gdp-application>
              | <gdp-application> <gdp-op> <gdp-application>
              | <gdp-application> <gdp-op> <gdp-application> <gdp-op> ...
<gdp-op> ::= "&&" | "==" | "!=" | "<=" | ">=" | "<" | ">"
<gdp-application> ::= <gdp-atom> { <gdp-atom> }
<gdp-atom> ::= <identifier>
             | <dotted-identifier>
             | <integer>
             | <string>
             | "(" <gdp-expr> ")"
```

Notes:

- application is by whitespace, e.g. `ValidPort x`;
- infix operators are also allowed inside type/proof syntax;
- `Fact (Predicate x)` is ordinary GDP application syntax;
- `:::` is not part of GDP syntax itself; it is annotation syntax surrounding values, bindings, and return types.

### 9.2 Meaning of `&&` in proof facts
**Accepted design, Implemented.**

Inside proof facts and proof obligations:

- `P && Q` means both facts must hold.

This operator is used by both the static checker and the runtime proof checker.

Note: `||` (disjunction) is not supported in proof, by design (It was intentionally removed from the language). When a value may carry one of several proofs, use `Either` instead: `Either (Int a ::: IsPositive a) (Int b ::: IsNegative b)`.

## 10. Modules, imports, qualification, and standard library
### 10.1 Module header
**Accepted design, Implemented.**

```text
module <Module.Name> exposing [<explicit-name>, ...]
```

The header is mandatory and may only appear once.

Wildcards are not supported. Exports must be listed explicitly.

### 10.2 Imports
**Accepted design, Implemented.**

```text
import <Module.Name> exposing [<explicit-name>, ...]
import <Module.Name>
```

Two import forms are supported:

- **Explicit imports** list the names to bring into the unqualified scope. The constructor-family form `Type(..)` imports an ADT name together with all of its constructors.
- **Module imports** (no `exposing` clause) load the module without importing any names into the unqualified scope. All exported names from the module are accessible via qualified `Module.Name` syntax in both type annotations and function call positions.
- **Proof predicates** — upper-case names such as `ValidPort` or `IsPositive` used in `:::` proof annotations are first-class exportable names, exactly like functions and types. A module that declares a predicate through an `establish`, `check`, or `auth` function must list it in `exposing [...]` to make it importable. Any other module that explicitly names the predicate in its own function annotations must import it. This makes every proof predicate greppable: searching the codebase for `ValidPort` in an `exposing [...]` list finds its home module immediately.

**Import ordering.** All `import` declarations must appear immediately after the `module` header, before any type, function, capability, or other top-level declaration. An `import` that appears after any other declaration is a **compile-time error**:

```tesl
# WRONG — import after a function definition
module Bad exposing []
import Tesl.Prelude exposing [Int]
fn f() -> Int = 1
import Tesl.Bool exposing [Bool]   # error: import must come before all definitions
```

**Module file resolution.** When a user module is imported (e.g. `import MyDomain`), the compiler looks for the file `my-domain.tesl` (PascalCase-to-kebab-case conversion) in the same directory as the importing file. If the file does not exist the compiler emits a clear error naming the path that was searched. This is a compile-time error, not a missing-name error downstream.

Type-like declarations are module-scoped. If two modules both define a name such as `User`, `Task`, or `Status`, those declarations remain distinct even when they share the same surface spelling. Loading one module must not change the meaning of an unqualified type name in another module.

If a module needs to use same-named imported type-like declarations from different modules, the ambiguity must be resolved by module qualification/prefixing. The compiler should reject unqualified ambiguous uses rather than merging declarations by bare name.

When modules form a cyclic import group (SCC), the compiler detects conflicting names across the group and mangles them internally. Qualified type annotations such as `Sandbox2.ARecord2` resolve correctly within the SCC, and field access on values of qualified types works via the existing record/entity runtime.

### 10.3 Qualification instead of extension methods
**Accepted design, Implemented.**

Functions should not be magically attached to values.

The canonical style is namespaced function calls, for example:

- `String.length(title)`
- `String.startsWith(title, "prefix")`
- `Int.parse(raw)`
- `List.isEmpty(xs)`

Receiver-style syntax such as `title.length` or `title.startsWith("x")` is not part of the language.

### 10.4 Standard library vs core language
**Accepted design.**

The specification distinguishes:

- **core syntax and semantics**;
- **standard library / Prelude names**.

`Maybe` and `Result` should be treated as ordinary standard-library ADTs, not as special language forms. If the current implementation bootstraps them specially during lowering or import resolution, that is an implementation detail rather than a language fact.

Similarly, names such as `Int`, `String`, `Fact`, `time`, `dbRead`, `dbWrite`, and common helper functions may be provided by Prelude, but they should be understood as library-level names unless the language explicitly requires otherwise.

### 10.5 Current special module names
**Implemented, but non-normative.**

The current frontend gives special treatment to these module names:

**Core infrastructure**

- `Tesl.Prelude` — core type symbols (`Int`, `Bool`, `String`, `List`, `Fact`, etc.), and fact operations (`attachFact`, `detachFact`, `forgetFact`, `andLeft`, `andRight`, `introAnd`)
- `Tesl.Cli` — CLI argument helpers (`lookupPortArgument`)
- `Tesl.Id` — ID generation (`generatePrefixedId`). Requires the `random` capability — callers must import `random` from `Tesl.Random` and declare it in their capability's `implies` chain.
- `Tesl.Random` — randomness capability (`random`) and functions (`randomInt`). The `random` capability gates all non-deterministic operations. Import it alongside `Tesl.Id` when using `generatePrefixedId`, or standalone when calling `randomInt`.
- `Tesl.Tuple` — tuple constructors and accessors (`Tuple2`, `Tuple3`, `Tuple2.first`, `Tuple2.second`, `Tuple3.first`, `Tuple3.second`, `Tuple3.third`).
- `Tesl.Env` — environment variable access (`env`, `envInt`)
- `Tesl.DB` — database capabilities (`dbRead`, `dbWrite`)
- `Tesl.Http` — HTTP request type (`HttpRequest`)
- `Tesl.Telemetry` — telemetry sentinel bindings (`telemetry`, `initTelemetry`)
- `Tesl.Queue` — queue capabilities (`queueRead`, `queueWrite`, `pubsub`), proof predicates (`FromQueue`, `FromDeadQueue`)
- `Tesl.UUID` — UUID generation and validation: `UUID.v4`, `UUID.v7`, `UUID.validate`, `IsUuid` proof predicate, `uuidV4Codec`, `uuidV7Codec`. The `uuid` capability gates generation; `UUID.validate` requires no capability. See §21.1.
- `Tesl.JWT` — JSON Web Token support: `JWT.sign`, `JWT.verify`, `JWT.decode`, nominal newtypes `JwtToken` and `JwtSecret`. The `jwt` capability gates all operations. Algorithm: HS256. See §21.2.
- `Tesl.HttpClient` — outgoing HTTP requests: `HttpClient.get`, `HttpClient.post`, `HttpClient.put`, `HttpClient.delete`, the `HttpResponse` record, and the `httpClient` capability. See §21.3.

**String and number utilities**

- `Tesl.String` — string functions: `String.length`, `String.isEmpty`, `String.trim` (→ `IsTrimmed`), `String.toUpper` (→ `IsUpperCase`), `String.toLower` (→ `IsLowerCase`), `String.startsWith`, `String.endsWith`, `String.contains`, `String.split`, `String.join`, `String.replace`, `String.slice`, `String.padLeft`, `String.padRight`, `String.indexOf`, `String.toInt`, `String.fromInt`, and more. Also exports check function `String.requireNonEmpty` (→ `IsNonEmpty`) and proof predicate name constants `IsTrimmed`, `IsUpperCase`, `IsLowerCase`, `IsNonNegative`, `IsNonEmpty`.
- `Tesl.Int` — integer functions: `Int.parse`, `Int.abs`, `Int.min`, `Int.max`, `Int.clamp`, `Int.pow`, `Int.gcd`, `Int.lcm`, `Int.isPositive`, `Int.isNegative`, `Int.isEven`, `Int.isOdd`, `Int.toString`, `Int.sign`, `Int.toFloat`. Also `Int.nonZero` (check function → `IsNonZero`), `Int.nonNegative` (check function → `IsNonNegative`), and `Int.divide` (requires `IsNonZero` on the denominator). Exports `IsNonNegative`, `IsNonZero`.
- `Tesl.Float` — floating-point functions: `Float.parse`, `Float.abs`, `Float.min`, `Float.max`, `Float.clamp`, `Float.ceil`, `Float.floor`, `Float.round`, `Float.sqrt`, `Float.pow`, `Float.log`, `Float.exp`, `Float.sin`, `Float.cos`, `Float.tan`, `Float.isNaN`, `Float.isInfinite`, and more. Also `Float.requireNonZero` (check function → `FloatNonZero`) and `Float.div` (proof-total, requires `FloatNonZero` on the denominator). Exports `FloatNonZero`.

**Collection utilities**

- `Tesl.List` — list functions: `List.length`, `List.isEmpty`, `List.head`, `List.tail`, `List.last`, `List.nth`, `List.map`, `List.filter`, `List.filterMap`, `List.foldl`, `List.foldr`, `List.append`, `List.concat`, `List.reverse`, `List.sort` (→ `IsSorted`), `List.sortBy` (→ `IsSorted`), `List.contains`, `List.find`, `List.findIndex`, `List.take` / `List.drop` / `List.repeat` (proof-total and require `IsNonNegative` on the count argument), `List.zip`, `List.zipWith`, `List.unzip`, `List.sum`, `List.product`, `List.maximum`, `List.minimum`, `List.any`, `List.all`, `List.count`, `List.partition`, `List.range`, `List.unique`, `List.filterCheck` (→ `ForAll P`), `List.allCheck` (→ `Maybe (List T ::: ForAll P)`), and more. Exports `IsSorted`, `IsNonNegative`.
- `Tesl.Maybe` — the `Maybe` ADT with constructors `Something` and `Nothing`
- `Tesl.Result` — the `Result` ADT with constructors `Ok` and `Err`
- `Tesl.Either` — the `Either` type (Left/Right): `Left`, `Right`, `Left?`, `Right?`, `Left-value`, `Right-value`, `Either.map`, `Either.mapLeft`, `Either.andThen`, `Either.withDefault`, `Either.toMaybe`, `Either.fromMaybe`, `Either.partition`
- `Tesl.Dict` — immutable key-value map: `Dict.empty`, `Dict.singleton`, `Dict.insert`, `Dict.remove`, `Dict.lookup` (Maybe-returning lookup), `Dict.requireKey` (check function → `HasKey key dict`), `Dict.get` (proof-total and requires `HasKey key dict`), `Dict.member`, `Dict.size`, `Dict.isEmpty`, `Dict.map`, `Dict.filter`, `Dict.union`, `Dict.unionWith`, `Dict.intersection`, `Dict.difference`, `Dict.fromList`, `Dict.toList`. Also exports the proof predicate name `HasKey`.
- `Tesl.Set` — immutable unique-element set: `Set.empty`, `Set.singleton`, `Set.insert`, `Set.remove`, `Set.member`, `Set.size`, `Set.isEmpty`, `Set.union`, `Set.intersection`, `Set.difference`, `Set.isSubset`, `Set.map`, `Set.filter`, `Set.foldl`, `Set.any`, `Set.all`, `Set.partition`, `Set.fromList`, `Set.toList`, `Set.filterCheck` (→ `ForAll P`), `Set.allCheck` (→ `Maybe (Set T ::: ForAll P)`)

**Time**

- `Tesl.Time` — time functions and the `PosixMillis` newtype:
  - `PosixMillis` — newtype wrapping `Int` (milliseconds since Unix epoch). Automatically maps to `BIGINT` in PostgreSQL — **no `@db(bigint)` annotation needed** for `PosixMillis` fields.
  - `nowMillis()` → `PosixMillis` — current POSIX time in milliseconds
  - `formatTime(ms: PosixMillis, timezone: String, fmt: String)` → `String`
  - `durationMs(pastMs: PosixMillis)` → `Int` — milliseconds elapsed since pastMs (requires `time`)
  - `addMs(ts: PosixMillis, delta: Int)` → `PosixMillis` — add delta ms to a timestamp
  - `subtractMs(ts: PosixMillis, delta: Int)` → `PosixMillis`
  - `diffMs(a: PosixMillis, b: PosixMillis)` → `Int` — b − a in milliseconds
  - `Time.posixToSeconds(ms: PosixMillis)` → `Int`
  - `Time.secondsToPosix(s: Int)` → `PosixMillis`

**Time convention.** All timestamps use `PosixMillis`; all deltas/durations use `Int`. A plain `Int` does **not** satisfy a `PosixMillis` expectation — use `Time.secondsToPosix(s)` or `addMs(base, delta)` to construct typed timestamps. `PosixMillis` does **not** auto-unwrap for arithmetic — use `diffMs`, `addMs`, or `subtractMs` explicitly. Use `nowMillis()` on insert; format with `formatTime` at API boundaries only — never store pre-formatted strings.

```tesl
import Tesl.Time exposing [nowMillis, PosixMillis, time]

entity Post table "posts" primaryKey id {
  id:          String
  publishedAt: PosixMillis    # BIGINT — no @db annotation needed
}

handler createPost(...) requires [dbWrite, time] =
  insert Post { id: newId, publishedAt: nowMillis() }
```

**Why `BIGINT` not `TIMESTAMPTZ`?** Both use 8 bytes. `BIGINT`/epoch is portable, free of timezone surprises, and trivial to sort/compare with integer arithmetic. Convert when you need PostgreSQL date functions: `to_timestamp(ts / 1000.0)` and `extract(epoch from ts) * 1000`.

That is currently useful for bootstrapping, but the important public point is explicit importing and qualification, not the exact bootstrap mechanism.

### 10.6 Standard library GDP proofs
**Accepted design, Implemented.**

Several standard library functions return proof-bearing values. These proofs can be propagated through function signatures using the `?` return annotation.

**Proof-returning transformation functions:**

| Function | Proof attached to result | Usage |
|---|---|---|
| `String.trim`, `String.trimLeft`, `String.trimRight` | `IsTrimmed result` | Ensures caller has trimmed whitespace |
| `String.toUpper` | `IsUpperCase result` | Ensures string is uppercase |
| `String.toLower` | `IsLowerCase result` | Ensures string is lowercase |
| `List.sort`, `List.sortBy` | `IsSorted result` | Ensures list is sorted |

**Check functions (use with `let x = check f(n)`):**

| Function | Proof on success | On failure |
|---|---|---|
| `Int.nonZero(n)` | `IsNonZero n` | `fail 400` |
| `Int.nonNegative(n)` | `IsNonNegative n` | `fail 400` |
| `Float.requireNonZero(f)` | `FloatNonZero f` | `fail 400` |
| `String.requireNonEmpty(s)` | `IsNonEmpty s` | `fail 400` |
| `Dict.requireKey(key, dict)` | `HasKey key dict` on the dict | `fail 400` |

**Proof-total arithmetic and collection access:**

All of the following functions require a proof at the call site — the compiler rejects calls that lack the required proof:

| Function | Required proof | How to obtain |
|---|---|---|
| `Int.divide(a, b)` | `b ::: IsNonZero b` | `check Int.nonZero(b)` |
| `Float.div(a, b)` | `b ::: FloatNonZero b` | `check Float.requireNonZero(b)` |
| `List.take(n, xs)` | `n ::: IsNonNegative n` | `check Int.nonNegative(n)` |
| `List.drop(n, xs)` | `n ::: IsNonNegative n` | `check Int.nonNegative(n)` |
| `List.repeat(x, n)` | `n ::: IsNonNegative n` | `check Int.nonNegative(n)` |
| `Dict.get(key, dict)` | `dict ::: HasKey key dict` | `check Dict.requireKey(key, dict)` |

```tesl
fn safeDivideInt(a: Int, b: Int) -> Int =
  let divisor = check Int.nonZero(b)
  Int.divide(a, divisor)

fn safeDivideFloat(a: Float, b: Float) -> Float =
  let divisor = check Float.requireNonZero(b)
  Float.div(a, divisor)

fn safeTake(xs: List Int, n: Int) -> List Int =
  let count = check Int.nonNegative(n)
  List.take(count, xs)

fn requireUser(userId: String, users: Dict String String) -> String =
  let checkedUsers = check Dict.requireKey(userId, users)
  Dict.get(userId, checkedUsers)
```

**Return type annotation for proof-propagating functions:**

Use the `?` named-pack form to declare that a `fn` function propagates a stdlib proof:

```tesl
fn normalizeTitle(raw: String) -> String ? IsTrimmed =
  String.trim(raw)                    # proof automatically propagated

fn sortedItems(xs: List String) -> List String ? IsSorted =
  List.sort(xs)                       # proof automatically propagated
```

The entity-append rule expands `IsTrimmed` to `(IsTrimmed _entity)` where `_entity` is the returned value's hidden GDP subject.

**Important syntax note:**

```tesl
# WRONG — `result` is unbound in this position
fn f(s: String) -> String ::: IsTrimmed result = String.trim(s)

# RIGHT — ? form inserts _entity automatically
fn f(s: String) -> String ? IsTrimmed = String.trim(s)

# ALSO VALID — no proof annotation; proof is still attached at runtime
fn f(s: String) -> String = String.trim(s)
```

### 10.7 Libraries (`library` keyword)
**Accepted design, Implemented.**

The `library` keyword declares a module intended for reuse. It is syntactically identical to `module` but enforces a strict logic-only boundary at compile time.

```tesl
library ModuleName exposing [TypeA, FactB, checkB, helperFn]
```

#### Boundary rules

**Allowed in a `library` module:**

| Construct | Examples |
|---|---|
| Data types | `record`, `type` (ADTs), newtype |
| Proof system | `fact`, `check`, `establish`, `auth` |
| Functions | `fn`, `handler`, `worker` (function definitions only, not wiring) |
| Capabilities and codecs | `capability`, `codec` |
| Tests | `test` blocks |
| Constants | Top-level immutable bindings |

**Not allowed in a `library` module (compile error):**

| Construct | Reason |
|---|---|
| `api`, `server` | HTTP server wiring — app-level only |
| `main` | Entry point — app-level only |
| `workers` | Background worker wiring — app-level only |
| `database`, `entity` | Storage declarations — app-level only |

The compiler rejects any `library` module that contains these infra constructs. This makes the boundary machine-checked: a library is always safe to import from any other module.

**Import restriction:** Importing a `module` that itself contains `api`, `server`, `main`, or `workers` wiring is also a compile error. Those constructs are application entry points and cannot be consumed as library dependencies.

#### Signature completeness

If a `library` module exports a function, every type and proof predicate referenced in that function's parameter or return types must also be exported. This is a **compile error** for library modules.

```tesl
# WRONG — compile error
library UsernameLib exposing [checkName]
# checkName's return type uses IsValidName, but IsValidName is not exported.
# Consumers cannot write `String ::: IsValidName name` in their own code.

fact IsValidName (name: String)
check checkName(name: String) -> name: String ::: IsValidName name = ...
# Error: library UsernameLib exports checkName but IsValidName
#        (used in its signature) is not exported — consumers cannot use this function

# CORRECT — export everything the signature touches
library UsernameLib exposing [IsValidName, checkName]
```

#### W080 lint warning for regular modules

The same signature-completeness check runs on regular `module` declarations, but as lint warning **W080** rather than an error. Regular (non-library) modules may be internal app modules where incomplete exposure is intentional. Libraries are held to a stricter standard because they are explicitly designed for external consumption.

#### Proof ownership across library boundaries

Only the module that declares `fact F` can produce values carrying `F` (via `check`, `establish`, or `auth`). This is called **proof minting**, and the right belongs solely to the declaring module.

Other modules that import `F` can:
- Require `F` in function parameter types: `fn f(x: T ::: F x) -> ...`
- Pass `F`-carrying values between functions
- Re-export `F` in their own `exposing [...]`

They cannot produce new `F`-carrying values. Attempting to return `ok x ::: F x` in a module that does not own `F` is a compile-time error (P001: proof ownership violation).

```tesl
# email-lib.tesl
library EmailLib exposing [IsValidEmail, checkEmail]
fact IsValidEmail (addr: String)
check checkEmail(addr: String) -> addr: String ::: IsValidEmail addr =
  if String.contains addr "@" then
    ok addr ::: IsValidEmail addr
  else
    fail 400 "not a valid email"

# my-handler.tesl — CORRECT usage
import EmailLib exposing [IsValidEmail, checkEmail]

fn sendTo(addr: String ::: IsValidEmail addr) -> String =
  "sending to ${addr}"

fn handle(rawAddr: String) -> String =
  let addr = check checkEmail rawAddr   # proof minted here, by EmailLib's check
  sendTo addr                           # proof flows through — accepted

# my-handler.tesl — WRONG: trying to forge the proof
fn forge(addr: String) -> addr: String ::: IsValidEmail addr =
  ok addr ::: IsValidEmail addr         # P001: my-handler does not own IsValidEmail
```

#### Re-export support

A library can re-export names from its imports by listing them in `exposing [...]`. This supports the **facade pattern**: a library imports from multiple internal modules and presents a unified API surface.

```tesl
# username-validation.tesl
library UsernameValidation exposing [IsValidUsername, checkUsername]
fact IsValidUsername (name: String)
check checkUsername(name: String) -> name: String ::: IsValidUsername name = ...

# email-validation.tesl
library EmailValidation exposing [IsValidEmail, checkEmail]
fact IsValidEmail (addr: String)
check checkEmail(addr: String) -> addr: String ::: IsValidEmail addr = ...

# user-lib.tesl — FACADE
library UserLib exposing [
  IsValidUsername, checkUsername,   # re-exported from UsernameValidation
  IsValidEmail,    checkEmail,      # re-exported from EmailValidation
  UserProfile,     makeUserProfile, # declared in UserLib
]

import UsernameValidation exposing [IsValidUsername, checkUsername]
import EmailValidation exposing [IsValidEmail, checkEmail]

record UserProfile {
  username: String ::: IsValidUsername username
  email:    String ::: IsValidEmail email
}

fn makeUserProfile(rawName: String, rawEmail: String) -> UserProfile =
  let name = check checkUsername rawName
  let addr = check checkEmail rawEmail
  UserProfile { username: name email: addr }
```

Consumers import only from `UserLib` and see a single, stable API. The internal split between `UsernameValidation` and `EmailValidation` is an implementation detail.

**Re-export does not transfer minting rights.** `UserLib` re-exports `IsValidEmail` from `EmailValidation`, but `UserLib` cannot produce new `IsValidEmail` values. `EmailValidation` retains sole minting authority.

**Signature completeness applies to re-exports.** If `UserLib` re-exports `checkUsername`, then `IsValidUsername` must also appear in `UserLib`'s `exposing [...]` — even if both were originally declared in `UsernameValidation`. The compiler checks this.

## 11. Surface grammar for top-level declarations
### 11.1 Overview
**Accepted design.**

```text
<module-file> ::= ["#lang tesl"] <module-header> { <import-line> } { <top-level-form> }

<top-level-form> ::= <capability-decl>
                   | <fact-decl>
                   | <type-decl>
                   | <record-decl>
                   | <entity-decl>
                   | <database-decl>
                   | <binding-decl>
                   | <function-decl>
                   | <capture-decl>
                   | <api-decl>
                   | <server-decl>
                   | <main-block>
                   | <test-block>
                   | <queue-decl>
                   | <channel-decl>
                   | <workers-decl>
                   | <cache-decl>
                   | <email-decl>
```

`const` is not part of the intended public language. Top-level immutability is already the default.

### 11.14 Test blocks
**Accepted design, Implemented.**

```text
<test-block> ::= "test" <string> [ "with" <integer> "runs" ] "{" { <test-statement> } "}"

<test-statement> ::= "expect" <expr> <comparison-op> <expr>
                   | "expect" <expr>
                   | "expectFail" <expr>
                   | "property" <string> "(" <prop-params> ")" "{" <expr> "}"
                   | "let" <identifier> "=" <expr>
                   | <expr>

<prop-params> ::= <prop-param> { "," <prop-param> }
<prop-param> ::= <identifier> ":" <type> [ "where" <expr> ]
```

Test blocks are first-class top-level declarations. They compile to Racket `module+ test` submodules using rackunit.

**`expect`** checks equality, comparison, or truthiness. **`expectFail`** asserts that an expression returns a check-fail or raises an exception.

**`let` with proof annotation.** Test block `let` bindings support an optional type annotation with proof declaration:

```tesl
let result: Int ::: IsPositive result && IsSmall result = makeValue p
```

The compiler validates that the function on the right-hand side actually returns the declared proof predicates. If `makeValue` does not return `IsSmall`, it is a compile-time error — the annotation documents the expected proof shape and is statically verified:

```tesl
# ERROR — makeWithAdminCargo returns IsPositive and IsAdmin, not IsSmall
test "type-checked binding" {
  let result: Int ::: IsPositive result && IsSmall = makeWithAdminCargo p admin
}
```

This prevents accidentally documenting the wrong proof shape in a test binding. Use `:::` (not `?`) in test let annotations — `?` is a return-type operator, not a binding-type operator.

**`property`** runs randomized property-based tests. Parameters are typed and random values are generated from the type. An optional `where` clause filters generated values. The run count defaults to 100 and can be overridden with `with N runs` on the test header.

```tesl
test "add is commutative" with 50 runs {
  expect add 3 7 == 10
  expectFail positive(-5)
  property "commutative" (x: Int, y: Int) { add x y == add y x }
  property "positive > 0" (n: Int where n > 0 && n < 10000) { n > 0 }
}
```

Run tests with `thsl --test file.tesl`.

#### API tests

`api-test` blocks run end-to-end requests against a compiled server value from within Tesl itself.

```text
<api-test-block> ::= "api-test" <string> "for" <identifier> [ "requires" <capability-list> ] "{" [ <seed-block> ] { <api-test-statement> } "}"
<seed-block>     ::= "seed" "{" { <seed-statement> } "}"
<seed-statement> ::= "insert" <identifier> "{" { <field-init> } "}"
                   | "let" <identifier> "=" <expr>
                   | <expr>
<api-test-statement> ::= "expect" <expr> <comparison-op> <expr>
                       | "expect" <expr>
                       | "let" <identifier> "=" <expr>
                       | <expr>
<api-request-expr> ::= "get" <string> [ "cookie" <string> ] [ "headers" <json-object-literal> ]
                     | "post" <string> [ "cookie" <string> ] [ "headers" <json-object-literal> ] [ "body" <json-literal> ]
                     | "put" <string> [ "cookie" <string> ] [ "headers" <json-object-literal> ] [ "body" <json-literal> ]
                     | "delete" <string> [ "cookie" <string> ] [ "headers" <json-object-literal> ]
<api-stream-expr> ::= "subscribe" <string> [ "cookie" <string> ] [ "headers" <json-object-literal> ]
                    | "collect" <identifier> [ "count" <integer> ] [ "until" <json-literal> ] [ "timeout" <duration-literal> ]
```

Files using `api-test` must import `Tesl.ApiTest`. The compiler emits a targeted error if an `api-test` block is present without that import.

Each `api-test` block runs with a fresh in-memory database by default. Optional `seed {}` setup runs before the HTTP boundary and uses the ordinary `insert` syntax, so entity field names and types are still compile-time checked.

Request expressions return the compiler-known type `HttpResponse` with fields `status`, `body`, and `headers`. `body` is a `JsonValue`, and `Tesl.ApiTest` exposes helper functions such as `statusOk`, `jsonString`, `hasLength`, `fieldAt`, `subscribe`, `processNextJob`, and `processNextDeadJob` for asserting on raw JSON, SSE streams, and queue workers.

When `collect` uses `count` or `until`, a `timeout` clause is required. Queue helpers (`processNextJob`, `processNextDeadJob`, `drainQueue`, `pendingJobCount`) run workers synchronously during the test, making HTTP → queue → SSE flows deterministic.

#### Load Tests

`load-test` blocks run performance/throughput tests against a compiled server using an open
workload model (fixed arrival rate). They reuse the same `seed` and request syntax as
`api-test` blocks.

```text
<load-test-block>     ::= "load-test" <string> "for" <identifier>
                           "rate" <integer> "rps"
                           "duration" <integer> "s"
                           [ "baseline" <string> ]
                           [ "requires" <capability-list> ]
                           "{" [ <seed-block> ] <api-request-expr> { <load-test-assert> } "}"
<load-test-assert>    ::= "assert" <load-metric> <comparison-op> <number> [ <unit> ]
                        | "assert" "regressionVsBaseline" <load-metric> "<" <number>
<load-metric>         ::= "p50" | "p95" | "p99" | "p99.9" | "errorRate" | "throughput"
<unit>                ::= "ms" | "rps"
```

Load tests use coordinated-omission-aware latency measurement: requests are scheduled on a
fixed wall-clock interval and latency is measured from scheduled send time. A warm-up phase
runs until p99 stabilises, then the measurement phase runs for the specified `duration`.

Assertions check histogram percentiles, error rate, and throughput after the run.
`regressionVsBaseline` compares against stored baselines in `.tesl-baselines/`.

```tesl
load-test "list books throughput" for BookServer
  rate 100rps
  duration 10s
  requires [dbRead] {
  get "/books"

  assert p99 < 200ms
  assert p95 < 80ms
  assert errorRate < 0.01
  assert throughput > 80rps
}
```

#### Doctests

Doctests are test examples embedded in comments directly above a function declaration:

```tesl
#> double 5
#= 10
#> double 0
#= 0
#> property "always even" (n: Int) { double n % 2 == 0 }
fn double(n: Int) -> Int =
  n + n
```

`#>` introduces a test expression (or a property declaration) and `#=` specifies the expected result. Doctests are automatically extracted and compiled as test cases when running `--test`. Property-based doctests use the same `property` syntax as test blocks.

#### Custom generators with `via`

Property parameters can specify a custom generator function with `via`:

```tesl
import Tesl.Random exposing [random, randomInt]
capability testCap implies random

fn genSmallPositive() -> Int
  requires [random] =
  1 + randomInt(100)

test "custom gen" with 50 runs {
  property "small values" (n: Int via genSmallPositive) { n > 0 && n <= 100 }
}
```

The `via` function is called once per property run to produce a value. This allows domain-specific generators tailored to the test scenario. Custom generators that use `randomInt` must declare the `random` capability.

#### Record generators

Property tests automatically generate random values for record types by constructing the record with random field values. For proof-bearing record fields, the generator fabricates the required proof so the record constructor succeeds.

### 11.15 Queue declarations
**Accepted design, Implemented.**

```text
<queue-decl> ::= "queue" <identifier> "{"
                   "database" <identifier>
                   "jobs" "[" <identifier> { "," <identifier> } "]"
                   [ "retry" "{" <retry-options> "}" ]
                 "}"

<retry-options> ::= { <retry-option> }
<retry-option>  ::= "maxAttempts" ":" <integer>
                  | "backoff"     ":" ( "exponential" | "fixed" )
                  | "initialDelay" ":" <integer>
```

A `queue` declaration creates a background job queue backed by the named `database`. The `jobs` list names the `record` types that can be enqueued in this queue. The compiler generates the `tesl_jobs` table schema automatically.

`retry` configures how failed worker jobs are retried. `maxAttempts: 1` (the default) means no retries. With `backoff: exponential` and `initialDelay: N` the delay between retries doubles: N, 2N, 4N, … seconds. With `backoff: fixed` the delay is always `initialDelay`.

Each queue declaration implicitly pairs with application-level capabilities following the same pattern as databases:

```tesl
queue EmailQueue {
  database MainDatabase
  jobs     [SendEmail, GeneratePDF]
  retry {
    maxAttempts:  3
    backoff:      exponential
    initialDelay: 60
  }
}
capability emailWrite implies queueWrite
capability emailRead  implies queueRead
```

Built-in `queueRead` and `queueWrite` capabilities come from `Tesl.Queue` (analogous to `dbRead`/`dbWrite` from `Tesl.DB`).

### 11.16 Channel declarations
**Accepted design, Implemented.**

```text
<channel-decl> ::= "channel" <identifier> "(" <binding> { "," <binding> } ")" "{"
                     "database" <identifier>
                     "payload"  <identifier>
                   "}"
```

A `channel` declaration creates a typed pub/sub channel backed by the named database (via the outbox pattern). The key parameters follow the same binding syntax as function parameters, including proof annotations. The `payload` type must be an ADT — all event variants must be declared before the channel.

```tesl
type UserEvent
  = ProfileUpdated bio: String
  | AvatarChanged  url: String
  | AccountDeleted

channel UserEvents(userId: String ::: UserId userId) {
  database MainDatabase
  payload  UserEvent
}
```

The `tesl_pubsub_outbox` table is created automatically alongside entity tables. Events published inside `with transaction` are written to the outbox atomically, and in-memory listeners are called after commit. Events published outside a transaction call listeners directly (at-most-once; a linter warning is planned).

The SSE fan-out is driven by in-memory listener callbacks. A PostgreSQL LISTEN connection for multi-process fan-out runs automatically when `serve` detects SSE endpoints and a PostgreSQL database is active.

Built-in `pubsub` capability comes from `Tesl.Queue`.

### 11.17 Worker declarations
**Accepted design, Implemented.**

`worker` is a new function kind (alongside `fn`, `check`, `establish`, `auth`, `handler`) for background job processors:

```text
<function-kind> ::= "check" | "establish" | "fn" | "auth" | "handler" | "worker"
```

Worker functions receive a proof-bearing job value (`FromQueue` proof, analogous to `FromDb`), perform their work, and either complete normally (job marked done) or `fail` (job marked failed, eligible for retry):

```tesl
worker sendEmailWorker(job: SendEmail ::: FromQueue (Id == jobId) job)
  requires [smtpSend] =
  sendMail(job.to, job.subject, job.body)
```

`FromQueue (Id == jobId) job` follows the same 2-arg pattern as `FromDb (Id == pk) entity` — both the job's primary key subject and the job entity subject are in the proof.

A `workers` declaration binds worker functions to job types, mirroring `server` for HTTP handlers:

```text
<workers-decl> ::= "workers" <identifier> "for" <identifier> "{"
                     { <identifier> "=" <identifier> }
                   "}"
```

```tesl
workers EmailWorkers for EmailQueue {
  SendEmail   = sendEmailWorker
  GeneratePDF = generatePdfWorker
}
```

### 11.2 Top-level immutable bindings
**Accepted design.**

```text
<binding-decl> ::= <identifier> "=" <expr>
```

### 11.3 Capabilities
**Accepted design, Implemented.**

```text
<capability-decl> ::= "capability" <identifier> [ "implies" <identifier> { "," <identifier> } ]
```

### 11.4 Bindings and return specs
**Accepted design, Implemented.**

```text
<binding> ::= <identifier> ":" <gdp-expr> [ ":::" <gdp-expr> ]

<return-spec> ::= "exists" <binding> "=>" <return-spec>
                | <binding>
                | <gdp-expr> " ? " <gdp-expr> ":::" <gdp-expr>   -- new canonical form
                | <gdp-expr> " ? " <gdp-expr>                    -- new canonical form, no other proofs
                | "?" <gdp-expr> ":::" <gdp-expr>                -- legacy form (still accepted)
                | "?" <gdp-expr>                                  -- legacy form (still accepted)
                | <gdp-expr> ":::" <gdp-expr>
                | <gdp-expr>
```

Interpretation:

- a plain return spec such as `Int` means an unannotated return type;
- an attached return spec such as `Int ::: Positive x` means an anonymous returned value with proof;
- a binding return spec such as `x: Int ::: Positive x` means the return is conceptually a named value whose proof may refer to that binder;
- a **named-pack** return spec such as `Todo ? FromDb (Id == id)` means the returned entity is automatically named by the caller's `let` binder (see section 7.13); the entity-append rule appends `_entity` to every leaf predicate in the `?` group;
- a **ForAll** return spec such as `List Note ::: ForAll (FromDb (AuthorId == user))` means every element of the returned list satisfies the given proof predicate (see section 16.9); compile-time only with zero runtime overhead;
- an existential return spec packages a witness and then a body return spec.

Note: the current `.tesl` surface uses lowercase `exists ... => ...`. The elaborated Racket core currently uses `Exists`.

### 11.4b Fact (predicate) declarations
**Accepted design, Implemented.**

```text
<fact-decl> ::= "fact" <UpperIdentifier> { "(" <binding-list> ")" }

<binding-list> ::= <binding> { "," <binding> }
<binding>      ::= <identifier> ":" <type-expr>
```

A `fact` declaration introduces a named GDP predicate with zero or more typed parameters. Fact declarations are **phantom** — they have no runtime representation, only compile-time significance for the proof system.

**Single-parameter fact** (most common):
```tesl
fact IsPositive (n: Int)
fact IsTrimmed  (s: String)
```

**Multi-parameter facts** relate several values:
```tesl
fact InRange (lo: Int) (hi: Int) (n: Int)
fact Ordered (lo: Int) (hi: Int)
fact HasPrefix (prefix: String) (s: String)
```

Each parameter group may be written as a separate `(name: Type)` pair, or comma-separated inside a single group:
```tesl
fact InRange (lo: Int, hi: Int, n: Int)   # equivalent to three separate groups
```

The predicate name uses PascalCase by convention. Lowercase fact names are not enforced as errors but are unusual.

**Using a multi-param fact in a `check` function.** The return binding name identifies which parameter is the validated value; the other parameters are constraints from the calling context:

```tesl
fact InRange (lo: Int) (hi: Int) (n: Int)

check isInRange(lo: Int, hi: Int, n: Int) -> n: Int ::: InRange lo hi n =
  if lo <= n && n <= hi then
    ok n ::: InRange lo hi n
  else
    fail 400 "out of range"
```

**Consuming multi-param proofs.** A function that requires a multi-param proof must list all parameters in the `:::` annotation. The compiler tracks proof subjects across `let` bindings so that proof evidence flows correctly from check calls to proof-requiring functions:

```tesl
fn processInRange(lo: Int, hi: Int, n: Int ::: InRange lo hi n) -> String = "ok"

fn validate(lo: Int, hi: Int, raw: Int) -> String =
  let validated = isInRange lo hi raw   # validated carries InRange lo hi raw
  processInRange lo hi validated        # proof passes: InRange lo hi raw matches InRange lo hi n
```

Passing `raw` (without the proof) directly to `processInRange` is a compile-time error.

### 11.5 Function-like declarations
**Accepted design, Implemented with some current syntax limits.**

```text
<function-decl> ::= <function-kind> <identifier> "(" [ <binding> { "," <binding> } ] ")"
                    "->" <return-spec>
                    [ "requires" <capability-list> ]
                    "="
                    <body>

<function-kind> ::= "check" | "establish" | "fn" | "auth" | "handler"
<capability-list> ::= "[" [ <identifier> { "," <identifier> } ] "]"
```

Current lowering:

- `check` lowers to `define-checker`;
- `auth` lowers to `define-auther`;
- `fn` lowers to `define/pow`;
- `establish` lowers to `define-trusted`. It is the explicit fact-producing boundary for unconditional proofs. The body returns proof constructors directly (e.g. `IsPositive n`), not `ok` expressions. `ok` and `fail` are compile-time errors inside `establish`.
- `handler` lowers to `define-handler`.

The `establish`, `check`, and `auth` kinds establish **proof predicate ownership** for every predicate named in their return type. Each owned predicate is added to the module's local namespace and may be included in `exposing [...]` to make it importable by other modules:

```tesl
module Ports exposing [isValidPort, ValidPort]

check isValidPort(p: Int) -> p: Int ::: ValidPort p =
  if 1 <= p && p <= 65535 then ok p ::: ValidPort p
  else fail 400 "port out of range"
```

A consuming module names the predicate explicitly in its imports before using it in its own annotations:

```tesl
import Ports exposing [isValidPort, ValidPort]

fn connectTo(host: String, port: Int ::: ValidPort port) -> Int = ...
```

Predicates that are only used within their declaring module do not need to be exported.

**`fn` proof passthrough.** A `fn` may declare a proof-carrying return type (`name: T ::: P`) if and only if `name` also appears as a parameter with that proof annotation — the function is merely passing through a proof it received. A `fn` may not declare a proof-carrying return type for a binding that was not proof-annotated on input; that would fabricate a proof without going through a validation boundary.

```tesl
# VALID — proof passthrough: n carries IsPositive n on input
fn passthrough(n: Int ::: IsPositive n) -> n: Int ::: IsPositive n = n

# REJECTED — n has no proof on input; fn cannot mint IsPositive n
fn forgery(n: Int) -> n: Int ::: IsPositive n =
  let pf = proveAny n
  n ::: pf
```

For returning proof-carrying values where the proof was produced inside the function body, use `check`, `establish`, or `auth` — the three validated proof-introduction boundaries.

**Named-pack return (`?` operator).** When a function or handler returns a value with a GDP proof, the `?` return spec automatically assigns the value's GDP subject from the caller's `let` binder (see section 7.13). This is the idiomatic return form for SQL-layer functions and proof-annotated value returns:

```tesl
handler getTodo(requestUser: User ::: Authenticated requestUser, todoId: String ::: TodoId todoId)
  -> Todo ? FromDb (Id == todoId)
  requires [dbRead] =
  ...

-- Compound entity proof: both Positive and Small get _entity appended
fn makeValue(n: Int ::: Positive n && Small n) -> Int ? Positive && Small =
  n

-- Entity proof + independent proof
fn make(n: Int ::: Positive n, user: String ::: Admin user) -> Int ? Positive ::: Admin user =
  n ::: detachFact(user)
```

The elaborated Racket uses `(? Todo _entity ::: (FromDb (Id == todoId) _entity))`. Both a 1-argument `FromDb` fact (for backward compat) and a 2-argument fact (with the entity subject) are attached to the returned value by the SQL layer.

### 11.6 Type declarations
**Accepted design, Implemented.**

```text
<type-decl> ::= <type-alias-decl> | <adt-decl>

<type-alias-decl> ::= "type" <identifier> "=" <gdp-expr>

<adt-decl> ::= "type" <identifier>
               <adt-variant-line>+

<adt-variant-line> ::= ("=" | "|") <identifier> { <adt-field> }
<adt-field> ::= <binding>
              | <gdp-expr> [ ":::" <gdp-expr> ]
```

**Important**: The distinction between type alias and ADT is determined by whether the `=` appears on the same line as the type name or on the next line.

- **Type alias** (newtype): `=` on the same line — `type UserId = String`
- **ADT**: `=` on the next line with the first variant — `type Color` then `  = Red | Green | Blue`

Single-line `type Color = Red | Green | Blue` is parsed as a type alias where the type text is `Red | Green | Blue`, **not** an ADT. Always declare ADTs multi-line:

```tesl
# CORRECT — multi-line ADT
type Color
  = Red
  | Green
  | Blue

# WRONG — parsed as type alias "Color = Red | Green | Blue"
type Color = Red | Green | Blue
```

> **Design note — constructor names must differ from the type name.** A constructor cannot share its name with the type it belongs to. `type Status = Status | Other` is invalid: the constructor `Status` is ambiguous with the type `Status`. Use a distinct name — for example, `type Status = Active | Other`. This is an explicit design choice to prevent collisions between the type namespace and the value constructor namespace and to make it clearer for a human reader what is referenced.

**Parameterized ADTs.** An ADT may declare type parameters by listing lowercase identifiers between the type name and `=`. Parameters may then be used as field types in variants:

```text
<adt-decl> ::= "type" <identifier> { <type-param> }
               <adt-variant-line>+

<type-param> ::= lowercase-identifier
```

```tesl
# Either with two type parameters
type Either a b
  = Left  value:a
  | Right value:b

# A simple container with one parameter
type Box a
  = Box value:a

# Optional value (standard library pattern)
type Option a
  = Some value:a
  | None

# Tree structure
type Tree a
  = Leaf
  | Node left:(Tree a) value:a right:(Tree a)
```

Type parameters are resolved structurally at compile time using Hindley-Milner inference. No explicit type arguments are required at call sites — the compiler infers them from usage:

```tesl
fn wrapInt(n: Int) -> Box Int =
  Box(n)

fn unwrap(b: Box Int) -> Int =
  case b of
    Box value -> value

fn mapEither(e: Either Int String, f: Int -> Int) -> Either Int String =
  case e of
    Left  value -> Left(f(value))
    Right value -> Right(value)
```

The standard library uses `Either`, `Maybe`, and `Result` as parameterized ADTs. User code may define its own parameterized ADTs with any number of parameters.

Type aliases are **nominal newtypes**, not transparent aliases. `type UserId = String` creates a distinct runtime type. A value of type `String` cannot be passed where `UserId` is expected; the two types are incompatible even though both wrap `String`.

**Database auto-mapping**: newtypes that wrap a built-in DB type inherit its column type automatically. For example, `PosixMillis` wraps `Integer` which maps to `BIGINT`, so `createdAt: PosixMillis` needs no `@db` annotation. Any user-defined newtype wrapping a built-in type benefits from the same rule.

To construct a newtype value, call the type name as a constructor:
```tesl
let id = UserId("user_abc")      # constructs a UserId
```

To access the wrapped value, use the `.value` field accessor:
```tesl
fn formatId(id: UserId) -> String =
  String.length(id.value)        # extracts the inner String
```
The structural checker treats `.value` as the explicit unwrap for nominal newtypes. Other dotted field access is checked against declared record, entity, or ADT-variant fields; an unknown field or a field access on a non-record/non-entity/non-variant value is a compile-time error.

At JSON/HTTP boundaries, newtypes are decoded and encoded transparently: the JSON representation is the same as the base type.

For ADT fields, explicit labels are allowed via ordinary binding syntax. If a field is written only as a type expression, the current implementation generates labels such as `value`, `value2`, and so on.

### 11.7 Records
**Accepted design, Implemented.**

```text
<record-decl> ::= "record" <identifier> "{" { <record-field> } "}"
                   [ ":::" <gdp-expr> [ "via" <dotted-identifier> ] ]
<record-field> ::= <identifier> ":" <gdp-expr>
                   [ ":::" <gdp-expr> ]
```

Record fields may carry proof annotations documenting what proof a field value must carry. `via checker` on individual record fields is **not** supported — field validation at HTTP boundaries is handled by codec blocks (see §11.12).

**Field proof propagation on read.** When a record field carries a proof annotation (e.g. `title: String ::: TitleSafe title`), the compiler enforces two guarantees:

1. **Construction** — building the record requires the field value to carry the declared proof. A `SafeItem { title: s }` is rejected unless `s` carries `TitleSafe`.
2. **Consumption** — reading the field back (e.g. `item.title`) automatically propagates the declared proof. A function requiring `String ::: TitleSafe t` accepts `item.title` directly, without re-checking:

```tesl
record SafeItem { title: String ::: TitleSafe title }
fn requiresSafe(t: String ::: TitleSafe t) -> String = t
fn readField(item: SafeItem) -> String = requiresSafe item.title  -- proof flows through
```

This implements the "validate once, trust everywhere" thesis for record-heavy code: once a value is stored in a proof-annotated field, the proof is permanently associated with the field and available to all consumers.

Records may also carry a **record-level proof** — a compile-time annotation of a cross-field invariant:

```tesl
record OrderLine {
  price:    Int ::: IsPositive price
  quantity: Int ::: IsPositive quantity
} ::: PriceExceedsQuantity price quantity
```

Without a `via` clause, the `:::` after the closing `}` is a **zero-cost, compile-time-only annotation**. No runtime check is inserted. Instead, the compiler enforces the **ghost witness pattern**: any site that constructs the record must supply a proof variable as an explicit ghost witness:

```tesl
fn makeOrderLine(price: Int ::: IsPositive price,
                 quantity: Int ::: IsPositive quantity,
                 recordProof: Fact (PriceExceedsQuantity price quantity)) -> OrderLine =
  { price: price, quantity: quantity } ::: recordProof
```

The `{ ... } ::: witnessVar` syntax on a record literal is the ghost witness. It compiles to the plain record constructor — no `attach-proof` call, no allocation. Without it, the compiler rejects the construction with:

```
constructing `OrderLine` requires a ghost witness for its cross-field invariant
`PriceExceedsQuantity price quantity`; use `{ ... } ::: proofVar`
```

**Compile-time validation of the ghost witness.** The compiler does not merely require that *some* proof is supplied — it validates that the witness carries the *correct* proof for the *exact* values in the record literal:

1. **Predicate check** — the witness proof must carry the same predicate declared on the record. Passing `(detachFact p)` (which carries `IsPositive p`) where `PriceExceedsQuantity price quantity` is required is a compile error:

   ```
   ghost witness for `OrderLine` carries the wrong proof predicate
     expected a proof of `PriceExceedsQuantity`
     got: `(IsPositive n)`
   ```

2. **Subject check** — the proof subjects in the witness must be the same identity as the values used in the record literal. A proof obtained for `(p_intruder, q)` cannot be used for `{ price: p, quantity: q }` even though both use the `PriceExceedsQuantity` predicate:

   ```
   ghost witness for `OrderLine` carries the wrong proof
     required: `(PriceExceedsQuantity p q)`
     got:      `(PriceExceedsQuantity p_intruder q)`
     the ghost witness must be the cross-field proof obtained for the EXACT
     values that appear in the record literal
   ```

This ensures that the GDP guarantee holds end-to-end: a proof `PriceExceedsQuantity p q` is valid only for the specific binding of `p` and `q` that produced it, and cannot be reused for any other pair of values — even values that happen to satisfy the same predicate independently.

The optional `via checker` suffix on a record declaration (not a field) registers a **runtime invariant** checked at construction time. This is useful for property-based test generators, which call the checker to fabricate valid records. For application code construction, the ghost witness pattern is still required regardless of whether `via` is present.

For HTTP input, the cross-field check belongs in the codec block:

```tesl
codec OrderLine {
  toJson_forbidden
  fromJson [
    {
      price    <- "price"    with_codec intCodec via checkPositiveInt
      quantity <- "quantity" with_codec intCodec via checkPositiveInt
    } via checkPriceExceedsQuantity
  ]
}
```

The `} via checker` suffix on a codec block runs the cross-field checker after all individual fields pass, using the decoded raw values in field declaration order. This is the **only** place where untrusted external input crosses the validation boundary.

For a single field that must satisfy multiple proofs, use the parenthesized `&&` form:

```tesl
fromJson [
  {
    title <- "title" with_codec stringCodec via (isSafeTitle && isShort && containsA)
  }
]
```

The `&&` expression applies checkers sequentially — the second runs only if the first succeeds, and so on. Chaining with multiple separate `via` keywords (e.g., `via isSafeTitle via isShort`) is not supported; use the parenthesized form instead.

This design is theoretically sound because:
- Field-level proofs are about individual field subjects (single-field GDP evidence).
- Record-level proofs are about the *relationship* between field subjects (cross-field GDP evidence).
- The ghost witness pattern (GDP) shifts all fallibility to proof *acquisition* — the construction function itself is total.
- HTTP boundaries are validated by the codec; application-internal construction is validated by requiring a pre-acquired proof as a ghost witness.

**Explicit HTTP wire adapters.** An endpoint may name a different wire type with `body req: Domain from Wire via decodeWire` and `response Wire via encodeWire`. These adapters are part of the static boundary contract, not an escape hatch. The compiler requires:
- `decodeWire` to be a declared Tesl function with exactly one raw `Wire` argument and a `Domain` return; if the endpoint body declares a proof, `decodeWire` must establish that proof itself unless the endpoint uses `body ... via (...)` to establish it at the boundary.
- `encodeWire` to be a declared Tesl function with exactly one raw handler-result argument and a `Wire` return.
- `Wire` to have the appropriate visible codec (`fromJson` for request bodies, `toJson` for responses), because `Wire` is still the type that crosses the HTTP boundary.

**`adtJson` shorthand for ADT types.** When a codec is needed solely to declare the standard `{"tag": "ConstructorName"}` JSON encoding for an ADT, use the `adtJson` shorthand:

```tesl
type OrgRole = RoleAdmin | RoleMember | RoleViewer

codec OrgRole {
  adtJson     # expands to: toJson {"tag": constructorName}
              #              fromJson {"tag": constructorName}
}
```

`adtJson` is equivalent to declaring both `toJson` and `fromJson` blocks that encode/decode the ADT using the standard runtime format. It cannot be combined with separate `toJson` or `fromJson` blocks in the same codec declaration.

Once `codec OrgRole { adtJson }` is declared, other codecs can reference it with `with_codec OrgRole`. The same `with_codec TypeName` form also works for non-ADT types when a visible `codec TypeName { ... }` exists:

```tesl
codec InviteMemberRequest {
  toJson_forbidden
  fromJson [
    {
      email <- "email" with_codec stringCodec
      role  <- "role"  with_codec OrgRole    # valid because OrgRole has a visible codec
    }
  ]
}
```

The compiler enforces that:
1. `with_codec OrgRole` is only used on fields declared as type `OrgRole` (type mismatch is a compile error).
2. `OrgRole` has a visible codec in the current module/import closure (for `fromJson`, the referenced codec must provide a decoder).
3. Builtin codecs (`stringCodec`, `intCodec`, etc.) must match the field's declared type (e.g., `with_codec stringCodec` on an `OrgRole` field is a compile error).

### 11.8 Entities
**Accepted design, Implemented but still evolving.**

```text
<entity-decl> ::= "entity" <identifier>
                  "table" <string>
                  "primaryKey" <identifier>
                  "{" { <entity-field> } "}"

<entity-field> ::= <identifier> ":" <gdp-expr>
                   [ ":::" <simple-field-fact> ]
                   [ "@db(" <identifier> ")" ]
```

Entity field proof annotations are intentionally restricted. They must be simple single-field facts of the form `ProofName field`. Entity fields do not currently support `via` checkers.

**`Maybe T` fields.** An entity field declared as `Maybe T` maps to a nullable SQL column of the underlying type. At runtime `Nothing` ↔ SQL `NULL` and `Something v` ↔ the column value. The `@db(...)` annotation applies to the inner type `T` as usual.

```tesl
entity Issue table "kanel_issues" primaryKey id {
  id:         String
  assigneeId: Maybe String   # nullable TEXT — NULL means unassigned
  dueAt:      Maybe PosixMillis  # nullable BIGINT
}
```

In queries, `Maybe` fields require a `case` expression or the `isAssignedTo` / helper-function pattern; they cannot be compared directly with `==` to a non-Maybe value.

**Column type mapping summary:**

| Tesl field type | SQL column type | Nullable? |
|---|---|---|
| `String` | `TEXT` | NOT NULL |
| `Int` | `BIGINT` | NOT NULL |
| `Bool` | `BOOLEAN` | NOT NULL |
| `PosixMillis` | `BIGINT` | NOT NULL |
| Any ADT | `JSONB` | NOT NULL |
| `Maybe T` | column type of `T` | NULL |

### 11.9 Databases
**Accepted design, Implemented with a Phase-1 backend restriction.**

```text
<database-decl> ::= "database" <identifier> "{" 
                      "backend" "postgres"
                      [ "schema" <string> ]
                      "entities" <capability-list>
                      "postgres" "{" { <postgres-setting> } "}"
                    "}"
```

Only `backend postgres` is currently supported.

### 11.10 Capture declarations
**Accepted design, Implemented.**

```text
<capture-decl> ::= "capture" <identifier> ":" <binding>
                   "using" <codec-name>
                   [ "via" <checker-expr> ]

<codec-name>   ::= <identifier>

<checker-expr> ::= <identifier>
                 | "(" <identifier> { "&&" <identifier> } ")"
```

The `using` clause names the JSON codec used to parse the URL segment — e.g., `stringCodec` for
string segments, `intCodec` for integer segments. The optional `via` clause applies a `check`
function (or a parenthesized `&&`-list of one check function) to validate and attach a proof to
the captured value.

Only one checker is supported per capture. For complex validation, compose checks into a single
`check` function.

This creates a reusable capture kind that can later be referenced from API declarations.

### 11.11 API declarations
**Accepted design, Implemented**

```text
<api-decl> ::= "api" <identifier> "{" { <api-endpoint> } "}"

<api-endpoint> ::= <http-method> <string>
                   { <api-endpoint-line> }

<http-method> ::= "get" | "post" | "put" | "delete"

<api-endpoint-line> ::= <auth-line>
                      | <body-line>
                      | <response-line>
                      | <capture-line>
                      | <return-line>

<auth-line> ::= "auth" <binding> "via" <identifier>
<capture-line> ::= "capture" <binding> "via" <identifier>
<body-line> ::= "body" <binding> [ "from" <gdp-expr> "via" <identifier> ]
<response-line> ::= "response" <gdp-expr> [ "via" <identifier> ]
<return-line> ::= "->" <return-spec>
```

Endpoint headers use path strings. Capture segments are written in the path with a leading `:` and then described by `capture ... via ...` lines in declaration order.

SSE (Server-Sent Events) endpoints are declared with `sse` instead of an HTTP method:
**Accepted design, Implemented.**

```text
<api-endpoint> ::= ...existing...
                 | "sse" <string>
                     { <api-endpoint-line> }
                     { <subscribe-line> }

<subscribe-line> ::= "subscribe" <identifier> "(" [ <expr> { "," <expr> } ] ")"
```

An SSE endpoint authenticates the client, captures URL parameters, then subscribes the long-lived HTTP connection to one or more typed channels. Subscriptions are declarative — no handler function is needed in the `server` declaration; routing is automatic.

```tesl
sse "/events/user/:userId"
  auth    session: Session ::: Authenticated session && ChannelOwner session userId
          via sessionOwnerAuth
  capture userId: String ::: UserId userId via userIdCapture
  subscribe UserEvents(userId)
```

Multiple `subscribe` lines subscribe the connection to multiple channels simultaneously. The client receives a discriminated JSON SSE `data:` line: `data: {"channel":"ChannelName","payload":{"tag":"VariantName",...}}`.

SSE runs on the **same TCP port** as the HTTP API server. No separate server or reverse proxy configuration is needed. The browser uses the native `EventSource` API, which auto-reconnects on disconnection.

**Client-side usage:**

```javascript
const evts = new EventSource('/events/user/usr_123');
evts.onmessage = (e) => {
  const { channel, payload } = JSON.parse(e.data);
  // dispatch on channel and payload.tag
};
// Reconnects automatically — no manual reconnect code needed
```

### 11.12 Servers
**Accepted design, Implemented.**

```text
<server-decl> ::= "server" <identifier> "for" <identifier> "{" { <server-binding> } "}"
<server-binding> ::= <identifier> "=" <identifier>
```

### 11.13 Main blocks
**Accepted design, Implemented.**

```text
<main-block> ::= "main" [ "with" "capabilities" <capability-list> ] "{" <body> "}"
```

The `with capabilities [...]` declaration on `main` lists every capability the application uses.  Two rules are enforced at compile time:

- **Pure `main {}`** — a `main` block with no capability declaration must not reference any capabilities anywhere in its body.  Any `with capabilities [...]` block, `serve ... with capabilities [non-empty]`, or `startWorkers ... with capabilities [non-empty]` inside is a compile error.  This ensures a bare `main` is a totally pure, capability-free entry point.
- **`main with capabilities [...]`** — every capability referenced in `with capabilities [...]` blocks, `serve`, and `startWorkers`/`startDeadWorkers` calls must be a subset of the declared set.  A missing capability is a compile error instead of a runtime failure.

**`startWorkers` and `startDeadWorkers`** start worker groups' background poll threads:
**Accepted design, Implemented.**

**SSE pub/sub LISTEN** starts automatically inside `serve` — no `startWebSocket` call needed.

```text
<main-statement> ::= ...existing...
                   | "startWorkers"     [ <integer> ] <identifier> "with" "capabilities" <capability-list>
                   | "startDeadWorkers" <identifier> "with" "capabilities" <capability-list>
                   | "startEmailWorker" <identifier>
```

`startWorkers N`: the optional integer `N` sets the number of concurrent worker threads for that worker group (default 1). Each thread independently dequeues and processes one job at a time using PostgreSQL's `SELECT ... FOR UPDATE SKIP LOCKED`, so threads never block each other.

**Choosing N:**
- I/O-bound jobs (HTTP calls, external APIs): N = 4–8
- CPU-bound jobs: N ≈ number of CPU cores
- Conservative default: 2–4; increase based on queue depth monitoring

**`startDeadWorkers`** always runs a single-threaded poll — it has no `N` parameter. Dead-letter handlers compensate for failures and should run serially to avoid duplicate compensating actions.

```tesl
main with capabilities [appService, smtpSend] {
  with database MainDatabase {
    with capabilities [appService, smtpSend] {
      startWorkers     5 EmailWorkers      with capabilities [smtpSend]   -- 5 concurrent email workers
      startDeadWorkers DeadEmailWorkers    with capabilities [smtpSend]   -- single-threaded (no N)
      -- No startWebSocket needed — SSE pub/sub LISTEN starts inside serve
      serve         MyServer              on port  with capabilities [appService]
    }
  }
}
```

`startWorkers` launches N+2 threads per queue/handler pair with PostgreSQL (N+1 with the in-memory fallback):

- **Fallback Poller** — wakes every 5 s to ensure no job is ever stranded indefinitely.
- **LISTEN Connection** *(PostgreSQL only)* — holds a dedicated connection with `LISTEN tesl_queue_<name>`. Wakes immediately when any process enqueues a job and its transaction commits. Reconnects automatically on failure.
- **SKIP LOCKED Worker** — waits on a semaphore (posted by the LISTEN thread or the poller), drains burst signals, then issues `FOR UPDATE SKIP LOCKED` until the queue is empty.

`enqueue!` also issues `SELECT pg_notify(...)` inside the enclosing transaction so the NOTIFY fires exactly on commit — workers in other processes receive the same sub-millisecond wakeup. **Order matters:** call `startWorkers` before `serve`.

`serve` automatically starts (with PostgreSQL) a pub/sub LISTEN thread when SSE endpoints are registered:

- Holds a dedicated connection with `LISTEN tesl_pubsub`. When a NOTIFY arrives carrying an outbox row ID, the thread fetches the row, fans the event to in-memory SSE listeners, and delivers it.
- A fallback poller sweeps `tesl_pubsub_outbox` every 5 s for rows that survived a dropped NOTIFY.
- An initial sweep on startup delivers events published before LISTEN was established.

## 12. Function bodies and expressions
### 12.1 Statements
**Accepted design, mostly Implemented.**

```text
<body> ::= { <statement> }

<statement> ::= <let-statement>
              | <if-statement>
              | <case-statement>
              | <exists-pack-statement>
              | <with-database-statement>
              | <with-capabilities-statement>
              | <update-statement>
              | <telemetry-statement>
              | <init-telemetry-statement>
              | <serve-statement>
              | <ok-statement>
              | <fail-statement>
              | <enqueue-statement>
              | <publish-statement>
              | <with-transaction-statement>
              | <expr>
```

#### `let`

```text
<let-statement> ::= "let" <identifier> "=" <expr>
                  | "let" <identifier> "=" "check" <expr>
                  | "let" "(" <identifier> ":::" <identifier> ")" "=" <expr>
```

`let name = check expr` is the monadic success-binding form. If the check succeeds, the implementation binds a fresh named value for `name` using the raw payload of the successful check result plus the detached proof extracted from that result.

**No `let ... in` expression form.** `let` is a *statement*, not an expression. Tesl deliberately does not support `let x = expr in body` inline expressions. The single-statement form keeps function bodies linear and greppable — every binding is visible at a consistent indentation level — and avoids the "wall of parentheses" style that `let … in … let … in …` chains drift into. Use sequential `let` statements at the function body level instead. This is a settled design decision and will not change.

**Why `check` calls must be `let`-bound.** The GDP proof system tracks proofs by
*subject identity* — a stable compiler-assigned name for each bound value. A `check`
call produces a named proof that the subject `x` satisfies predicate `P`. For this
to work, the result must be bound to a name with `let x = check f(n)`, so the compiler
can associate the proof with the subject `x`. Writing `needsProof (check f(n))` without
a `let` binding is rejected because there is no stable subject name to attach the proof
to. The proof only exists in the scope of the `let`-bound name.

A bare `check` call used as a statement (result not bound) is also a compile-time error:

```tesl
fn demo(raw: Int) -> Int =
  check isPositive raw   # ERROR: bare `check` — result not bound, proof discarded
  42
```

The compiler rejects this with: `"bare \`check\` call: the result must be bound with \`let x = check f(n)\`"`. A bare `check` does not gate subsequent statements — it discards both the validated value and the proof.

`let (x ::: p) = y` is proof decomposition. It elaborates to `x = forgetFact(y)` and `p = detachAllProof(y)`. The value `x` preserves the hidden subject identity of `y` but has no attached proofs. The proof `p` is a first-class detached proof carrying all facts that were attached to `y`. This form is only valid when `y` has at least one attached proof.

The proof side supports `&&`-separated patterns with `_` as discard:

```tesl
let (x ::: _ && q) = y           # discard left proof, bind right as q
let (x ::: p && _) = y           # bind left as p, discard right
let (x ::: p && q) = y           # bind both
let (_ ::: p) = y                # discard value, bind proof only
let (x ::: _ && q && r) = y      # three-way: discard first, bind second and third
```

Pattern matching is positional over the flat conjunction structure. For a value carrying `A && B && C`, the first pattern item corresponds to `A`, the second to `B`, the third to `C`. The elaboration uses `andLeft`/`andRight` to project each part. `_` means the projected proof is discarded.

**`let (_ ::: p) = check f(x)` — validate and keep original name.** A particularly useful combination: decompose a `check` result immediately, discarding the value binding but keeping the proof. The compiler tracks that `p` is the proof *about* `x`, so the proof can be re-attached to `x` with `x ::: p` or `attachFact x p`:

```tesl
fn insertValidated(t: Tree, raw: Int) -> Tree =
  let (_ ::: p) = check checkPositive raw
  let proven = raw ::: p       # raw now carries IsPositive raw
  insertTree t proven          # insertTree requires IsPositive on its second arg
```

This is the idiomatic pattern when downstream code refers to the original binding name (`raw`) rather than the check-result name, or when you need to store the proof separately before re-attaching it. The compiler is smart enough to know that `p` is the proof of `raw`'s subject, so re-attachment is sound.

#### `if`

```text
<if-statement> ::= "if" <expr> "then"
                   <body>
                   "else"
                   <body>
```

**`if/then/else` must be multi-line in function bodies.** Inline single-line `if cond then a else b` is not accepted. Both the `then` and `else` branches must be on separate indented lines:

> **Design note — single-line `if` is forbidden by design.** The parser intentionally rejects `if cond then a else b` on one line. This is not an incidental parser limitation; it is an explicit formatting constraint to ensure that branch structure is always visually clear and consistent across all Tesl code.

```tesl
# Correct
if n > 0 then
  "positive"
else
  "non-positive"

# Rejected — single-line form not supported
if n > 0 then "positive" else "non-positive"
```

#### `case`

```text
<case-statement> ::= "case" <expr> "of" <case-branch>+
<case-branch>    ::= <case-pattern> [ "where" <expr> ] "->" ( <expr> | <body> )
<case-pattern>   ::= <constructor-pattern>
                   | <lit-pattern>
                   | <identifier>
                   | "_"
<constructor-pattern> ::= <UIDENT> { <field-pattern> | "_" }
                        | <UIDENT> "{" <label-pattern> { "," <label-pattern> } "}"
<field-pattern>  ::= <identifier>                          (* variable binding *)
                   | "_"                                   (* wildcard *)
                   | "(" <constructor-pattern> ")"         (* nested constructor *)
                   | "Nothing"                             (* bare nullary Maybe variant *)
                   | <UIDENT>                              (* bare nullary constructor *)
<label-pattern>  ::= <IDENT> "=" <case-pattern>
<lit-pattern>    ::= <STRING>                              (* string literal match *)
                   | <INT>                                 (* integer literal match *)
```

Duplicate binders in a case pattern are illegal. The underscore `_` is not a binder.

**Literal patterns.** String and integer literals match exact values:

```tesl
case code of
  200 -> "OK"
  404 -> "Not Found"
  _   -> "other"

case cmd of
  "help"  -> showHelp()
  "quit"  -> quit()
  other   -> unknown other
```

Literal patterns do NOT count toward exhaustiveness for general types (`Int`, `String`) — a variable or wildcard catch-all arm is always required.

**Nested constructor patterns.** A field position can contain a sub-pattern to match the nested constructor:

```tesl
# Positional syntax (wraps the sub-pattern in parens):
case m of
  Wrap (Something n) -> n
  Wrap Nothing       -> 0

# Labeled syntax (uses braces with field = sub-pattern):
case v of
  Wrap { inner = Something { value = n } } -> n
  Wrap { inner = Nothing }                 -> 0
```

**Case expressions must be exhaustive.** Every constructor of the matched ADT must appear in some branch. Non-exhaustive `case` is a compile-time error listing the missing constructors.

**`where` guards.** A `where` clause adds a runtime condition to a case arm. The guard is evaluated *after* the pattern matches. If the guard is false the arm is skipped and the next arm is tried:

```tesl
case existing of
  Nothing ->
    fail 404 "not found"
  Something todo where todo.ownerId != requestUser.id ->
    fail 403 "not your todo"
  Something todo ->
    todo
```

The `where` guard is emitted as part of the `cond` condition in the compiled Racket — it does **not** execute the arm body before checking the guard. This means bound pattern variables (like `todo` above) are available to the guard expression.

**Explicit binders required.** Every field of a constructor must be explicitly bound or wildcarded. `Circle _ ->` for a one-field constructor, `AlternativeA _ s ->` for a two-field constructor. Omitting binders is an arity error.

**Fall-through arms.** A branch with an empty body (no expression after `->`) is a fall-through arm. It shares the body of the next non-empty arm. This provides the "or-pattern" idiom without wildcard syntax:

```tesl
case status of
  Backlog    ->
  Todo       ->
  Cancelled  ->
    "inactive"     # Backlog, Todo, and Cancelled all use this body
  InProgress ->
  InReview   ->
    "active"       # InProgress and InReview use this body
  Done       ->
    "complete"
```

Fall-through arms may carry binders (`AlternativeA _ s ->`), but those binders are **ignored at runtime** — only the body arm's binders are accessed. This lets you document the constructor's fields for readability without affecting behaviour.

Safety check for the body arm closing a fall-through group: every field label that the body arm binds must exist in **all** preceding fall-through constructors. If a pending constructor lacks the field, the compiler rejects it:

```tesl
type Bepa
  = AlternativeA x:Int s:String
  | AlternativeB s:String
  | AlternativeC t:Int          # does NOT have field 's'

# VALID — AlternativeA and AlternativeB both have field 's'
fn f(b: Bepa) -> String =
  case b of
    AlternativeA _ s ->         # fall-through; 's' documented but ignored
    AlternativeB s ->           # body: accesses field 's' (exists in both)
      *s
    AlternativeC _ ->
      "no-string"

# COMPILE ERROR — AlternativeC lacks field 's'
fn g(b: Bepa) -> String =
  case b of
    AlternativeC _ ->
    AlternativeB s ->           # error: AlternativeC has no 's' field
      *s
```

Additional fall-through constraints:
- The final arm in the entire `case` must have a body — a trailing empty arm is a compile error.
- Wildcard patterns (`_`) are not supported as standalone constructor names by design; fall-through is the intended mechanism for grouping constructors.

#### Existential packing

```text
<exists-pack-statement> ::= "exists" <identifier> "=>" <body>
```

This statement does not bind a fresh variable. It packages an existing named value as an existential witness.

#### Resource / capability blocks

```text
<with-database-statement> ::= "with database" <identifier> "{" <body> "}"
<with-capabilities-statement> ::= "with capabilities" <capability-list> "{" <body> "}"
```

#### Success and failure

```text
<ok-statement> ::= "ok" <expr> ":::" <gdp-expr>
<fail-statement> ::= "fail" <integer> <expr>
```

**`fail` shape is intentionally minimal.** `fail STATUS "message"` takes exactly an HTTP status code and a plain message. Tesl deliberately does **not** accept a structured JSON payload here. The rationale:

1. Tesl pushes validation to the edge (codecs + `check`), so once a handler body runs, the rest of the request is structurally correct. The remaining failure modes are small and enumerable.
2. A single consistent error shape (status + message) is easier for clients to consume than a union of ad-hoc per-endpoint error bodies.
3. Complex error payloads encourage treating `fail` as a side channel for computed values. That is exactly the ambiguity Tesl's proof system is built to eliminate.

If a handler genuinely needs to return a machine-readable error envelope (for example to surface which of several field-level checks failed in a single response), the right shape is an ordinary success branch returning a domain record that carries the failure data, and a consistent client-side contract about how to interpret it. `fail` remains the short, minimal, "stop and return this status" escape hatch.

This is a settled design decision.

#### The two `ok` forms are not interchangeable

There are two distinct `ok` forms, and they serve different purposes:

- **`ok val ::: proof`** — canonical for `check` and `auth` functions. Produces a `check-ok` carrying the value, plus the proof fact(s) from `proof`. The `let x = check f(n)` form binds `x` as a named-value with the proof attached and the raw value preserved as the subject.

- **Direct proof constructor** — the idiomatic form for `establish` functions. Return the proof predicate directly as a value, e.g. `IsPositive n` or `PriceExceedsQuantity price quantity`. An `establish` function must return `Fact (P args)` or `Maybe (Fact (P args))`. The body returns the proof constructor application directly:

```tesl
establish provePositive(n: Int) -> Fact (IsPositive n) =
  IsPositive n

establish validatePort(p: Int) -> Maybe (Fact (ValidPort p)) =
  if 1 <= p && p <= 65535 then Something (ValidPort p) else Nothing
```

**`establish` is total.** Unlike `check` functions, `establish` functions cannot use `fail` — they must always return a value. If the proof cannot be established, return `Nothing` (for `Maybe (Fact P)` return types). An `establish` body that uses `fail` is a compile-time error.

Both `ok val ::: proof` and direct proof constructors work naturally with the proof system. However, they are **not interchangeable in general**:

- Using `ok val ::: proof` (the `check` form) in an `establish` function is a compile-time error.
- Using direct proof constructors in a `check` function is a compile-time error.
- Calling `detachFact` on an `ok <| proof` result (`detached-proof`) produces a **doubly-wrapped detachment** — a `detached-proof` wrapping another `detached-proof` — which is not a valid proof carrier.

**`ok` binding name requirement in `check` functions.** The expression after `ok` must be the declared binding name. `ok 42 ::: IsPositive n` is rejected — the literal `42` is not the binding `n`. The proof must also match the declared return spec exactly:

```tesl
# WRONG — literal is not the binding name
check bad(n: Int) -> n: Int ::: Positive n =
  if n > 0 then ok 42 ::: Positive n   # error: must return n, not 42
  else fail 400 "..."

# WRONG — proof args in wrong order
check bad2(lo: Int, hi: Int) -> lo: Int ::: InRange lo hi =
  ok lo ::: InRange hi lo              # error: proof does not match

# RIGHT
check validatePositive(n: Int) -> n: Int ::: Positive n =
  if n > 0 then ok n ::: Positive n
  else fail 400 "not positive"
```

#### Miscellaneous body statements

```text
<telemetry-statement> ::= "telemetry" <string> "{" [ <telemetry-attr> { "," <telemetry-attr> } ] "}"
<telemetry-attr> ::= <identifier-or-dotted> "=" <expr>

<init-telemetry-statement> ::= "initTelemetry" "service" <string> "endpoint" <string> "console" ("true" | "false")

<serve-statement> ::= "serve" <identifier> "on" <identifier> "with capabilities" <capability-list>
```

#### `enqueue`
**Accepted design, Implemented.**

```text
<enqueue-statement> ::= "enqueue" <identifier> <record-literal>
```

Inserts a job of the named record type into the associated queue. The job type determines the queue unambiguously — each job type belongs to exactly one queue (compiler enforces). Requires the relevant `queueWrite`-derived capability.

```tesl
enqueue SendEmail { to: req.email, subject: "Welcome!", body: "..." }
```

Inside a `with transaction` block, the job is inserted atomically — it only becomes visible to workers if the transaction commits. Outside a transaction, delivery is at-most-once (lint warning emitted).

#### `publish`
**Accepted design, Implemented.**

```text
<publish-statement> ::= "publish" <identifier> "(" [ <expr> { "," <expr> } ] ")" <adt-constructor-expr>
```

Publishes an event to the named channel, parameterised by the channel key. The second argument must be a constructor of the channel's `payload` ADT. Requires `pubsub` capability.

```tesl
publish UserEvents(userId) ProfileUpdated { bio: newBio }
```

Inside `with transaction` with a PostgreSQL database active: writes the event to `tesl_pubsub_outbox` as part of the same transaction; in-memory listeners are called after commit. If the transaction rolls back, neither the outbox row nor the listener call happens. Outside a transaction: calls in-memory listeners directly (at-most-once semantics).

#### `with transaction`
**Accepted design, Implemented.**

```text
<with-transaction-statement> ::= "with" "transaction" "{" <body> "}"
```

Wraps all enclosed database operations (`insert`, `update`, `delete`, `enqueue`, `publish`) in a single Postgres transaction. The block returns its last expression. On any exception, the transaction rolls back and no jobs or notifications escape. Nesting `with transaction` inside another `with transaction` is a compile error.

```tesl
with transaction {
  let user = insert User { id: userId, email: req.email }
  enqueue SendEmail { to: req.email, subject: "Welcome!" }
  user   # returned value
}
```

#### Dead-letter workers: `deadWorker`, `deadWorkers`, and `startDeadWorkers`
**Accepted design, Implemented.**

When a job fails `maxAttempts` times it moves to `dead` status and is skipped by the normal worker loop. A separate **dead-letter worker** handles these jobs — typically to send an alert, log the failure, or publish a compensating event.

**`deadWorker`** is declared exactly like `worker`, except with the `deadWorker` keyword and the `FromDeadQueue` proof (instead of `FromQueue`):

```text
<dead-worker-fn>  ::= "deadWorker" <identifier> "(" <param-list> ")"
                      [ "->" <type-expr> ]
                      "requires" "[" <capability-list> "]"
                      "=" <body>
```

```tesl
deadWorker handleDeadEmail(job: SendEmail ::: FromDeadQueue (Id == jobId) job)
  requires [alertCap] =
  telemetry "email.dead" { to = job.to, subject = job.subject }
  publish AdminAlerts() EmailDeliveryFailed { to: job.to }
  job
```

Returning the job value marks it **acknowledged** (deleted from the dead-letter queue). Calling `fail` restores it to `dead` status for the next dead-worker pass.

**`deadWorkers`** maps job types to dead-worker functions — mirrors `workers` exactly:

```text
<dead-workers-decl> ::= "deadWorkers" <identifier> "for" <identifier>
                        "{" { <identifier> "=" <identifier> } "}"
```

```tesl
deadWorkers DeadEmailWorkers for EmailQueue {
  SendEmail   = handleDeadEmail
  GeneratePDF = handleDeadPdf
}
```

Every job type in the queue must have exactly one dead-letter worker (same completeness rule as `workers`).

**`startDeadWorkers`** in `main` starts the dead-letter poll loop:

```tesl
main {
  with database MainDatabase {
    with capabilities [appService] {
      startWorkers     EmailWorkers     with capabilities [smtpSend]
      startDeadWorkers DeadEmailWorkers with capabilities [alertCap]
      serve            MyServer         on port with capabilities [appService]
    }
  }
}
```

The dead-letter loop polls every 10 seconds (no NOTIFY wakeup — dead jobs are infrequent). On success the job row is deleted; on failure it stays `dead` and will be retried on the next poll.

### 12.2 Expressions
**Accepted design, partly Implemented.**

```text
<expr> ::= <raw-expr>
         | <attach-sugar>
         | <paren-call-expr>
         | <qualified-name>
         | <select-expr>
         | <insert-expr>
         | <record-literal>
         | <record-update>
         | <list-literal>
         | <string-literal>
         | <integer>
         | "true"
         | "false"
         | "Nothing"
         | <identifier>
         | "(" <expr> ")"
         | <expr> <value-op> <expr>
         | <expr> "|>" <expr>
         | <expr> "<|" <expr>
```

#### List literals
**Accepted design, Implemented.**

```text
<list-literal> ::= "[" [ <expr> { "," <expr> } ] "]"
```

List literals construct a Racket list. The empty list is `[]`; a list with elements is `[a, b, c]`. All elements are compiled with `raw_default=True` (their GDP subject wrappers are stripped to plain values).

```tesl
let empty  = []                # Racket: (list)
let ns     = [1, 2, 3]        # Racket: (list 1 2 3)
let nested = [[1, 2], [3, 4]] # Racket: (list (list 1 2) (list 3 4))
```

**Important:** the `[...]` bracket depth is tracked by all internal splitting functions, so nested list literals parse correctly. `[["a","b"],["c","d"]]` is two elements, not four.

#### Implicit value unwrapping

Tesl parameters and locally bound proof-carrying values are automatically unwrapped by the compiler where a raw (non-GDP) value is needed — for example, in arithmetic, comparisons, string interpolation, and function arguments. There is no surface syntax for manual unwrapping; the compiler infers the correct representation at each use site.

#### Proof attachment sugar

```text
<attach-sugar> ::= <expr> ":::" <proofish-expr>
<proofish-expr> ::= <expr> { "&&" <expr> }
```

This lowers to `attachFact(value, proofish)`.

The preferred pattern for passing a proof-bearing value to a function is `f <| value ::: proof`, which combines `<|` (low-precedence application) with `:::` (proof attachment). This avoids explicit `attachFact` calls in most cases:

```tesl
listen <| port ::: portProof          # preferred
listen (attachFact port portProof)   # equivalent but verbose
```

Important distinction:

- in a proof fact, `&&` and `||` are logical operators over facts;
- in a proofish expression position, `&&` is currently used as proof-value composition, building a collection of detached proofs to attach.

**`:::` requires a proof value, not a predicate expression.** The right-hand side of `:::` in expression context must be an existing proof value — typically the return value of an `establish` or `check` function, a variable holding a detached proof, or a composition built with `introAnd`/`detachFact`. Writing a raw predicate expression such as `value ::: IsPositive x` is only valid inside `establish`, `check`, and `auth` functions (where `ok val ::: Pred val` is the proof-introduction form). In `fn` and `handler` bodies it is rejected at compile time with a clear error. This rule exists because a raw predicate expression in `:::` position would otherwise fabricate a proof fact without going through any validation boundary.

#### Function application
**Accepted design, Implemented.**

Tesl uses ML-style space-separated application:

```text
<application> ::= <callee> <atom> { <atom> }

<callee> ::= <identifier> | <dotted-identifier> | "(" <expr> ")"
<atom> ::= <identifier> | <integer> | <string-literal> | "(" <expr> ")"
```

```tesl
detachFact y
attachFact x proof
add (double x) (double y)
String.length title
(checkActive && checkPinned) note
```

Parentheses are only for grouping or for forming a grouped callee. They do not introduce legacy `f(x)` call syntax. Use `String.startsWith title "todo-"`, not `String.startsWith(title, "todo-")`.

Bare function names are first-class values. Use `f` when passing or storing a function, and use `f()` only for an explicit zero-argument call. This keeps zero-arg invocation distinct from function values while still rejecting legacy `f(x)` / `f(x, y)` syntax.

Application has the highest precedence among expression forms. Parentheses serve as grouping when a subexpression needs to be passed as a single argument: `double (add x y)`.

Function *declarations* retain parenthesized parameter syntax with type annotations, as this is required for the GDP name/subject/type binding machinery.

#### Receiver-style method syntax is not part of the language
**Accepted design, Implemented.**

Receiver-style dotted function syntax is not part of the language and is rejected by the compiler. The canonical style is namespaced function calls:

- `String.length(title)` instead of `title.length`
- `String.startsWith(title, "prefix")` instead of `title.startsWith("prefix")`
- `List.isEmpty(xs)` instead of `(xs).isEmpty`

#### Low-precedence application and pipeline operators
**Accepted design, Implemented.**

```text
<pipe-expr> ::= <expr> "|>" <expr>
<apply-expr> ::= <expr> "<|" <expr>
```

`|>` is the left-to-right pipeline operator. `x |> f` is equivalent to `f x`. Chains are left-associative: `x |> f |> g` is `g (f x)`.

`<|` is the right-to-left low-precedence application operator (analogous to Haskell's `$`). `f <| x` is equivalent to `f x`. Chains are right-associative: `f <| g <| x` is `f (g x)`.

Both operators have the lowest precedence of all expression operators — lower than `:::`. This means `f <| x ::: proof` parses as `f <| (x ::: proof)`, which is the idiomatic way to pass a proof-bearing value to a function:

```tesl
listen <| port ::: portProof       # f <| (value ::: proof)
port ::: portProof |> listen       # (value ::: proof) |> f
```

The existing `ok <| ProofFact` in proof-producing functions is a special case of `<|` applied to the `ok` form.

#### Query/update forms

The current `.tesl` frontend includes a small SQL-like sublanguage:

```text
<select-expr> ::= "selectOne" <identifier> "from" <entity>
                              [ <select-clause>* ]
               | "select" <identifier> "from" <entity>
                          [ <select-clause>* ]
               | "selectCount" <identifier> "from" <entity>
                               [ <select-clause>* ]
               | "selectSum" <identifier> "." <field> "from" <entity>
                             [ <select-clause>* ]
               | "selectMax" <identifier> "." <field> "from" <entity>
                             [ <select-clause>* ]
               | "selectMin" <identifier> "." <field> "from" <entity>
                             [ <select-clause>* ]

<select-clause> ::= "where" <sql-predicate>
                  | "where" "isNull"    <field-ref>
                  | "where" "isNotNull" <field-ref>
                  | "where" "inList"    <field-ref> "[" <expr>* "]"
                  | "where" "notInList" <field-ref> "[" <expr>* "]"
                  | "where" "like"      <field-ref> <string-expr>
                  | "where" "ilike"     <field-ref> <string-expr>
                  | "order"   <field-ref> ( "asc" | "desc" )
                  | "limit"   <int>
                  | "offset"  <int>
                  | "groupBy" <field-ref>
                  | "innerJoin" <entity> "on" <binder-field-ref> <entity-field-ref>

<insert-expr> ::= "insert" <identifier> <record-literal>

<upsert-expr> ::= "upsert" <entity> "{" { <field-init> } "}"
                  "onConflict" "[" <field>+ "]"
                  "doUpdate"   "[" <field>+ "]"

<delete-expr> ::= "delete" <identifier> "from" <entity>
                            [ <select-clause>* ]
               | "deleteAndReturnResult" <identifier> "from" <entity>
                                        [ <select-clause>* ]

<update-statement> ::= "update" <identifier> "in" <identifier>
                       <update-line>+
<update-line> ::= "where" <sql-predicate>
                | "set" <identifier> "." <identifier> "=" <expr>
                | "returning" "one"

<sql-predicate> ::= <identifier> "." <identifier> <comparison-op> <expr>
<comparison-op> ::= "==" | "!=" | "<=" | ">=" | "<" | ">"
```

**`innerJoin` — inner join by FK.** Returns only rows from the main entity for which a matching row exists in the joined entity. The two field refs after `on` are the main entity's FK field and the join entity's matching field (no `==` operator — `==` sits above function application in Tesl's grammar):

```tesl
select u from User innerJoin Profile on u.profileId Profile.id

select u from User
  where u.active == True
  innerJoin Profile on u.profileId Profile.id
```

**Aggregate queries.**  All aggregate forms require the `dbRead` capability. `selectCount` always returns `Int`. `selectSum`, `selectMax`, `selectMin` return the same type as the target field (e.g. `Int` for an integer field, `Float` for a float field).

```tesl
let total  = selectCount u from User where u.active == True     # Int
let total  = selectSum   u.score from User                      # Int (or Float)
let top    = selectMax   u.score from User where u.active == True
let bottom = selectMin   u.score from User
```

**`upsert` — INSERT … ON CONFLICT DO UPDATE.**  Inserts a record; if the conflict column(s) already exist, updates only the listed fields.  `onConflict` takes the column(s) to conflict on (usually the unique/PK columns); `doUpdate` lists the columns to overwrite on conflict.

```tesl
upsert Session { userId: uid, token: tok, expiresAt: exp }
  onConflict [userId]
  doUpdate   [token, expiresAt]
```

**`delete` and `deleteAndReturnResult`.**  `delete` removes matching rows and returns `Unit`.  `deleteAndReturnResult` removes matching rows and returns `DeleteResult`, which carries the count of deleted rows.  `DeleteResult` and the constructors `NoRowDeleted` / `RowsDeleted` must be imported from `Tesl.DB`:

```tesl
import Tesl.DB exposing [DeleteResult, NoRowDeleted, RowsDeleted]

# Simple delete (returns Unit)
delete u from User where u.id == userId

# Delete with result inspection
let result = deleteAndReturnResult u from User where u.id == userId
case result of
  NoRowDeleted -> ...
  RowsDeleted  -> ...
```

## 13. Static semantics
### 13.1 Names, duplication, and imports
**Accepted design, Implemented.**

- A module header is mandatory.
- The module header may appear only once.
- Export lists must be explicit. Wildcard exports are rejected.
- Imports may use either an explicit `exposing [...]` list or the module-import form (`import Module`) for qualified-only access.
- Duplicate top-level definitions are rejected.
- Imported names may not conflict with local definitions.
- The same imported name may not arrive from two different imports.
- Same-spelled type aliases, records, entities, and ADTs defined in different modules are distinct declarations; identity is tied to the defining module, not just the bare name.
- If multiple imported declarations would make an unqualified type-like reference ambiguous, the program must use module qualification/prefixing instead of relying on bare-name resolution.
- `Type(..)` import/export syntax is only valid for locally defined or exported ADTs.
- Proof predicates (upper-case names used in `:::` annotations, such as `ValidPort` or `IsPositive`) are part of the module namespace. They must be explicitly exported by their home module and explicitly imported by any module that names them in function or record annotations. Using a predicate in a signature without having imported it is a compile error. This rule applies to parameter annotations, return spec proof annotations, and `Fact(...)` return types.

### 13.2 No-shadowing rule
**Accepted design, Implemented.**

The following are compile-time errors when they shadow an already-visible name:

- function parameters;
- `let` bindings;
- `case` binders.

This rule exists because the language treats visible binders as proof-relevant carriers of hidden GDP names.

### 13.3 Scope of `exists` in function bodies
**Accepted design, Implemented.**

`exists witness => ...` requires that `witness` already be a visible bound name. It is a packaging form, not a fresh binder form.

### 13.4 Scope of implicit unwrapping
**Accepted design, Implemented.**

Implicit value unwrapping applies to function parameters and locally bound proof-carrying values. The compiler automatically unwraps named values at use sites that require raw Racket values (arithmetic operators, comparisons, string interpolation, constructor arguments, stdlib calls). No surface syntax is required or accepted for manual unwrapping.

### 13.5 Scope of GDP names in proof templates
**Accepted design, Implemented.**

Proof templates are validated for scope. Unbound names inside proof-related syntax are rejected.

This includes, among other places:

- binding annotations;
- return annotations;
- proof-accepting success forms.

### 13.6 Static proof checking at call sites
**Accepted design, Implemented.**

For function calls, the frontend performs proof-aware static checking roughly as follows:

1. each visible value binder in scope carries a static subject identity;
2. when calling a function, the callee's formal parameter names are mapped to the actual argument subjects;
3. the callee's proof obligation is instantiated with that subject mapping;
4. if the obligation for the checked argument's own binder is still unresolved, the call is rejected;
5. if the obligation is fully known and the argument's known facts do not satisfy it, the call is rejected;
6. otherwise the call may be allowed and runtime validation remains authoritative.

This is how cross-parameter proof references such as `ValidPort x` on another parameter can be checked without confusing surface spelling with subject identity.

### 13.7 Static proof satisfaction
**Accepted design, Implemented.**

Static proof satisfaction is currently structural and uses these rules:

- an expected fact is satisfied if that fact is present exactly;
- `P && Q` is satisfied if both `P` and `Q` are satisfied.

### 13.8 Record and entity field restrictions
**Accepted design, Implemented.**

- Record fields may carry proof annotations and optional `via` checkers.
- Entity fields may carry only simple field proof names and do not support `via` checkers.

### 13.9 Proof predicate scope and explicit import
**Accepted design, Implemented.**

A proof predicate name is in scope in a module if and only if:

1. the module declares it — i.e. it is produced in the return type of a local `establish`, `check`, or `auth` function; or
2. the module explicitly imports it — i.e. the predicate name appears in an `import … exposing [...]` list and the exporting module lists it in `exposing [...]`.

This is the same rule that governs functions, record types, and ADT constructors. There is no implicit "transitive visibility" — a module that imports `isValidPort` from `Ports` does not automatically gain the ability to name `ValidPort` in its own annotations; it must import `ValidPort` explicitly too.

**Module-only imports do not expose proof predicates.** A bare `import Tesl.String` (no `exposing` clause) brings the module's functions into qualified scope (`String.length`, etc.) but does NOT make its proof predicates (`IsTrimmed`, `IsNonEmpty`, etc.) available in `:::` annotations. Proof predicates always require an explicit `exposing` clause:

```tesl
# WRONG — IsTrimmed is not in scope without explicit import
import Tesl.String
fn needTrimmed(s: String ::: IsTrimmed s) -> String = s   # compile error

# RIGHT
import Tesl.String exposing [String.trim, IsTrimmed]
fn needTrimmed(s: String ::: IsTrimmed s) -> String = s   # ok
```

The compiler error is: `"proof predicate \`IsTrimmed\` is not in scope; a plain module import does not expose proof predicates. To use it, add it to an explicit import: \`import Tesl.String exposing [IsTrimmed]\`"`.

**Why this rule exists:** In a large codebase there should be exactly one greppable canonical declaration of `ValidPort`. That declaration is the `exposing [ValidPort]` line in the home module. The import statement in every consuming module is an explicit acknowledgement of the dependency. Without this rule, a predicate name could proliferate invisibly across the codebase with no traceable origin.

**Partial application restriction:** Partial application of a function is rejected at compile time if any remaining parameter's proof annotation references a captured parameter. The resulting closure would require a proof about a hidden captured subject, which cannot be expressed or satisfied in Tesl.

## 14. Dynamic semantics
### 14.1 Runtime argument validation
**Accepted design, Implemented.**

Direct calls to executable/check-like definitions validate declared argument types and proofs at runtime.

This includes current `.tesl` functions lowered to:

- `define/pow`
- `define-handler`
- `define-trusted`
- `define-checker`
- `define-auther`

### 14.2 Runtime proof satisfaction
**Accepted design, Implemented.**

Runtime proof checking interprets the expected proof against:

- the facts attached to the evidence-bearing value;
- the runtime subject environment carried by that value.

As at compile time:

- exact facts satisfy themselves;
- `&&` requires all parts.

### 14.3 `detachFact`
**Accepted design, Implemented.**

- `detachFact(value)` extracts the attached proof from `value`.
- If no proof is attached, it fails.
- If exactly one proof is attached, it returns that proof as a `Fact`.
- If multiple separate proofs are attached, `detachFact(value)` **succeeds** by combining
  all attached facts into a single `&&` conjunction and returning the combined proof.
  This is equivalent to calling `detachAllFact`.
- To extract individual proofs from a conjunction, use `andLeft` and `andRight`, or
  use proof decomposition: `let (x ::: p1 && p2) = value` (see §15.2).

### 14.4 Proof decomposition
**Accepted design.**

Use `let (x ::: p) = value` (proof decomposition) to detach a proof from a value, or `let (x ::: p1 && p2) = value` to split a conjunction.

### 14.5 `attachFact`
**Accepted design, Implemented.**

`attachFact(value, proofish)` accepts:

- one detached proof; or
- a list/collection of detached proofs built by proofish conjunction.

It does not accept plain proof-fact data with no detached-proof carrier.

### 14.6 `forgetFact`
**Accepted design, Implemented.**

`forgetFact(value)` removes attached facts while preserving the subject identity and runtime bindings associated with the value.

### 14.7 Existentials
**Accepted design, Implemented for return specs and packing; elimination surface still evolving.**

The runtime supports existential packages plus witness-escape checks.

The current `.tesl` surface includes:

- existential return specs;
- existential packing with `exists witness => ...`.

Dedicated `.tesl` elimination syntax is not yet part of the stable surface.

**Structurally binding the witness to a record id field.** When a handler creates a resource and returns it with an existential proof, the proof fact should encode the primary-key equality explicitly — mirroring the SQL layer's `FromDb (Id == todoId)` pattern. For non-database resources, use a check function that validates `resource.id == witnessId` and constructs a proof of the form `IsCreated (Id == witnessId) ...`:

```tesl
check checkSessionCreated(session: Session, sessionId: String, user: String ::: Authenticated user)
  -> session: Session ::: IsCreatedSession (Id == sessionId) user =
  if session.id == sessionId then
    ok session ::: IsCreatedSession (Id == sessionId) user
  else
    fail 500 "session id does not match the witness"
```

The `(Id == sessionId)` sub-expression inside the proof fact is the structural binding — it closes the gap between the existential witness and the returned record's identity field. Without it, the proof claims "some session was created" but does not bind the returned session's id to the witness.

**Using `?` with existential returns.** For database entities, the `?` pack operator can be used inside an existential return to avoid naming the inner binder explicitly:

```tesl
handler createTodo(requestUser: User ::: Authenticated requestUser, newTodo: NewTodo)
  -> exists todoId: String =>
       ?Todo ::: FromDb (Id == todoId)
  requires [dbRead, dbWrite, time] =
  let todoId = generateTodoId()
  exists todoId =>
    insert Todo { id: todoId, title: newTodo.title, ... }
```

The `?` here means the inner `Todo` entity is named by whoever unpacks the existential. This is the idiomatic form for create-resource handlers that return database entities.

### 14.8 Route/API boundaries
**Accepted design, Implemented**

At HTTP/API boundaries the runtime validates:

- captures;
- request bodies;
- proof-annotated record fields when a checker is available;
- successful handler returns that cross the HTTP boundary.

These runtime checks are boundary validation, not the primary mechanism for ordinary pure-language typing. Record-literal shape errors, wrong dotted field access, malformed existential returns, and mixed-type arithmetic/boolean/comparison expressions are intended to be rejected by the compiler before code generation or execution.

Current API declarations are intended to remain type-level, with the value-level wiring handled by `server` and `serve`.

## 14b. Structural type system
**Accepted design, Implemented.**

Tesl has two orthogonal type-checking layers:

1. **GDP proof annotations** — described throughout this spec. Check/establish
   function kinds stamp values with proof predicates. The compiler verifies
   that every proof obligation is satisfied.

2. **Structural HM types** — catches wrong-type arguments to stdlib functions
   at compile time, using Hindley–Milner type inference with Robinson unification.

### 14b.1 Type language

```
τ ::= Int | String | Bool | Float | PosixMillis    -- base types

Use `Bool` in Tesl source code. SQL storage types such as `BOOLEAN` are backend representations, not additional Tesl type names, and `Boolean` is not a source-language alias.
    | List τ                                        -- homogeneous list
    | Tuple2 τ₁ τ₂ | Tuple3 τ₁ τ₂ τ₃               -- tuple/product types
    | Maybe τ | Result τ e | Either l r             -- standard ADTs
    | Dict k v | Set τ                              -- collections
    | τ₁ → τ₂                                      -- function type
    | α                                             -- type variable
```

List literals `[e₁, e₂, ...]` are always `List τ` — homogeneous sequences.
A two-element literal `[a, b]` is `List τ`, not `Tuple2`; the elements must
share the same type.

**`Tuple2` and `Tuple3` are separate, distinct types from `List`.**
Use the `Tuple2 a b` and `Tuple3 a b c` constructors explicitly when you want
a product type. A `Tuple2 τ₁ τ₂` cannot be used where `List τ` is expected,
and a `List` literal cannot be used where `Tuple2` is expected — the compiler
rejects both with a type error.

```tesl
let pair = Tuple2 1 "hello"   # Tuple2 Int String
let xs   = [1, 2, 3]          # List Int

# ERROR — Tuple2 ≠ List
# let xs2 = Tuple2 1 2   -- cannot pass to fn expecting List Int
```

Use `Tesl.Tuple` to construct and deconstruct tuples:
- `Tuple2 a b` — constructor
- `Tuple2.first t`, `Tuple2.second t` — accessors
- `Tuple3 a b c`, `Tuple3.first/second/third` — analogous

### 14b.2 PosixMillis is not Int

`PosixMillis` is a nominal newtype. A plain `Int` does NOT satisfy a `PosixMillis`
expectation. Use `Time.secondsToPosix(s)` or `addMs(base, delta)` to construct
typed timestamps from integer literals. `PosixMillis` does **not** auto-unwrap to
`Int` in arithmetic or comparison expressions — use `diffMs(a, b)`, `addMs(ts, n)`,
or `subtractMs(ts, n)` explicitly.

### 14b.3 T_ANY — the escape hatch (stdlib only)

`T_ANY` is an internal sentinel that unifies with any type. It may only appear
in stdlib type signatures (e.g. the check-function argument of `List.filterCheck`)
and never in user code. Users cannot write `Any` in type annotations to bypass
type checking — the word `Any` in a Tesl type annotation is an opaque nominal
type, not the wildcard.

### 14b.4 Error format

Structural type errors use the same location format as GDP errors:

```
error: argument 1 to `Dict.fromList`: expected `List (k, v)` but got `Int`
  --> api.tesl:42
  expression: `Dict.fromList(1)`
  hint: Dict.fromList expects a list of Tuple2 key-value pairs, e.g.
    Dict.fromList [Tuple2 "key1" val1, Tuple2 "key2" val2]
```

Structural type checking is always on; there is no supported env-var bypass for accepted Tesl programs anymore.

### 14b.5 Expression forms covered by structural checking

The structural checker is responsible for the ordinary expression forms that should never fall through to backend/runtime failure for type reasons. In particular:

- record literals and record updates are checked against visible record, entity, or ADT-variant field declarations;
- dotted field access is checked against declared record/entity/variant fields, with `.value` as the explicit newtype unwrap;
- arithmetic, boolean, and comparison operators enforce operand constraints instead of accepting mixed-type expressions;
- when a function declares an existential return type, its terminal expression must be an existential pack (except for `fail ...` paths).

These checks are intentionally frontend responsibilities so that accepted ordinary Tesl programs do not depend on backend/runtime validation for basic type correctness.

---

## 15. Proof composition and decomposition
### 15.1 Implemented proof composition
The following are currently part of the implemented story:

- attaching a detached proof to a value with `attachFact(value, proof)`;
- the surface sugar `value ::: proofValue` where `proofValue` is an existing detached proof (from an `establish`/`check` function, a proof variable, or a composition);
- attaching multiple detached proofs via proofish conjunction `p1 && p2`;
- logical proof conjunction inside proof annotations and obligations using `&&`;
- selecting one proof from a multi-proof value using proof decomposition: `let (x ::: p1 && p2) = value` extracts the conjunction into individual named proofs `p1` and `p2`; `_` discards a slot.

The current proofish `&&` used for attachment is a composition device over detached proofs. It is not yet the final first-class recursive proof-term surface.

### 15.2 Proof decomposition
**Accepted design, Implemented.**

The first proof-decomposition syntax to pursue is:

- `let (x ::: p) = y`

This choice is deliberate:

- it keeps composition and decomposition visually related through `:::`;
- it avoids introducing a separate `split ...` statement before the proof-aware semantics are settled;
- it leaves room to extend the proof side later with `_` and recursive proof patterns.

The intended elaboration is:

- `x` means `forgetFact(y)`;
- `x` therefore preserves the hidden subject identity of `y`;
- `p` means the first-class proof value extracted from `y`;
- the form is only valid when that extraction is unambiguous under the core proof-selection rules.

This form must not be understood as ordinary pair destructuring. It is proof-aware sugar over the existing core operations.

The proof side also supports `&&`-separated patterns with `_` as discard, enabling selective proof extraction:

```tesl
let (x ::: _ && q) = y           # discard left, bind right
let (x ::: p && _) = y           # bind left, discard right
let (_ ::: p) = y                # discard value, bind proof only
let (x ::: _ && q && r) = y      # three-way decomposition
```

Possible later extensions include:

- template-directed proof selection for ambiguous multi-proof values;
- surface sugar for existential elimination.

Parameter syntax that directly splits a function input into value and proof binders is deferred until after local `let`-decomposition has proved sound and ergonomic.

Any future design here should preserve the invariants in sections 6 and 7.

## 16. Open design areas
### 16.1 Currying and partial application
**Accepted design, Implemented.**

Partial application is supported. When a function with known arity `n` is called with fewer than `n` arguments, the call returns a closure that captures the provided arguments and waits for the rest:

```tesl
fn add(x: Int, y: Int) -> Int = x + y

let add3 = add 3        # partial application — returns a closure
add3 4                  # 7
```

ML-style space-separated application works for both known functions and bound variables (including partially-applied closures):

```tesl
let f = add 3
f 4                      # 7
```

### 16.2 Low-precedence application and pipelines
**Implemented.** See Section 12.2 "Low-precedence application and pipeline operators".

### 16.3 Final public existential surface
**Accepted design, Implemented.**

Existential packaging uses `exists witness => body` in function bodies. The witness variable is scoped to the body block and cannot escape. Return types use `exists name: T => InnerType` syntax. The compiler enforces that ordinary functions with existential return types actually return a pack, while the runtime/core still enforces witness escape prevention at evaluation time. This surface is settled.

### 16.4 The exact public role of `establish`
**Accepted design, Implemented.**

`establish` is the surface keyword for trusted fact introduction. It lowers to `define-trusted`, which is the only function kind where `trusted-proof` (and `ok <| proof`) are permitted. The boundary is enforced via a Racket syntax parameter that rejects those forms in all other function kinds.

The canonical usage pattern is:
- `establish` for functions that return a `Fact (ProofPredicate ...)` value — i.e. a first-class detached proof. The body returns the proof constructor directly (e.g. `IsPositive n`), which produces a `detached-proof`.
- `check` for functions that validate a value and return it with proof attached; uses `ok val ::: proof` in the body, which produces a `check-ok` with both value and facts.

See §12 (`ok` forms) for the precise syntax.

The name `establish` is settled. Renaming it is not planned.

**`establish`, `check`, and `auth` are the three proof-minting boundaries of
Tesl's GDP layer.** All three can attach a proof predicate to a value; all three
are equally capable of producing an incorrect proof if the programmer states the
wrong invariant. None of them is "more unsafe" than the others — the honest
framing is that every proof in the system is traceable back to exactly one of
these three kinds of function, and every one of them is a trust boundary that
deserves care.

The three kinds differ in *when* the proof can fail, not in the authority they
grant:

- `check` validates at runtime and can `fail STATUS "..."`. It is the right
  choice at external boundaries (HTTP request bodies, CLI arguments, decoded
  data) where the input might legitimately be invalid.
- `auth` validates at runtime and can `fail STATUS "..."`. It is a specialised
  `check` whose proof is about *identity* rather than *shape*.
- `establish` is total: it cannot `fail`. It is the right choice when the
  proof follows from values that are already known to be good, or when you are
  writing an internal lemma that needs to succeed unconditionally. A conditional
  `establish` returns `Maybe (Fact (P ...))` and the caller handles the
  `Nothing` case — there is no silent failure path.

Because `establish` cannot `fail`, reviewers sometimes think of it as "the
unsafe version". That framing is misleading: an `establish` that returns the
wrong predicate is exactly as unsound as a `check` that returns the wrong
predicate. The right mental model is that all three function kinds are trust
boundaries, the entire file author is responsible for each one, and a single
convention — clear name, clear docstring, obviously-matching return
predicate — applies to all of them.

The design goal is that every proof in the system is traceable: either it
came through a runtime-validated `check`/`auth` boundary, or through a total
`establish` declaration. All three are equally inspectable by tools and
reviewers.

### 16.5 First-class recursive proof(fact) terms and proof(fact) combinators
**Accepted design, Implemented.**

Proof values should eventually support recursive conjunction/disjunction structure, not only atomic detached facts plus ad hoc proofish lists used for the current attachment surface.

This means the proof binder in a future decomposition such as `let (x ::: p) = y` should be able to denote structured proof values, including shapes like `P && Q && R`, provided the subject bindings remain well-scoped and well-founded.

To make explicit proof manipulation possible when it is actually needed, the language should grow a small principled family of proof introduction/elimination helpers.

These helpers must elaborate to the same subject-preserving core as `attachFact`, `detachFact`, and `forgetFact`. They must not retarget proofs, weaken the no-shadowing rule, or allow existential witnesses to escape.

### 16.6 A smaller formal core
This draft is intentionally operational and implementation-aware. A later revision should define a smaller elaboration core for:

- named values;
- raw projection;
- detached proofs;
- existential packaging;
- proof satisfaction.

That smaller core would make theoretical review easier.

### 16.9 List query proofs (`ForAll`)
**Implemented.**

`List T ::: ForAll P` is a compile-time annotation on list-returning functions that records "every element of this list satisfies proof predicate P". It is a type-level contract only — at runtime, the list is a plain Racket list with no per-element proof structs and zero overhead.

**Syntax:**
```tesl
fn listNotes(user: String ::: Authenticated user)
  -> List Note ? ForAll (FromDb (AuthorId == user))
  requires [noteDbRead] =
  select note from Note where note.authorId == user
```

**Rules:**
- `ForAll P` is valid on `List T` and `Set T` return types (and their `Maybe (...)` wrappers). Applying it to any other type is a compile error.
- `select ... from Entity where ...` automatically produces `List Entity ::: ForAll (FromDb ...)`.
- `List.filterCheck checkFn xs` produces a `ForAll` list of the check function's proof predicate.
- `List.allCheck checkFn xs` validates every element: returns `Nothing` if any fail, `Something list` if all pass — return type is `Maybe (List T ::: ForAll P)`.
- `Set.filterCheck checkFn s` — same as `List.filterCheck` but for sets: keeps elements that pass, returns `Set T ::: ForAll P`.
- `Set.allCheck checkFn s` — same as `List.allCheck` but for sets: returns `Nothing` if any element fails, `Something (Set T ::: ForAll P)` if all pass.
- `List.filter pred xs` does NOT produce a `ForAll` list — the predicate is opaque to the compiler. Likewise `Set.filter`.
- Inline `value ::: ForAll P` in a function body is rejected with a clear error.
- An empty list literal `[]` does **not** vacuously satisfy any `ForAll P` at **call sites** — passing `[]` to a function that requires `List T ::: ForAll P` is rejected. To construct an empty list that satisfies `ForAll P`, use `List.emptyForAll checkP` where `checkP` is the `check` function that establishes `P`. This makes the intent explicit rather than implicit. Note: returning `[]` directly from a `ForAll`-typed function body is currently accepted (the static checker does not enforce the requirement at return sites), but `List.emptyForAll` is still the recommended and explicit idiom.

Return type: use the ? operator — -> List T ? ForAll P. The explicit subject form -> T ::: ForAll P xs is not supported in return position. The ? operator automatically inserts the entity subject.

Parameter type: use ::: with explicit subject — xs: List T ::: ForAll P xs.

**ForAll proof expansion** — proofs combine, never replace:
```tesl
fn narrowToSmall(xs: List Int ::: ForAll (IsPositive) xs)
  -> List Int ? ForAll (IsPositive && IsSmall)  -- P1 AND P2
  requires [] =
  List.filterCheck checkIsSmall xs
```
When `filterCheck` or `allCheck` is called on a list already annotated with `ForAll P1`, the programmer declares the expanded combined proof `ForAll (P1 && P2)` in the return type. The compiler accepts this; the programmer is responsible for the logical soundness of the combined claim.

**Check combination with `&&`:**
```tesl
fn filterBoth(xs: List Int) -> List Int ? ForAll (IsPositive && IsSmall)
  requires [] =
  List.filterCheck (checkIsPositive && checkIsSmall) xs
```
`checkA && checkB` composes two check/establish/auth functions: runs `checkA` first; if it passes, runs `checkB` on the result; if either fails the element is rejected. Right-associative: `checkA && checkB && checkC` = `checkA → checkB → checkC`. Works for `check`, `establish`, and `auth` functions, and mixed combinations.

**General-case `&&` — applying a combined check to a single value:**

The `&&` operator can be used beyond list operations. You can apply a combined check directly to a single value with ML-style application:

```tesl
let r = (checkActive && checkPinned) note
```

Or pass the combined checker itself as a first-class value to collection helpers:

```tesl
List.filterCheck (checkActive && checkPinned) notes
```

The combined checker itself still compiles to `(check-and checkActive checkPinned)` in Racket, but to run it as a check you must use the `check` keyword at the call site: `check (checkActive && checkPinned) note`. This is fail-fast validation: it behaves like nested checks, returning the validated value with the combined proof attached and failing on the first failing check. Use `establish` when you want a recoverable proof attempt instead.

**`List.allCheck`:**
```tesl
fn verifyBatch(notes: List Note)
  -> Maybe (List Note ::: ForAll (IsActive && IsPinned))
  requires [] =
  List.allCheck(checkActive && checkPinned, notes)
```
Unlike `filterCheck` (which drops failures), `allCheck` is all-or-nothing: if any element fails the check, the entire result is `Nothing`. Use when you want to accept a batch only if it is fully valid.

**`Maybe (List T ::: ForAll P)` return type:** valid as a first-class return spec. Emits `(Maybe (List T))` in Racket — the `ForAll` annotation is stripped.

**ForAll in parameter types:**
```tesl
fn countActive(notes: List Note ::: ForAll (IsActive)) -> Int requires [] =
  List.length(notes)
```
The `ForAll` annotation is stripped from the Racket binding; it is a static type-level annotation only.

**Not dependent types.** `ForAll`, check combination, and `allCheck` are a finite set of structural rules in the compiler — not term-level quantifiers. No dependent types infrastructure is required.

See also: `example/learn/lesson29-forall-list-proofs.tesl` (List ForAll), `example/learn/lesson30-forall-set-proofs.tesl` (Set ForAll).

### 16.9a Dict proof quantifiers (`ForAllValues`, `ForAllKeys`)
**Implemented.**

`Dict K V ::: ForAllValues P` and `Dict K V ::: ForAllKeys P` are compile-time annotations on dict-returning functions that record "every value (or key) of this dict satisfies proof predicate P". Like `ForAll`, these are type-level contracts only — at runtime the dict is a plain Racket hash with zero overhead.

**Syntax:**
```tesl
fn getVerifiedCache(raw: Dict String String)
  -> Dict String String ::: ForAllValues IsAuthenticated
  requires [] =
  let checked = Dict.filterCheckValues checkIsAuthenticated raw in
  ok checked ::: ForAllValues (IsAuthenticated)

fn getByValidKeys(raw: Dict String User)
  -> Dict String User ::: ForAllKeys IsValidEmail
  requires [] =
  let checked = Dict.filterCheckKeys checkIsValidEmail raw in
  ok checked ::: ForAllKeys (IsValidEmail)
```

**Filter functions:**
- `Dict.filterCheckValues : (V -> V) -> Dict K V -> Dict K V` — applies a `check` function to each value; keeps entries that pass, drops entries where the check fails. The `ForAllValues P` annotation is established at the call site.
- `Dict.filterCheckKeys : (K -> K) -> Dict K K -> Dict K V` — applies a `check` function to each key; keeps entries with valid keys (using the checked key), drops entries where the check fails. The `ForAllKeys P` annotation is established at the call site.

**Rules:**
- `ForAllValues P` is valid only on `Dict K V` return types. Applying it to `List`, `Set`, or any other type is a compile error.
- `ForAllKeys P` is valid only on `Dict K V` return types. Applying it to any other type is a compile error.
- `Dict.filterCheckValues checkFn d` produces a `ForAllValues P` dict where P is the check function's proof predicate.
- `Dict.filterCheckKeys checkFn d` produces a `ForAllKeys P` dict where P is the check function's proof predicate.
- The `ok dict ::: ForAllValues (P)` proof must match the declared return predicate exactly.
- `Dict.filter pred d` does NOT produce a `ForAllValues` dict — the predicate is opaque to the compiler.

**Not dependent types.** `ForAllValues` and `ForAllKeys` follow the same finite structural rules as `ForAll` — they are not term-level quantifiers.


**Implemented — including horizontal scaling via LISTEN/NOTIFY.**

All constructs are fully implemented with the PostgreSQL backend. The chat example (`example/chat/`) demonstrates the complete feature set.

**Queue** (`tesl_jobs` table): `enqueue!` inserts within the current transaction and issues `NOTIFY tesl_queue_<name>` (deferred to commit); the three-thread worker model (fallback poller + LISTEN connection + SKIP LOCKED worker) handles both single-process and multi-process deployments. Failed jobs are retried with exponential or fixed backoff; exhausted jobs become `dead`. Dead jobs are handled by `deadWorker`/`deadWorkers`/`startDeadWorkers` — a separate poll loop that runs dead-letter handlers which can publish compensating events, send alerts, or acknowledge the failure.

**Pub/sub** (`tesl_pubsub_outbox` table): `publish` inside `with transaction` writes to the outbox atomically and issues `NOTIFY tesl_pubsub` with the row ID (deferred to commit); `serve` automatically starts a LISTEN thread (when SSE endpoints and PostgreSQL are active) that fetches and delivers outbox rows to connected SSE clients, with a 5-second fallback poller for missed notifications.

**In-memory fallback**: when no PostgreSQL context is active (unit tests), all operations use the in-memory store — no database required. Design archived in `future-roadmap/completed/well_designed_reactivity_design.md`.

### 16.10 Previously open areas now resolved
**Implemented.**

The following design areas were open in earlier drafts and are now resolved:

- **Native Cache** — resolved and implemented. See §19.
- **Email Support** — resolved and implemented. See §20.
- **Outgoing HTTP client** — resolved and implemented via `Tesl.HttpClient`. See §21.3.
- **UUID generation and validation** — resolved and implemented via `Tesl.UUID`. See §21.1.
- **JWT signing and verification** — resolved and implemented via `Tesl.JWT`. See §21.2.
- **Step debugger (Phase 0+1)** — resolved and implemented. See §22. Phases 2–4 remain open.

## 17. Worked examples
### 17.1 Valid proof transport
```tesl
#lang tesl
module Example exposing [listen, bootstrap]
import Tesl.Prelude exposing [attachFact, Int, Fact]

establish validPort(port: Int) -> Maybe(Fact (ValidPort port)) =
  if 1 <= port && port <= 65535 then
    ValidPort port
  else
    Nothing

fn listen(port: Int ::: ValidPort port) -> Int =
  port

fn bootstrap(port: Int) -> Int =
  let mPortProof = validPort port
  case mPortProof of
    Something portProof -> listen <| port ::: portProof
    Nothing -> ....
```

### 17.2 Invalid cross-subject proof reuse
```tesl
#lang tesl
module BadExample exposing [bad]
import Tesl.Prelude exposing [attachFact, Int, Fact]

establish validPort(port: Int) -> Maybe(Fact (ValidPort port)) =
  if 1 <= port && port <= 65535 then
    ValidPort port
  else
    Nothing

fn listen(port: Int ::: ValidPort port) -> Int =
  port

fn bad(x: Int, y: Int) -> Int =
  let mxProof = validPort x
  case mxProof of
    Something mProof -> listen <| y ::: xProof
    Nothing -> ...
```

This is invalid because `xProof` is about the subject of `x`, not the subject of `y`.

### 17.3 `forgetFact` preserves identity but not evidence
```tesl
#lang tesl
module ForgetExample exposing [roundTrip]
import Tesl.Prelude exposing [attachFact, forgetFact, Int, Fact]

establish validPort(port: Int) -> Maybe(Fact (ValidPort port)) =
  if 1 <= port && port <= 65535 then
    Something <| ValidPort port
  else
    Nothing

fn listen(port: Int ::: ValidPort port) -> Int =
  port

fn roundTrip(port: Int) -> Int =
  let mValidProof = validPort port
  case mValidProof of
    Something validProof ->
      let checked = port ::: validProof
      let forgotten = forgetFact checked
      listen <| forgotten ::: validPort port
    Nothing -> ...
```

`forgetFact` does not produce a raw `Int`; it produces the same named subject with no attached proof facts.

### 17.4 Illegal shadowing
```tesl
#lang tesl
module Shadowing exposing []
import Tesl.Prelude exposing [Int]

fn bad(x: Int) -> Int =
  let x = 1
  x
```

This is invalid because the inner `x` would shadow a proof-relevant outer binder.

## 18. Canonical guidance for future language changes
Any new Tesl feature that touches proofs, names, existentials, or effects should be justified in terms of this core model.

In particular, new syntax should not be accepted unless it can answer all of the following clearly:

- What hidden subject does the value denote?
- What facts are attached, detached, forgotten, or transported?
- Does the feature preserve the no-shadowing rule?
- Can it accidentally retarget a proof to a different subject?
- Can it cause an existential witness to escape?
- Does it fit the effect model, especially the capability rule and the telemetry exception?
- How does the feature elaborate to the existing core machinery?

If a proposed feature cannot be explained cleanly in those terms, it should not yet be part of the language.

## 19. Native Cache
**Implemented.**

A `cache` declaration creates a typed, name-scoped cache backed by a PostgreSQL `UNLOGGED` table. The unlogged storage provides write performance comparable to Redis while retaining the transactional guarantees of PostgreSQL. An in-memory hash is used as a fallback when no PostgreSQL context is active (unit tests, development).

### 19.1 Declaration syntax

```text
<cache-decl> ::= "cache" <identifier> "{"
                   "database" ":" <identifier>
                   "defaultTtl" ":" <integer>
                   "valueType" ":" <type-expr>
                 "}"
```

```tesl
cache UserProfileCache {
  database:   MainDB
  defaultTtl: 3600
  valueType:  UserProfile
}

cache ProductListCache {
  database:   MainDB
  defaultTtl: 300
  valueType:  List Product
}
```

Each `cache` block declares:
- `database` — the `database` declaration that backs this cache. The compiler emits the `tesl_cache` unlogged table into that database schema automatically.
- `defaultTtl` — default time-to-live in seconds. Individual `Cache.set` calls may override this.
- `valueType` — the Tesl type of stored values. The compiler derives the codec automatically; no user annotation is needed.

### 19.2 Capability

Each named cache declares its own capability token: `cache CacheName` (where `CacheName` is the declared identifier). The capability name uses a space, which the compiler normalises to an underscore in the generated Racket identifier (`cache_CacheName`).

```tesl
capability appService implies cache UserProfileCache
```

A handler that reads or writes `UserProfileCache` must declare `cache UserProfileCache` in its `requires` list (directly or transitively via `implies`):

```tesl
handler getProfile(id: String) -> UserProfile
  requires [dbRead, cache UserProfileCache] =
  ...
```

### 19.3 Operations

```text
Cache.get      CacheName key               # -> Maybe ValueType
Cache.set      CacheName key value         # -> Unit (uses defaultTtl)
Cache.set      CacheName key value ttl     # -> Unit (overrides defaultTtl; ttl in seconds)
Cache.delete   CacheName key               # -> Unit
Cache.invalidate CacheName prefix          # -> Unit (deletes all keys with this prefix)
```

`Cache.get` returns `Maybe ValueType` where `ValueType` is the type declared in the `cache` block. The return type is statically known — no runtime cast is needed. If no entry exists for `key`, `Nothing` is returned.

`Cache.invalidate` is a prefix scan: it deletes every entry whose key starts with `prefix`. This is useful for cache tag patterns such as invalidating all `"user_<id>_*"` entries when a user record changes.

### 19.4 Stale-entry handling

If a stored value cannot be deserialized (for example because the application was redeployed with new required fields on `ValueType`), the runtime silently deletes the entry and returns `Nothing`. The cache degrades gracefully across schema evolution. There is no error propagation.

### 19.5 Transactional cache writes

`Cache.set`, `Cache.delete`, and `Cache.invalidate` inside a `with transaction` block participate in the surrounding PostgreSQL transaction atomically. This eliminates the dual-write problem that arises when a separate Redis cache is used alongside PostgreSQL: if the transaction rolls back, no cache mutation is committed.

```tesl
handler updateProfile(userId: String, req: UpdateProfileRequest)
  -> UserProfile
  requires [dbWrite, cache UserProfileCache] =
  with transaction {
    let updated = update ... in User ...
    Cache.delete UserProfileCache ("profile_" ++ userId)
    updated
  }
```

### 19.6 Background sweeper

A sweeper thread runs every 60 seconds and deletes expired rows (`expires_at < NOW()`). No application code is needed to trigger expiry cleanup.

### 19.7 Worked example

```tesl
import Tesl.Maybe exposing [Maybe, Something, Nothing]

cache UserProfileCache {
  database:   MainDB
  defaultTtl: 3600
  valueType:  UserProfile
}

handler getUserProfile(id: String) -> UserProfile
  requires [dbRead, cache UserProfileCache] =
  let cached = Cache.get UserProfileCache ("profile_" ++ id)
  case cached of
    Something profile ->
      profile
    Nothing ->
      let profile = selectOne p from UserProfile where p.id == id
      Cache.set UserProfileCache ("profile_" ++ id) profile
      profile
```

---

## 20. Email Support
**Implemented.**

Tesl provides native transactional email via the outbox pattern: `Email.send` writes a row to a `tesl_email_outbox` table inside the current database transaction. A background worker thread polls for pending rows and delivers via SMTP with exponential-backoff retry. If the surrounding transaction rolls back, the email row is never inserted and no email is ever sent.

### 20.1 Declaration syntax

```text
<email-decl> ::= "email" <identifier> "{"
                   "database" ":" <identifier>
                   "smtp" "{"
                     "host"     ":" <expr>
                     "port"     ":" <integer>
                     "username" ":" <expr>
                     "password" ":" <expr>
                     "tls"      ":" ( "true" | "false" )
                   "}"
                 "}"
```

```tesl
email AppEmail {
  database: MainDB
  smtp {
    host:     env("SMTP_HOST")
    port:     587
    username: env("SMTP_USER")
    password: env("SMTP_PASS")
    tls:      true
  }
}
```

Multiple `email` blocks can coexist, each backed by the same or a different database.

### 20.2 Capability

The capability is `email` — a single shared token, not name-specific. Any function that calls `Email.send` must declare `requires [email]`:

```tesl
capability appService implies email

fn sendWelcomeEmail(to: String) -> Unit requires [email] =
  Email.send AppEmail {
    to:      to
    subject: "Welcome!"
    text:    "Welcome to the service."
    html:    "<h1>Welcome!</h1>"
  }
```

### 20.3 Operations

**`Email.send`** — fire-and-queue, non-blocking:

```text
Email.send EmailName {
  to:      String
  subject: String
  text:    String      # optional — plain-text body
  html:    String      # optional — HTML body
}
```

`Email.send` inserts a row into `tesl_email_outbox` and returns immediately. It does not open a TCP connection. At least one of `text` or `html` should be provided; both may be provided to send a multipart message.

**`startEmailWorker`** — starts the background delivery thread in `main`:

```text
startEmailWorker EmailName
```

This statement must appear inside a `with database` block in `main`, before `serve`. Without it, rows accumulate in the outbox but are never delivered.

```tesl
main with capabilities [appService] {
  with database MainDB {
    with capabilities [appService] {
      startEmailWorker AppEmail
      serve MyServer on port with capabilities [appService]
    }
  }
}
```

### 20.4 Delivery model

The worker uses two threads:

- **Poller thread** — every 5 seconds, issues `SELECT ... FOR UPDATE SKIP LOCKED` on `tesl_email_outbox` for `pending` rows. On success, marks the row `sent`. On SMTP failure, increments `attempts` and sets `next_attempt_at` with exponential backoff: `5 minutes × 2^attempts`.
- **Cleanup thread** — every hour, deletes `sent` rows older than 24 hours.

After 5 failed attempts a row is marked `dead` and is no longer retried. Dead rows remain in the table for inspection.

### 20.5 Transactional atomicity

`Email.send` inside a `with transaction` block is part of the same database transaction. If the transaction rolls back, the row is never inserted and the email is never sent. This prevents sending notifications for events that did not actually persist.

```tesl
handler registerUser(req: RegistrationRequest) -> User requires [dbWrite, email] =
  with transaction {
    let user = insert User { id: newId, email: req.email }
    Email.send AppEmail {
      to:      req.email
      subject: "Welcome!"
      text:    "Your account has been created."
    }
    user
  }
```

If the `insert` or any subsequent step raises an exception, the transaction rolls back and no email row is committed.

---

## 21. Standard Library Extensions

This section documents three new modules added to the Tesl standard library.

### 21.1 `Tesl.UUID`
**Implemented.**

Provides UUID generation and validation. Import:

```tesl
import Tesl.UUID exposing [uuid, UUID.v4, UUID.v7, UUID.validate, IsUuid,
                           uuidV4Codec, uuidV7Codec]
```

**Capability:** `uuid` — required by `UUID.v4` and `UUID.v7`. `UUID.validate` is a pure `check` function and requires no capability.

**Functions:**

| Function | Signature | Notes |
|---|---|---|
| `UUID.v4` | `() -> String` | Random UUID (RFC 4122 v4). Requires `uuid`. |
| `UUID.v7` | `() -> String` | Time-ordered UUID (RFC 9562 v7). Requires `uuid`. Better for database primary keys — monotonically increasing within a millisecond. |
| `UUID.validate` | `check (s: String) -> s: String ::: IsUuid s` | Validates UUID format (8-4-4-4-12 hex). No capability required. |

**Proof predicate:** `IsUuid s` — attached to the result of `UUID.validate` on success.

**JSON codecs:**

- `uuidV4Codec` — encodes/decodes UUID v4 strings. Decoder validates the UUID format.
- `uuidV7Codec` — encodes/decodes UUID v7 strings. Decoder validates the UUID format.

Use in codec blocks:

```tesl
codec CreateRequest {
  fromJson [
    { id <- "id" with_codec uuidV7Codec }
  ]
}
```

**Example:**

```tesl
import Tesl.UUID exposing [uuid, UUID.v4, UUID.v7, UUID.validate, IsUuid]

capability appService implies uuid

fn makeEntityId() -> String requires [uuid] =
  UUID.v7()

check validateId(s: String) -> s: String ::: IsUuid s =
  UUID.validate s

fn requiresValidId(id: String ::: IsUuid id) -> String = id
```

**`UUID.v7` for primary keys.** UUID v7 encodes a 48-bit millisecond timestamp in the most-significant bits, making newly-generated IDs sort later than older ones. This is preferable to v4 for database primary keys: index pages fill sequentially instead of randomly, which substantially reduces B-tree fragmentation at high insert rates.

### 21.2 `Tesl.JWT`
**Implemented.**

Provides JSON Web Token signing, verification, and decoding using HMAC-SHA256 (HS256). Import:

```tesl
import Tesl.JWT exposing [jwt, JwtToken, JwtSecret, JWT.sign, JWT.verify, JWT.decode]
```

**Capability:** `jwt` — required by all three operations.

**Nominal newtypes:**

- `JwtToken` — wraps `String`. Represents a signed JWT (`header.payload.signature`). Not interchangeable with `String` — the type system prevents passing a raw string where a `JwtToken` is expected, and vice versa.
- `JwtSecret` — wraps `String`. Represents the HMAC signing key. Nominal separation ensures that secrets cannot be accidentally swapped with tokens or plain strings.

**Functions:**

| Function | Signature | Notes |
|---|---|---|
| `JWT.sign` | `(claims: a) (secret: JwtSecret) -> JwtToken` | Signs an arbitrary record as claims. Requires `jwt`. |
| `JWT.verify` | `(token: JwtToken) (secret: JwtSecret) -> a` | Verifies signature and expiry. Fails 401 on bad signature or expired token. Requires `jwt`. |
| `JWT.decode` | `(token: JwtToken) -> a` | Decodes payload without verifying signature. Use only for non-security-critical inspection. Requires `jwt`. |

`JWT.sign` accepts any Tesl record as the claims payload. `JWT.verify` and `JWT.decode` return the same record type — the compiler infers the type from context.

**Algorithm:** HS256 (HMAC-SHA256). The header is always `{"alg":"HS256","typ":"JWT"}`.

**Example:**

```tesl
import Tesl.JWT exposing [jwt, JwtToken, JwtSecret, JWT.sign, JWT.verify]

capability authService implies jwt

record TokenClaims {
  sub: String
  exp: Int
}

fn issueToken(userId: String, secret: JwtSecret) -> JwtToken requires [jwt] =
  let claims = TokenClaims { sub: userId, exp: nowMillis() + 3600000 }
  JWT.sign claims secret

fn authenticate(token: JwtToken, secret: JwtSecret) -> TokenClaims requires [jwt] =
  JWT.verify token secret
```

### 21.3 `Tesl.HttpClient`
**Implemented.**

Provides outgoing HTTP requests. Import:

```tesl
import Tesl.HttpClient exposing [httpClient, HttpResponse,
                                 HttpClient.get, HttpClient.post,
                                 HttpClient.put, HttpClient.delete]
```

**Capability:** `httpClient` — required by all four functions. The identifier is camelCase to match Tesl identifier rules.

**`HttpResponse` record:**

```tesl
record HttpResponse {
  status:  Int
  body:    String
  headers: List (Tuple2 String String)
}
```

**Functions:**

| Function | Signature | Notes |
|---|---|---|
| `HttpClient.get` | `(url: String) (headers: List (Tuple2 String String)) -> HttpResponse` | Issues a GET request. |
| `HttpClient.post` | `(url: String) (headers: List (Tuple2 String String)) (body: String) -> HttpResponse` | Issues a POST request with a string body. |
| `HttpClient.put` | `(url: String) (headers: List (Tuple2 String String)) (body: String) -> HttpResponse` | Issues a PUT request with a string body. |
| `HttpClient.delete` | `(url: String) (headers: List (Tuple2 String String)) -> HttpResponse` | Issues a DELETE request. |

All functions are synchronous and block until the response is received. Both `http://` and `https://` schemes are supported.

**Example:**

```tesl
import Tesl.HttpClient exposing [httpClient, HttpResponse,
                                 HttpClient.get, HttpClient.post]
import Tesl.Tuple exposing [Tuple2]

capability appService implies httpClient

handler fetchExternalUser(id: String) -> HttpResponse requires [httpClient] =
  let url     = "https://api.example.com/users/" ++ id
  let headers = [Tuple2 "Accept" "application/json",
                 Tuple2 "Authorization" "Bearer token"]
  HttpClient.get url headers
```

**Header lists.** Headers are `List (Tuple2 String String)` — a list of name/value pairs. Pass `[]` for requests with no custom headers.

**Response inspection.** Inspect `response.status` (HTTP status code) and `response.body` (raw response body string). Parse JSON bodies with the standard codec layer or with `Dict`/`String` operations.

---

## 22. Step Debugger
**Phase 0+1 Implemented. Phases 2–4 Open.**

Tesl provides a source-level step debugger using the Debug Adapter Protocol (DAP), integrated with the VSCode extension.

### 22.1 Architecture

```
VSCode
  │  DAP JSON-RPC over stdio
  ▼
dsl/debug/dap-server.rkt    — DAP protocol handler
  │  spawns compiled .rkt with debug instrumentation
  ▼
dsl/debug/checkpoint.rkt    — (thsl-src file line expr) macro
  │  signals stopped events via Racket channels
  ▼
dap-server.rkt              — receives stopped events, serves variables/stackTrace
```

### 22.2 Compiling with debug instrumentation

Pass `--debug` to the Tesl compiler:

```bash
tesl --debug file.tesl
```

When `--debug` is active:
1. Every emitted expression is wrapped with `(thsl-src "file.tesl" LINE expr)` using the `loc` of the AST node.
2. A `.tesl.srcmap.json` sidecar file is written alongside the compiled `.rkt`. It maps Tesl source lines to generated Racket lines:

```json
{
  "tesl_file": "foo.tesl",
  "entries": [
    { "tesl_line": 12, "rkt_line": 47 },
    ...
  ]
}
```

The sidecar allows the DAP server to translate VSCode breakpoint line numbers into the correct Racket positions.

### 22.3 VSCode integration

The `editor/vscode-tesl` extension contributes a `debuggers` entry in `package.json`. Launching `Debug Tesl Program` via VSCode:

1. Invokes `editor/vscode-tesl/debug/launch-dap.sh` which starts `dsl/debug/dap-server.rkt` via Racket.
2. The DAP server compiles the `.tesl` file with `--debug`, loads the compiled `.rkt`, and runs it with `debug-enabled? = true`.
3. Breakpoints set in VSCode are sent via `setBreakpoints` DAP messages. The `(thsl-src ...)` macro checks for a matching breakpoint, sends a stopped event, and waits on a resume channel.
4. The variables panel calls `variables` → the `locals-thunk` captured at the pause point, which uses `thsl-display-value` to unwrap GDP proof wrappers and show plain user-level values.

**GDP value unwrapping in the debugger.** The `thsl-display-value` helper unwraps the runtime evidence layer before display: `named-value` structs are shown as their raw value (with proof tags listed as annotations), `newtype-value` is shown as its inner value, and `record-value` fields are recursed. The user sees the application-level value, not the proof-carrying runtime wrapper.

### 22.4 Phase 1 capabilities (implemented)

- Breakpoints at statement and function level.
- `continue` resumes execution.
- Local variable inspection (proof-unwrapped values).
- Stack trace showing the currently paused function and source location.

### 22.5 Deferred phases

| Phase | Feature | Status |
|---|---|---|
| 2 | Step-over (`next`) and step-into (`stepIn`) | **Open** — requires a `step-depth` parameter to track call depth. |
| 3 | GDP proof tags as variable annotations | **Open** — show `"Alice" [IsTrimmed, IsNonEmpty]` in the variables panel. |
| 4 | Conditional breakpoints | **Open** — pause only when a user expression is truthy. |
| 4 | Watch expressions | **Open** — user-defined expressions evaluated at each pause. |

---

## Appendix A. Current implementation divergences
This appendix is descriptive rather than normative.

### A.1 `const`
Resolved: the frontend rejects `const name = expr` at top level. Use `name = expr`; top-level bindings are immutable by default.

### A.2 Prelude / standard-library bootstrapping
The current frontend bootstraps some Prelude and ADT names specially. The intended language story is still that explicit imports and ordinary library definitions should carry as much of this surface as possible, including `Maybe` and `Result`.

### A.3 Application style
The primary application form is ML-style space-separated syntax (`f x y`). Parentheses are reserved for grouping (`f (g x)`) and grouped callees (`(checkA && checkB) x`). `<|` and `|>` provide low-precedence alternatives.

### A.4 Verbose ambient logging

**Implemented.** Activate at runtime with `TESL_VERBOSE=1`.

Tesl applications emit structured log lines to stderr for:
- HTTP requests and responses (method, path, status, elapsed ms)
- SQL queries emitted by the ORM (condensed single-line form + bound parameters)
- Queue `enqueue` and `dequeue` / `done` / `fail` events
- Pub/sub `publish` and `deliver` events

**Zero overhead when disabled.** `tesl-verbose?` is evaluated once at module load time from the `TESL_VERBOSE` environment variable. When it is `#f`, the only per-call cost is a single boolean read.

```bash
TESL_VERBOSE=1 racket your-compiled-app.rkt
```

Example output:
```
[TESL][HTTP] → POST /rooms/room-1/messages
[TESL][SQL] insert into "chat"."messages" ("id", ...) values ($1, ...) [msg-abc, ...]
[TESL][QUEUE] enqueue NotifyJob id=job-xyz
[TESL][PUBSUB] publish RoomMessages(room-1)
[TESL][PUBSUB] deliver outbox#42 RoomMessages(room-1) → 2 listener(s)
[TESL][HTTP] ← 200 POST /rooms/room-1/messages (18ms)
```

Implementation: `tesl/logging.rkt` + instrumented in `dsl/web.rkt`, `dsl/sql.rkt`, `tesl/queue.rkt`.
