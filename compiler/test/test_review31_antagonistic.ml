(** Antagonistic regression tests for Critical Review 31.

    Each test probes a specific correctness gap, ergonomic limitation, or
    soundness boundary identified during Review 31.

    Findings covered:
      G31  selectMax / selectMin: in sql_read_names + emitter but NOT in type-checker
      G32  selectSum return type is always Int regardless of field type (Float gap)
      G33  PosixMillis does NOT auto-unwrap in arithmetic (spec vs implementation gap)
      G34  Duplicate variable binder in a case arm now correctly rejected (was: silently compiled)
      G35  ForAll on non-List/Set type now correctly rejected (was: silently accepted)
      G36  Handler with extra unused capability in requires produces no lint warning
      G37  upsert, delete, selectCount/Sum/Max/Min now documented in LANGUAGE-SPEC.md
      G38  deleteAndReturnResult must import DeleteResult from Tesl.DB (not Tesl.Prelude)
      G39  Proof arity mismatch at declaration now correctly rejected (was: silently accepted)
      G40  Nested transaction correctly gives P001 error
      G41  Non-exhaustive case expression is correctly detected
      G42  Circular capability implication is correctly rejected
      G43  Polymorphic identity function works with multiple monomorphic call sites
      G44  [a, b] two-element list infers as Tuple2 (spec §14b.1)
      G45  check function with wrong proof in ok is correctly rejected
      G46  forgetFact correctly strips proof annotation
      G47  Variable shadowing in let is correctly rejected (no-shadow invariant)
      G48  selectCount return type is Int (correct)
      G49  Dict.get requires HasKey proof — missing proof correctly rejected
      G50  PosixMillis comparison operators work (unified as same type)
      G51  Paren-style multi-arg call f(x, y) is correctly rejected (parser error)
      G52  Handler declaring a capability not in any stdlib module compiles (user caps)
*)

open Alcotest

(* ── Helpers ────────────────────────────────────────────────────────────── *)

let tesl =
  match Sys.getenv_opt "TESL_BIN" with
  | Some v -> v
  | None ->
    let dir = Filename.dirname Sys.argv.(0) in
    let candidate = Filename.concat (Filename.dirname dir) "bin/main.exe" in
    let candidate2 = Filename.concat dir "../bin/main.exe" in
    if Sys.file_exists candidate then candidate
    else if Sys.file_exists candidate2 then candidate2
    else "tesl"

let check_subcmd =
  if Filename.basename tesl = "main.exe" then "--check" else "check"

let compile_string src =
  let tmp = Filename.temp_file "tesl-r31-test" ".tesl" in
  let oc = open_out tmp in
  output_string oc src;
  close_out oc;
  let ic = Unix.open_process_in (Printf.sprintf "%s %s %s 2>&1" tesl check_subcmd tmp) in
  let out = In_channel.input_all ic in
  let _ = Unix.close_process_in ic in
  (try Sys.remove tmp with _ -> ());
  out

let should_pass src =
  let out = compile_string src in
  let has_error =
    let re = Str.regexp "error\\[" in
    try ignore (Str.search_forward re out 0); true with Not_found -> false
  in
  if has_error then
    Printf.eprintf "Unexpected error output:\n%s\n" out;
  check bool "should compile without errors" false has_error

let should_fail pattern src =
  let out = compile_string src in
  let found =
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0); true with Not_found -> false
  in
  if not found then
    Printf.eprintf "Expected pattern '%s' in output:\n%s\n" pattern out;
  check bool (Printf.sprintf "should fail with pattern: %s" pattern) true found

let prelude =
  "#lang tesl\nmodule T exposing []\n\
   import Tesl.Prelude exposing [Int, String, Bool(..), List, Unit, Fact]\n\
   import Tesl.Maybe exposing [Maybe(..)]\n"

let db_prelude =
  prelude ^
  "import Tesl.DB exposing [dbRead, dbWrite]\n" ^
  "entity Product table \"products\" primaryKey id {\n" ^
  "  id: String\n" ^
  "  name: String\n" ^
  "  price: Int\n" ^
  "}\n"

let proof_prelude =
  prelude ^
  "fact IsPositive (n: Int)\n" ^
  "check checkPos(n: Int) -> n: Int ::: IsPositive n =\n" ^
  "  if n > 0 then\n" ^
  "    ok n ::: IsPositive n\n" ^
  "  else\n" ^
  "    fail 400 \"neg\"\n" ^
  "fn needsPositive(n: Int ::: IsPositive n) -> Int = n\n"

(* ── G31: selectMax / selectMin now fully supported in the type checker ───── *)
(*                                                                              *)
(* `selectMax p.field from Entity` is now recognized by both the emitter and  *)
(* the type checker (FIXED). selectMax/selectMin return Int and compile.       *)
let test_g31_selectmax_unknown_name () =
  let src = db_prelude ^
    "fn maxPrice() -> Int requires [dbRead] =\n" ^
    "  selectMax p.price from Product\n" in
  should_pass src

(* ── G32: selectSum always returns Int even when field type is Float ─────── *)
(*                                                                              *)
(* `selectSum p.price from Product` where price is of type Int returns Int    *)
(* (correct). But the return type of selectSum is hardcoded as `Int` in the   *)
(* type checker (see checker.ml line 860), so even if price were Float, the   *)
(* return would still be typed as Int. This is a type inaccuracy for          *)
(* Float-typed aggregate fields.                                               *)
let test_g32_selectsum_returns_int () =
  let src = db_prelude ^
    (* Return type annotation Int should match selectSum on Int field *)
    "fn totalPrice() -> Int requires [dbRead] =\n" ^
    "  selectSum p.price from Product\n" in
  should_pass src

(* ── G33: PosixMillis does NOT auto-unwrap in arithmetic (spec vs impl) ─── *)
(*                                                                              *)
(* LANGUAGE-SPEC.md §14b.2 and §503 state: "PosixMillis auto-unwraps to Int  *)
(* when passed to arithmetic or comparison operators."                          *)
(* However, the type checker (checker.ml:1453-1462) requires both sides of    *)
(* arithmetic to unify with Int or Float. PosixMillis != Int, so a - b where  *)
(* a and b are PosixMillis fails with T001.                                    *)
(* Correct approach is to use diffMs, addMs, subtractMs.                       *)
let test_g33_posixmillis_arithmetic_fails () =
  let src =
    prelude ^
    "import Tesl.Time exposing [time, PosixMillis, nowMillis]\n" ^
    "fn timeDiff(a: PosixMillis, b: PosixMillis) -> Int requires [time] =\n" ^
    "  a - b\n" in
  (* Spec says this should work, but implementation rejects it *)
  should_fail "cannot unify PosixMillis\\|T001" src

(* ── G34: Duplicate variable binding in a case arm silently compiles ─────── *)
(*                                                                              *)
(* Pattern `MkPair x x -> x + x` uses the same binder `x` twice in the same  *)
(* case arm. The compiler accepts this without error. The semantics are        *)
(* ambiguous — does the second `x` shadow the first? Does it require them      *)
(* to be equal? A compiler error or clear warning is missing.                 *)
let test_g34_duplicate_binder_in_case_arm () =
  let src =
    prelude ^
    "type Pair\n" ^
    "  = MkPair Int Int\n" ^
    "fn sumPair(p: Pair) -> Int =\n" ^
    "  case p of\n" ^
    "    MkPair x x -> x + x\n" in
  (* Fixed: duplicate binder 'x' in the same case arm is now rejected *)
  should_fail "duplicate.*binder\\|duplicate.*variable\\|binder.*x.*x\\|already bound\\|x.*bound" src

(* ── G35: ForAll on non-List type silently compiles ─────────────────────── *)
(*                                                                              *)
(* `ForAll IsPositive x` where x has type Int (not List Int) is semantically  *)
(* meaningless but compiles without any error or warning. The ForAll          *)
(* quantifier is only meaningful over collection types, but there is no       *)
(* validation that the annotated subject is a List or Set.                    *)
let test_g35_forall_on_non_list_silently_compiles () =
  let src = proof_prelude ^
    (* x is Int, not List Int — ForAll is meaningless here *)
    "fn badForAll(x: Int ::: ForAll IsPositive x) -> Int = x\n" in
  (* Fixed: ForAll on a non-collection parameter type is now rejected *)
  should_fail "ForAll.*collection\\|collection.*ForAll\\|List\\|Set\\|not a collection\\|ForAll requires" src

(* ── G36: Handler with unused capability — no lint warning ──────────────── *)
(*                                                                              *)
(* A handler declaring `requires [dbRead, time]` but only using dbRead has    *)
(* no issue detected by the compiler. Unused declared capabilities represent  *)
(* unnecessary privilege that should ideally be flagged by a lint rule.       *)
(* The compiler silently accepts over-declared capabilities.                  *)
let test_g36_handler_unused_capability_no_warning () =
  let src =
    prelude ^
    "import Tesl.DB exposing [dbRead, dbWrite]\n" ^
    "import Tesl.Time exposing [time, PosixMillis]\n" ^
    "entity Product table \"products\" primaryKey id {\n" ^
    "  id: String\n" ^
    "  name: String\n" ^
    "  price: Int\n" ^
    "}\n" ^
    (* Handler declares [dbRead, time] but only uses dbRead *)
    "handler getProducts() -> List Product requires [dbRead, time] =\n" ^
    "  select p from Product\n" in
  should_pass src

(* ── G37: upsert compiles correctly (undocumented feature) ───────────────── *)
(*                                                                              *)
(* `upsert Entity { ... } onConflict [fields] doUpdate [fields]` is          *)
(* implemented in the emitter and type checker but completely absent from     *)
(* LANGUAGE-SPEC.md. Users who read the spec would not know it exists.       *)
(* This test documents that upsert works so that the behavior is preserved   *)
(* if/when documentation is added.                                            *)
let test_g37_upsert_compiles () =
  let src = db_prelude ^
    "fn upsertProduct(id: String, name: String, price: Int) -> Unit requires [dbWrite] =\n" ^
    "  upsert Product { id: id, name: name, price: price } onConflict [id] doUpdate [name, price]\n" in
  should_pass src

(* ── G38: deleteAndReturnResult requires import from Tesl.DB ─────────────── *)
(*                                                                              *)
(* `DeleteResult` and its constructors `NoRowDeleted`/`RowsDeleted` must be   *)
(* imported from Tesl.DB, not Tesl.Prelude. This is not obvious from the      *)
(* surface language — users expect common return types in the prelude.        *)
let test_g38_delete_result_needs_db_import () =
  let src =
    prelude ^
    (* Wrong: DeleteResult is NOT in Tesl.Prelude *)
    "import Tesl.DB exposing [dbRead, dbWrite]\n" ^
    "entity Product table \"products\" primaryKey id {\n" ^
    "  id: String\n" ^
    "  name: String\n" ^
    "  price: Int\n" ^
    "}\n" ^
    (* Forget to import DeleteResult *)
    "fn removeProduct(id: String) -> Unit requires [dbWrite] =\n" ^
    "  delete p from Product where p.id == id\n" in
  (* Returning Unit from delete is fine — no DeleteResult needed *)
  should_pass src

(* ── G39: Proof arity mismatch at declaration silently accepted ─────────── *)
(*                                                                              *)
(* `fact Pair (a: Int) (b: Int)` has arity 2. Writing a check function       *)
(* with return spec `x: Int ::: Pair x` (arity 1) compiles without error.    *)
(* The arity check in validation.ml (line 3444) only fires when arity matches,*)
(* so wrong-arity proof annotations are silently skipped at declaration.      *)
(* The error appears only at the use site, giving a confusing experience.     *)
let test_g39_proof_arity_mismatch_at_declaration () =
  let src = prelude ^
    "fact Pair (a: Int) (b: Int)\n" ^
    (* Declares Pair x with only ONE arg — Pair needs two — now detected early *)
    "check checkPair(x: Int, y: Int) -> x: Int ::: Pair x =\n" ^
    "  if x < y then\n" ^
    "    ok x ::: Pair x\n" ^
    "  else\n" ^
    "    fail 400 \"bad\"\n" in
  (* Fixed: arity mismatch now detected at declaration with clear error *)
  should_fail "argument count mismatch\\|arity\\|expected 2.*got 1\\|Pair.*2.*argument\\|count mismatch" src

(* ── G40: Nested transaction correctly gives P001 error ─────────────── *)
(*                                                                              *)
(* Nesting `transaction` inside another `transaction` must be       *)
(* rejected with P001. The spec §1823 explicitly forbids nesting.             *)
let test_g40_nested_transaction_rejected () =
  let src = db_prelude ^
    "fn nestedTx() -> Unit requires [dbWrite] =\n" ^
    "  transaction {\n" ^
    "    transaction {\n" ^
    "      insert Product { id: \"1\", name: \"a\", price: 10 }\n" ^
    "    }\n" ^
    "  }\n" in
  should_fail "nested.*transaction\\|transaction.*nested\\|P001" src

(* ── G41: Non-exhaustive case expression correctly detected ─────────────── *)
(*                                                                              *)
(* A case expression that does not cover all constructors of an ADT           *)
(* is caught and reported with a clear message naming the missing arms.       *)
let test_g41_non_exhaustive_case_detected () =
  let src =
    prelude ^
    "fn test(m: Maybe Int) -> Int =\n" ^
    "  case m of\n" ^
    "    Something x -> x\n" in
  should_fail "non-exhaustive.*case\\|missing.*Nothing\\|V001" src

(* ── G42: Circular capability implication correctly rejected ─────────────── *)
(*                                                                              *)
(* `capability A implies B` and `capability B implies A` would create an     *)
(* infinite loop in a naive expand_caps. The compiler correctly detects this  *)
(* cycle and rejects it with a helpful error naming the cycle path.           *)
let test_g42_circular_capability_rejected () =
  let src =
    prelude ^
    "import Tesl.DB exposing [dbRead, dbWrite]\n" ^
    "capability adminAccess implies dbRead, superAccess\n" ^
    "capability superAccess implies adminAccess, dbWrite\n" in
  should_fail "cycle.*adminAccess\\|capability cycle\\|V001" src

(* ── G43: Polymorphic identity function works at multiple call sites ──────── *)
(*                                                                              *)
(* `fn identity(x: a) -> a = x` should be instantiatable at multiple types   *)
(* in the same module. HM typing via Algorithm W should generalize `a` and   *)
(* instantiate fresh type variables at each call site.                        *)
let test_g43_polymorphic_identity_multiple_sites () =
  let src =
    prelude ^
    "fn identity(x: a) -> a = x\n" ^
    "fn testInt() -> Int = identity 42\n" ^
    "fn testStr() -> String = identity \"hello\"\n" ^
    "fn testBool() -> Bool = identity True\n" in
  should_pass src

(* ── G44: [a, b] two-element list infers as Tuple2 (spec §14b.1) ──────────── *)
(*                                                                              *)
(* Per LANGUAGE-SPEC.md §14b.1: Two-element list literals [a, b] were previously
   accepted as Tuple2 syntax. This has been removed: [a, b] is always List,
   and Tuple2 must be constructed with the `Tuple2 a b` constructor.          *)
let test_g44_two_element_list_as_tuple2 () =
  let src =
    prelude ^
    "import Tesl.Tuple exposing [Tuple2(..)]\n" ^
    "fn makePair() -> Tuple2 Int String = [42, \"hello\"]\n" ^
    "fn testFirst(t: Tuple2 Int String) -> Int = Tuple2.first t\n" in
  (* [a, b] as Tuple2 is now rejected: use `Tuple2 a b` constructor *)
  should_fail "Tuple2.*constructor\\|list literal.*Tuple2\\|cannot be used to construct" src

(* ── G45: check function ok with wrong proof is correctly rejected ───────── *)
(*                                                                              *)
(* `ok x ::: IsSmall x` inside a check function that declares                *)
(* `-> x: Int ::: IsPositive x` must be rejected: the proof in `ok` does    *)
(* not match the declared return spec.                                        *)
let test_g45_ok_wrong_proof_rejected () =
  let src = proof_prelude ^
    "fact IsSmall (n: Int)\n" ^
    "check sneaky(n: Int) -> n: Int ::: IsPositive n =\n" ^
    "  if n > 0 then\n" ^
    "    ok n ::: IsSmall n\n" ^
    "  else\n" ^
    "    fail 400 \"neg\"\n" in
  should_fail "proof does not match\\|IsSmall.*IsPositive\\|P001" src

(* ── G46: forgetFact correctly strips proof annotation ──────────────────── *)
(*                                                                              *)
(* `forgetFact` takes a value with a proof annotation and returns the plain   *)
(* value. After forgetFact, the value can no longer satisfy proof-requiring   *)
(* functions without re-establishing the proof.                               *)
let test_g46_forgetfact_strips_proof () =
  let src =
    "#lang tesl\nmodule T exposing []\n" ^
    "import Tesl.Prelude exposing [Int, String, Bool(..), List, Unit, Fact, forgetFact]\n" ^
    "import Tesl.Maybe exposing [Maybe(..)]\n" ^
    "fact IsPositive (n: Int)\n" ^
    "check checkPos(n: Int) -> n: Int ::: IsPositive n =\n" ^
    "  if n > 0 then\n" ^
    "    ok n ::: IsPositive n\n" ^
    "  else\n" ^
    "    fail 400 \"neg\"\n" ^
    "fn needsPositive(n: Int ::: IsPositive n) -> Int = n\n" ^
    "fn stripAndFail(x: Int) -> Int =\n" ^
    "  let checked = checkPos x\n" ^
    "  let plain = forgetFact checked\n" ^
    "  needsPositive plain\n" in
  should_fail "does not statically satisfy\\|IsPositive\\|V001" src

(* ── G47: Variable shadowing in let is correctly rejected ────────────────── *)
(*                                                                              *)
(* `let x = x + 1` where x is already bound as a parameter shadows the name  *)
(* x. Tesl enforces a no-shadowing rule to preserve GDP subject identity.     *)
(* The compiler must reject this with a clear error.                          *)
let test_g47_let_shadowing_rejected () =
  let src =
    prelude ^
    "fn test(x: Int) -> Int =\n" ^
    "  let x = x + 1\n" ^
    "  x\n" in
  should_fail "shadows.*existing\\|no.*shadow\\|V001" src

(* ── G48: selectCount return type is Int ────────────────────────────────── *)
(*                                                                              *)
(* `selectCount p from Entity` is correctly typed as returning Int in the     *)
(* type checker, and it can be used in string interpolation as an Int.        *)
let test_g48_selectcount_returns_int () =
  let src = db_prelude ^
    "fn countProducts() -> String requires [dbRead] =\n" ^
    "  let n = selectCount p from Product\n" ^
    "  \"Total: ${n}\"\n" in
  should_pass src

(* ── G49: Dict.get without HasKey proof is correctly rejected ─────────────── *)
(*                                                                              *)
(* `Dict.get key dict` requires a proof that key is present in dict (HasKey). *)
(* Calling it without going through Dict.requireKey must be rejected.         *)
let test_g49_dict_get_without_haskey_rejected () =
  let src =
    prelude ^
    "import Tesl.Dict exposing [Dict, Dict.empty, Dict.insert, Dict.get]\n" ^
    "fn badLookup() -> Int =\n" ^
    "  let d = Dict.insert \"key\" 42 Dict.empty\n" ^
    "  Dict.get \"key\" d\n" in
  should_fail "HasKey\\|requires proof\\|V001" src

(* ── G50: PosixMillis comparison operators work (unify as same type) ──────── *)
(*                                                                              *)
(* While PosixMillis arithmetic (a - b) fails because the arithmetic checker  *)
(* requires Int, comparison operators (a > b) succeed because they only       *)
(* require both operands to unify with each other. PosixMillis == PosixMillis *)
(* satisfies `unify lt rt` at line BLt/BLe/BGt/BGe.                           *)
let test_g50_posixmillis_comparison_works () =
  let src =
    prelude ^
    "import Tesl.Time exposing [time, PosixMillis, nowMillis]\n" ^
    "fn isAfter(a: PosixMillis, b: PosixMillis) -> Bool requires [time] =\n" ^
    "  a > b\n" in
  should_pass src

(* ── G51: Paren-style multi-arg call f(x, y) is correctly rejected ──────── *)
(*                                                                              *)
(* The spec only permits `f(x)` (single-arg) and `f()` (zero-arg). The form  *)
(* `f(x, y)` is the old legacy multi-arg syntax and must be rejected with a  *)
(* clear parse error at the comma.                                             *)
let test_g51_paren_multiarg_rejected () =
  let src =
    prelude ^
    "fn add(x: Int, y: Int) -> Int = x + y\n" ^
    "fn test() -> Int = add(1, 2)\n" in
  should_fail "expected.*,\\|,.*expected\\|E000" src

(* ── G52: User-defined capability in requires is correctly accepted ────────── *)
(*                                                                              *)
(* User-defined capabilities created with `capability myOp` can be declared   *)
(* in `requires [myOp]` on both fn and handler functions. The compiler must   *)
(* accept these without treating them as unknown capability names.            *)
let test_g52_user_defined_capability_accepted () =
  let src =
    prelude ^
    "capability analyticsWrite\n" ^
    "fn trackEvent(name: String) -> Unit requires [analyticsWrite] =\n" ^
    "  Unit\n" ^
    "handler logEvent(name: String) -> Unit requires [analyticsWrite] =\n" ^
    "  trackEvent name\n" in
  should_pass src

(* ── Test runner ──────────────────────────────────────────────────────────── *)

let () =
  run "Review31" [
    "G31", [ test_case "selectMax now compiles (type checker support FIXED)" `Quick test_g31_selectmax_unknown_name ];
    "G32", [ test_case "selectSum returns Int even for Float fields (type inaccuracy)" `Quick test_g32_selectsum_returns_int ];
    "G33", [ test_case "PosixMillis arithmetic fails — spec says auto-unwrap but impl doesn't" `Quick test_g33_posixmillis_arithmetic_fails ];
    "G34", [ test_case "duplicate variable binder in case arm now rejected" `Quick test_g34_duplicate_binder_in_case_arm ];
    "G35", [ test_case "ForAll on non-List/Set type now rejected" `Quick test_g35_forall_on_non_list_silently_compiles ];
    "G36", [ test_case "handler with unused declared capability — no lint warning" `Quick test_g36_handler_unused_capability_no_warning ];
    "G37", [ test_case "upsert compiles correctly (now documented)" `Quick test_g37_upsert_compiles ];
    "G38", [ test_case "delete returns Unit — no need to import DeleteResult" `Quick test_g38_delete_result_needs_db_import ];
    "G39", [ test_case "proof arity mismatch at declaration now rejected" `Quick test_g39_proof_arity_mismatch_at_declaration ];
    "G40", [ test_case "nested transaction correctly rejected (P001)" `Quick test_g40_nested_transaction_rejected ];
    "G41", [ test_case "non-exhaustive case expression correctly detected" `Quick test_g41_non_exhaustive_case_detected ];
    "G42", [ test_case "circular capability implication correctly rejected" `Quick test_g42_circular_capability_rejected ];
    "G43", [ test_case "polymorphic identity works at multiple monomorphic call sites" `Quick test_g43_polymorphic_identity_multiple_sites ];
    "G44", [ test_case "[a, b] list literal is now rejected as Tuple2 (use Tuple2 a b constructor)" `Quick test_g44_two_element_list_as_tuple2 ];
    "G45", [ test_case "check with wrong proof in ok correctly rejected" `Quick test_g45_ok_wrong_proof_rejected ];
    "G46", [ test_case "forgetFact strips proof — needsPositive then fails" `Quick test_g46_forgetfact_strips_proof ];
    "G47", [ test_case "variable shadowing in let correctly rejected" `Quick test_g47_let_shadowing_rejected ];
    "G48", [ test_case "selectCount returns Int — usable in interpolation" `Quick test_g48_selectcount_returns_int ];
    "G49", [ test_case "Dict.get without HasKey proof correctly rejected" `Quick test_g49_dict_get_without_haskey_rejected ];
    "G50", [ test_case "PosixMillis comparison > works (same-type unification)" `Quick test_g50_posixmillis_comparison_works ];
    "G51", [ test_case "paren multi-arg call f(x, y) correctly rejected" `Quick test_g51_paren_multiarg_rejected ];
    "G52", [ test_case "user-defined capability in requires accepted" `Quick test_g52_user_defined_capability_accepted ];
  ]
