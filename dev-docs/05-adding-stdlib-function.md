# 05 — Adding a Standard Library Function
This guide describes the current compiler/runtime path for standard library functions. Older Python-era instructions are obsolete; the active implementation is split between the OCaml compiler and the Racket runtime modules.
## Current moving pieces
When you add a stdlib function, there are usually four places to think about:
1. runtime implementation in `tesl/*.rkt`
2. Racket module-path resolution in `compiler/lib/emit_racket.ml`
3. type information in `compiler/lib/type_system.ml`
4. import validation in `compiler/lib/type_system.ml` and `compiler/lib/checker.ml`
## Case A: add a function to an existing stdlib module
Example: adding `String.foo` to `Tesl.String`.
### 1. Implement and export it in the runtime module
Add the Racket implementation to the module file that actually backs the stdlib surface, for example:
- `tesl/string.rkt`
- `tesl/list.rkt`
- `tesl/dict.rkt`
Make sure it is exported from that Racket module.
### 2. Add its type to `Type_system.stdlib_env`
The type checker resolves stdlib functions from `compiler/lib/type_system.ml` via `stdlib_env` and `make_stdlib_env`.
For module-qualified functions, add the qualified Tesl name directly, for example:
- `"String.length"`
- `"List.map"`
- `"Int.parse"`
If the function is also available unqualified, add the unqualified entry too.
### 3. Add the name to the module export list
`compiler/lib/type_system.ml` contains `tesl_module_exports`, the authoritative export lists for `import Tesl.X exposing [...]` validation.
Add the function name to the correct module entry, for example the `Tesl.String` list.
If you skip this step, the function may exist at runtime but the compiler will reject explicit imports of it.
### 4. Verify qualified-name behavior
Qualified stdlib calls such as `String.length(x)` are type-checked through the stdlib environment. For most additions, updating `stdlib_env` is enough.
If you introduce a brand-new qualifier/module name, also check `known_qualifier_modules` in `compiler/lib/checker.ml`.
## Case B: add an entirely new stdlib module
If you are adding something like `Tesl.Regex` rather than extending an existing module, there are extra steps.
### 1. Add the new runtime module
Create the backing Racket file under `tesl/`, for example `tesl/regex.rkt`, and export the public bindings.
### 2. Register its require path in `emit_racket.ml`
`compiler/lib/emit_racket.ml` uses `module_path_table` to map `Tesl.*` module names to runtime file paths.
Add a new entry there so generated Racket can require the module.
### 3. Register the module as known to the compiler
Add the module name to `tesl_known_module_names` in `compiler/lib/type_system.ml`.
Without this, `import Tesl.NewModule ...` is rejected as an unknown stdlib module.
### 4. Add an export list if imports should be checked strictly
If the module has a stable public surface, add it to `tesl_module_exports`.
If you intentionally want loose import validation for an internal module, you can leave it out of `tesl_module_exports` while still listing it in `tesl_known_module_names`.
### 5. Add type entries for the module’s functions/types
Add the relevant function/type constructor entries to `stdlib_env` so the type checker can resolve them.
## Case C: lifted modules — combinators written in Tesl, not Racket

Some stdlib modules now keep their **pure, leaf-free combinators in Tesl
source** instead of hand-written Racket. This is the "smaller core" path: the
language implements its own standard library, the OCaml checker infers the
combinator types directly from the `.tesl` source (no `stdlib_env` rows), and
the trusted hand-written Racket surface shrinks to irreducible leaves only.

Two modules use this path today: **`Tesl.List`** (16 combinator bodies lifted;
leaves head/tail/append live in `Tesl.ListPrim`) and **`Tesl.Either`** (10
combinators lifted; the `define-adt` lives in `Tesl.EitherPrim`).

### The two halves of a lifted module

1. **Leaf half (hand-written Racket).** The irreducible primitives that pure
   Tesl cannot express — list deconstruction (`car`/`cdr`), `define-adt`,
   hash/set construction, float math, numeric parsing, and **all proof/GDP
   machinery** (`validate-runtime-argument`, `attach`, `check`-backed
   functions). These stay in a `*-prim.rkt` (or the shim) and keep their types
   in `stdlib_env`.
2. **Lifted half (Tesl source → generated Racket).** The pure combinators are
   written as real recursive Tesl in `tesl/<mod>.tesl`. The compiler:
   - **infers their types** from that source via
     `Checker.load_imported_func_sigs` → `load_lifted_sigs`, gated by
     `lifted_stdlib_basename` (`checker.ml`) — so their `stdlib_env` rows are
     **deleted**; and
   - **compiles their bodies** (build time) to a committed snapshot
     `tesl/<mod>-derived.rkt` (see *Build* below). The public shim
     `tesl/<mod>.rkt` re-exports those compiled bodies under the dotted
     `Module.fn` runtime names via `(only-in "<mod>-derived.rkt" [fn Module.fn] …)`.

### The require-cycle rule (do not skip)

A compiled `<mod>.tesl` whose bodies delegate to leaf functions/constructors of
its OWN module emits `(require tesl/tesl/<mod> …)` — i.e. it requires the shim.
If the shim also requires `<mod>-derived.rkt`, Racket fails with **"cycle in
loading"**. Break it by putting the leaves the bodies need in a **separate
`Tesl.<Mod>Prim` module** (`list-prim`, `either-prim`) that both the shim and
`<mod>-derived.rkt` require, and which requires neither. Have `<mod>.tesl`
`import Tesl.<Mod>Prim` for those leaves so the generated require points at the
prim module, not the shim. (Combinators that delegate only to *operators*
— e.g. arithmetic — need no prim split, since their generated Racket requires
nothing from the module.) Use `only-in`, NOT bare `rename-in`, on the
`<mod>-derived.rkt` require: `rename-in` would import every bare provide of the
derived module and shadow Racket builtins (`length`, `take`, `min`, …) used by
the hand-written leaf bodies.

### Registering a lifted (or prim) module — checklist

For the lifted source module (e.g. `Tesl.List` / `Tesl.Either`):
- `Checker.lifted_stdlib_basename`: add `| "Tesl.X" -> Some "x.tesl"` so types
  load from source. **Delete** the lifted functions' rows from `stdlib_env`
  (keep leaf/constructor rows).

For a new prim module (e.g. `Tesl.ListPrim` / `Tesl.EitherPrim`):
- `Emit_racket.module_path_table`: `add "Tesl.XPrim" "tesl/x-prim.rkt";`
- `Type_system.tesl_module_exports`: an entry listing the prim's exports.
- `Type_system.tesl_known_module_names`: add `"Tesl.XPrim"`.
- Leaf types come from `stdlib_env` (constructors like `Left`/`Right`) or a
  lifted `x-prim.tesl` type source (`ListPrim.head/tail/append`), as
  appropriate. If the prim is referenced by a qualifier (`ListPrim.head`), add
  it to `Checker.known_qualifier_modules` and `Checker.stdlib_module_of_prefix`.

### Build: regenerating the `*-derived.rkt` snapshot

`tesl/` is **outside** the dune project root (`compiler/`), so a dune
`(mode promote)` rule cannot write these targets. Instead they are committed
generated snapshots (exactly like the byte-exact `example/learn/*.rkt`):
- `scripts/gen-stdlib-rkt.sh` regenerates them with the just-built `tesl`
  binary. Add a `"tesl/<mod>.tesl:tesl/<mod>-derived.rkt"` row to its `LIFTED`
  array when you lift a module.
- `compiler/ci.sh` runs `scripts/gen-stdlib-rkt.sh --check` and **fails the
  build if a snapshot has drifted** — so after editing a lifted `.tesl`, run the
  script and commit the regenerated `*-derived.rkt`.

### Invariants when lifting (hard requirements)

- **User emission must stay byte-identical.** Keep `module_path_table`'s entry
  and the shim's dotted `Module.fn` provides; user `.rkt` still requires
  `tesl/tesl/<mod>` and calls `tesl_import_Module_fn`. The 58-lesson byte-exact
  match (`test_integration`, `ci.sh` exact-match) is the gate.
- **Type-display must stay byte-identical.** Choose the `.tesl` type-variable
  names so `decl_scheme`'s alphabetical rigid-id assignment (`a`=-1, `b`=-2,
  `c`=-3) reproduces the deleted `stdlib_env` rows exactly.
- **Behavioral parity.** Keep a `<mod>` parity test (e.g.
  `tests/lifted-list-tests.{tesl,rkt}`) that exercises every lifted function;
  run it via `raco test` against the lifted runtime. Run `test_diag_snapshots`
  after each module — diagnostics for lifted functions must be byte-identical.
- **Leave proof machinery alone.** Never lift `check`/`establish`-backed
  functions or proof-consuming ones (`Int.divide`, `Dict.get`, `List.take`); they
  must remain Racket leaves.

## Constructors, types, and proof helpers
If the stdlib change introduces:
- new exported types
- new constructors
- proof-related helpers or proof-establishing behavior
then make sure the surrounding type/proof rules are still coherent.
Typical follow-up touchpoints are:
- `compiler/lib/checker.ml`
- `compiler/lib/proof_checker.ml`
- `compiler/lib/validation.ml`
Only change those when the new stdlib surface actually needs new compile-time behavior; many ordinary helper functions need no special handling beyond runtime + types + exports.

## Proof-consuming functions (important special case)

A **proof-consuming** stdlib function is one that calls `validate-runtime-argument` with a non-`#f` proof template — i.e. it actively validates that one of its arguments carries a specific GDP proof at runtime. Examples: `Int.divide` (requires `IsNonZero` on the divisor), `Dict.get` (requires `HasKey` on the dict), `Float.div` (requires `FloatNonZero` on the divisor).

These functions need special handling in the emitter. When a proof-annotated function parameter is passed to a proof-consuming function, the emitter must emit the GDP symbol (the named-value reference) rather than the raw `*name` value — otherwise the runtime proof lookup fails even though the static checker accepted the code.

**If your new stdlib function calls `validate-runtime-argument` with a non-`#f` proof template:**

1. Add its Racket import name to the `proof_consuming_stdlib` table in `compiler/lib/emit_racket.ml`:
   ```ocaml
   let proof_consuming_stdlib : (string, unit) Hashtbl.t =
     let h = Hashtbl.create 8 in
     List.iter (fun k -> Hashtbl.replace h k ())
       [ "tesl_import_Int_divide";
         "tesl_import_Int_modulo";
         "tesl_import_Float_div";
         "tesl_import_Dict_get";
         (* add your new function here *)
       ];
     h
   ```
   The Racket import name follows the pattern `tesl_import_Module_function` (e.g. `tesl_import_List_take` for `List.take`).

2. Add a runtime test that calls the function through a **function parameter boundary** — i.e. the proof is established in an outer function and the inner function takes it as a proof-annotated parameter:
   ```tesl
   fn helper(a: Int, b: Int ::: IsNonZero b) -> Int =
     Int.divide a b   # must work even though b came via parameter

   fn test(a: Int, b: Int) -> Int =
     let nz = check Int.nonZero b
     helper a nz
   ```
   This is the scenario the `proof_consuming_stdlib` table exists to fix. Without the table entry, the static check passes but the runtime fails.

The `is_comptime_only_proof` predicate (also in `emit_racket.ml`) controls which proof annotations are treated as compile-time-only (ForAll, IsSorted, etc.) vs runtime-evidence-carrying. If your function's proof predicate is a new kind of compile-time-only annotation, add it there too.
## Validation checklist
For any stdlib change, prefer this order:
1. add focused compiler tests for import/type behavior
2. add runtime/integration tests showing the emitted Racket actually works
3. add at least one adversarial regression if the function is proof-related, security-relevant, or easy to misuse
Useful places to look:
- `compiler/test/test_types.ml`
- `compiler/test/test_validation.ml`
- `compiler/test/test_integration.ml`
- `tests/tesl-test.rkt`
## Rule of thumb
If the change is “a new callable stdlib name,” update:
- the runtime module
- `Type_system.stdlib_env`
- `Type_system.tesl_module_exports`
And if the change is “a new stdlib module,” also update:
- `Emit_racket.module_path_table`
- `Type_system.tesl_known_module_names`
- possibly `Checker.known_qualifier_modules`
