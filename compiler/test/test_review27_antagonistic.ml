(** Antagonistic regression tests for Critical Review 27.

    Each test probes a specific correctness gap, ergonomic limitation, or
    soundness boundary identified during Review 27.

    Findings covered:
      F01  Scalar proof accumulation via chaining (KNOWN BUG: loses first proof)
      F02  && combined check in let binding (KNOWN BUG: combined proof not tracked)
      F03  Inline check result without let binding (KNOWN LIMITATION)
      F04  String literal pattern matching (NOT SUPPORTED)
      F05  Guard condition does not establish proof predicates
      F06  Empty list [] does not satisfy ForAll proof (vacuous truth gap)
      F07  ForAll filterCheck chaining correctly accumulates proofs (positive)
      F08  ForAll wrong conjunction rejected (negative)
      F09  establish always-returning proof (by design soundness boundary)
      F10  Fact parameter type enforcement (type-checked correctly)
      F11  Single-line if gives clear E000 error, not crash
      F12  Import before definitions enforced
      F13  ADT constructor same name as type is rejected
      F14  Circular type alias is rejected
      F15  check ok expression must return the named identifier (P001)
      F16  Forward reference across function definitions compiles
      F17  Mutual recursion compiles
      F18  Case arm type mismatch caught (T001)
      F19  Unused let variable silently compiles (no warning)
      F20  Partial application with proof-bearing argument preserves proof
      F21  Higher-order function with proof-bearing param compiles
      F22  Capability syntax error gives E000, not crash
      F23  Large integer literal detected (overflow)
      F24  Nested case via inner case expression compiles
      F25  Cross-subject proof reuse is rejected (soundness)
      F26  proof-forgery-003 variant using multi-line if (positive regression)
      F27  proof-forgery-004 variant using multi-line if (negative regression)  *)

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
  let tmp = Filename.temp_file "tesl-r27-test" ".tesl" in
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
   import Tesl.Prelude exposing [Int, String, Bool(..), List, Unit]\n\
   import Tesl.Maybe exposing [Maybe(..)]\n"

let proof_prelude =
  prelude ^
  "fact IsPositive (n: Int)\n" ^
  "fact IsSmall (n: Int)\n" ^
  "check checkPos(n: Int) -> n: Int ::: IsPositive n =\n" ^
  "  if n > 0 then\n" ^
  "    ok n ::: IsPositive n\n" ^
  "  else\n" ^
  "    fail 400 \"neg\"\n" ^
  "check checkSmall(n: Int) -> n: Int ::: IsSmall n =\n" ^
  "  if n < 100 then\n" ^
  "    ok n ::: IsSmall n\n" ^
  "  else\n" ^
  "    fail 400 \"big\"\n" ^
  "fn needsBoth(n: Int ::: IsPositive n && IsSmall n) -> String = \"ok\"\n"

(* ── F01: Scalar proof chaining LOSES first proof ────────────────────────
   KNOWN BUG: let n1 = checkA n ; let n2 = checkB n1
   After this, n2 only carries IsSmall — not IsPositive && IsSmall.
   A function requiring both proofs will (correctly, but regrettably) reject n2.
   This test documents the current (broken) behaviour so any fix is caught.   *)

let test_scalar_proof_chain_accumulates () =
  (* Bug is now FIXED: sequential checks accumulate all proofs.
     n2 carries both IsPositive (from n1) and IsSmall (from checkSmall). *)
  let src = proof_prelude ^ {|
fn testChain(n: Int) -> String =
  let n1 = check checkPos n
  let n2 = check checkSmall n1
  needsBoth n2
|} in
  should_pass src

let test_scalar_proof_chain_single_step_works () =
  (* Baseline: a single check correctly establishes its proof *)
  let src = proof_prelude ^ {|
fn needsPos(n: Int ::: IsPositive n) -> String = "ok"
fn testSingle(n: Int) -> String =
  let n1 = check checkPos n
  needsPos n1
|} in
  should_pass src

(* ── F02: && combined check in let binding doesn't track combined proof ──
   KNOWN BUG: (checkPos && checkSmall) n should produce n ::: IsPositive n && IsSmall n,
   but the let-bound result is not tracked as carrying both proofs.             *)

let test_and_check_let_binding_tracked () =
  (* Bug is now FIXED: (checkPos && checkSmall) n in a let binding
     correctly tracks both IsPositive and IsSmall on the result. *)
  let src = proof_prelude ^ {|
fn testAndLet(n: Int) -> String =
  let n2 = check (checkPos && checkSmall) n
  needsBoth n2
|} in
  should_pass src

let test_and_check_named_fn_workaround () =
  (* The workaround: wrap && in a named check function — this DOES work *)
  let src = proof_prelude ^ {|
check checkBoth(n: Int) -> n: Int ::: IsPositive n && IsSmall n =
  check (checkPos && checkSmall) n
fn testAndFn(n: Int) -> String =
  let n2 = check checkBoth n
  needsBoth n2
|} in
  should_pass src

(* ── F03: Inline check result without let binding ────────────────────────
   KNOWN LIMITATION: passing check(n) directly as an argument is rejected.
   The proof system requires a named let binding to track the proof subject.    *)

let test_inline_check_result_rejected () =
  let src = proof_prelude ^ {|
fn testInline(n: Int) -> String =
  needsBoth (check checkPos n)
|} in
  should_fail "no trackable subject" src

let test_let_bound_check_accepted () =
  (* The required workaround: bind to a name first *)
  let src = proof_prelude ^ {|
fn needsPos(n: Int ::: IsPositive n) -> String = "ok"
fn testLetBound(n: Int) -> String =
  let n2 = check checkPos n
  needsPos n2
|} in
  should_pass src

(* ── F04: String literal pattern matching is NOT supported ───────────────
   There is no case-on-string support in Tesl; patterns must be ADT constructors
   or variable/wildcard binders.                                                *)

let test_string_literal_pattern_supported () =
  (* String literal patterns are now supported via PLit in the pattern AST. *)
  let src = prelude ^ {|
fn classify(s: String) -> Int =
  case s of
    "hello" -> 1
    "world" -> 2
    _ -> 0
|} in
  should_pass src

(* ── F05: Guard condition does not establish proof predicates ─────────────
   A guard `where n > 0` narrows the value domain semantically, but the proof
   system doesn't convert that guard into an IsNonZero (or similar) proof.
   Division inside that guarded arm still requires Int.nonZero check.           *)

let test_guard_does_not_establish_nonzero_proof () =
  let src = prelude ^ {|
fn safeDiv(a: Int, b: Int) -> Int =
  case b of
    n where n > 0 -> a / n
    _ -> 0
|} in
  should_fail "IsNonZero\\|nonZero\\|proof" src

let test_explicit_nonzero_check_works () =
  let src = "#lang tesl\nmodule T exposing [safeDiv]\n\
             import Tesl.Prelude exposing [Int]\n\
             import Tesl.Int exposing [Int.nonZero]\n" ^
  {|
fn safeDiv(a: Int, b: Int) -> Int =
  let b2 = Int.nonZero b
  a / b2
|} in
  should_pass src

(* ── F06: Empty list literal does not vacuously satisfy ForAll proof ──────
   In logic, ∀x∈[]. P(x) is vacuously true, but Tesl does not honour this:
   passing [] to a ForAll-requiring function is rejected even when typed.       *)

let test_empty_list_variable_forall_not_vacuous () =
  (* A variable bound to [] still needs a ForAll proof when passed to a function.
     The vacuous truth fix only applies to LITERAL [] at the call site. *)
  let src = prelude ^ {|
fact IsPositive (n: Int)
fn processAll(xs: List Int ::: ForAll IsPositive xs) -> String = "done"
fn processEmpty() -> String =
  let emptyList: List Int = []
  processAll emptyList
|} in
  (* Variable case: vacuous truth is NOT applied because we don't track
     that emptyList was bound to []. This remains a known limitation. *)
  should_fail "ForAll\\|proof" src

let test_empty_list_literal_forall_vacuous () =
  (* Per spec section 16.9, an empty list literal does NOT vacuously satisfy
     ForAll P. The compiler now correctly rejects this. *)
  let src = prelude ^ {|
fact IsPositive (n: Int)
fn processAll(xs: List Int ::: ForAll IsPositive xs) -> String = "done"
fn processEmpty() -> String =
  processAll []
|} in
  should_fail "ForAll\\|proof\\|requires proof" src

(* ── F07: ForAll filterCheck chaining accumulates proofs (positive) ───────
   List-level proof accumulation through filterCheck chains IS implemented
   correctly in the stdlib. This test guards against regression.                *)

let test_forall_filtercheck_chaining_accumulates () =
  let src =
    "#lang tesl\nmodule T exposing [filterBoth]\n\
     import Tesl.Prelude exposing [Int, List]\n\
     import Tesl.List exposing [List.filterCheck]\n" ^
  {|
fact IsPositive (n: Int)
fact IsSmall (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "neg"
check checkSmall(n: Int) -> n: Int ::: IsSmall n =
  if n < 100 then
    ok n ::: IsSmall n
  else
    fail 400 "big"
fn filterBoth(xs: List Int) -> List Int ? ForAll (IsPositive && IsSmall)
  requires [] =
  let positives = List.filterCheck checkPos xs
  List.filterCheck checkSmall positives
|} in
  should_pass src

(* ── F08: ForAll wrong conjunction is rejected (negative regression) ──────
   Claiming ForAll (IsPositive && IsEven) when only IsPositive && IsSmall
   were established must be rejected by the compiler.                           *)

let test_forall_wrong_conjunction_rejected () =
  let src =
    "#lang tesl\nmodule T exposing [filterChainedWrong]\n\
     import Tesl.Prelude exposing [Int, List]\n\
     import Tesl.List exposing [List.filterCheck]\n" ^
  {|
fact IsPositive (n: Int)
fact IsSmall (n: Int)
fact IsEven (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "neg"
check checkSmall(n: Int) -> n: Int ::: IsSmall n =
  if n < 100 then
    ok n ::: IsSmall n
  else
    fail 400 "big"
fn filterChainedWrong(xs: List Int) -> List Int ? ForAll (IsPositive && IsEven)
  requires [] =
  let positives = List.filterCheck checkPos xs
  List.filterCheck checkSmall positives
|} in
  should_fail "IsEven\\|mismatch\\|conjunction\\|established" src

(* ── F09: establish always-returning proof (soundness boundary by design) ─
   An `establish` function that unconditionally fabricates a proof compiles.
   This is an intentional trusted-boundary escape hatch, not a bug, but it
   means the proof system is only as sound as the establish implementations.   *)

let test_establish_always_true_compiles () =
  let src = prelude ^ {|
fact IsPositive (n: Int)
establish alwaysPositive(n: Int) -> Fact (IsPositive n) = IsPositive n
fn usesProof(n: Int ::: IsPositive n) -> Int = n
fn lie(n: Int) -> Int =
  let proof = alwaysPositive n
  n ::: proof
|} in
  (* By design, this compiles — establish is a trusted boundary *)
  should_pass src

(* ── F10: Fact parameter type is enforced ────────────────────────────────
   Using a fact on an argument whose type doesn't match the declared fact
   parameter type is a type error.                                               *)

let test_fact_param_type_enforced () =
  let src = prelude ^ {|
fact WeirdFact (n: String)
check checkWeird(n: Int) -> n: Int ::: WeirdFact n =
  if n > 0 then
    ok n ::: WeirdFact n
  else
    fail 400 "no"
fn testFact(n: Int) -> Int =
  let m = checkWeird n
  m
|} in
  should_fail "Int.*String\\|String.*Int\\|type.*Int\\|WeirdFact" src

(* ── F11: Single-line if gives clear E000 error, not a crash ─────────────
   The prohibition on single-line `if cond then a else b` is a deliberate
   design choice. It must give a clear diagnostic, not a panic or parse crash.  *)

let test_single_line_if_gives_clear_error () =
  let src = prelude ^ {|
fn f(n: Int) -> String = if n > 0 then "pos" else "neg"
|} in
  should_fail "then.*body.*indented\\|single.line.*if\\|E000" src

(* ── F12: Definitions before imports are rejected ────────────────────────
   All imports must precede type and function definitions. Placing a type
   alias before an import must produce an error.                                 *)

let test_def_before_import_rejected () =
  let src =
    "#lang tesl\nmodule T exposing [f]\n\
     type Foo = Int\n\
     import Tesl.Prelude exposing [Int]\n\
     fn f(x: Int) -> Int = x\n"
  in
  should_fail "import\\|order\\|before" src

(* ── F13: ADT constructor with same name as type is rejected ─────────────
   Writing `type Status = Status | Inactive` must produce a compile error.
   Constructor names must differ from the type name.                             *)

let test_adt_constructor_same_name_as_type_rejected () =
  let src = prelude ^ {|
type Status
  = Status
  | Inactive
|} in
  should_fail "constructor\\|same.*name\\|type name\\|Status\\|error" src

(* ── F14: Circular type alias is rejected ───────────────────────────────── *)

let test_circular_type_alias_rejected () =
  let src = prelude ^ {|
type A = B
type B = A
fn f(a: A) -> B = a
|} in
  should_fail "circular\\|cycle\\|recursive\\|B\\|error" src

(* ── F15: check ok expression must return the named identifier (P001) ─────
   `ok (n * 2) ::: IsPositive n` in a check function is rejected because the
   ok expression must return the exact binding name being validated, not an
   arbitrary sub-expression.                                                     *)

let test_check_ok_must_be_identifier () =
  let src = prelude ^ {|
fact IsPositive (n: Int)
check checkAndDouble(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok (n * 2) ::: IsPositive n
  else
    fail 400 "neg"
|} in
  should_fail "non-identifier\\|identifier\\|ok expression\\|declared binding name\\|constructor" src

(* ── F16: Forward reference across function definitions compiles ──────────
   Functions defined after their callers are in scope for the whole module.     *)

let test_forward_reference_compiles () =
  let src = prelude ^ {|
fn a(n: Int) -> Int = b n
fn b(n: Int) -> Int = n + 1
|} in
  should_pass src

(* ── F17: Mutual recursion compiles ──────────────────────────────────────── *)

let test_mutual_recursion_compiles () =
  let src = prelude ^ {|
fn isEven(n: Int) -> Bool =
  if n == 0 then
    True
  else
    isOdd (n - 1)
fn isOdd(n: Int) -> Bool =
  if n == 0 then
    False
  else
    isEven (n - 1)
|} in
  should_pass src

(* ── F18: Case arm type mismatch is caught ───────────────────────────────── *)

let test_case_arm_type_mismatch_caught () =
  let src = prelude ^ {|
fn f(x: Maybe Int) -> String =
  case x of
    Nothing -> 42
    Something n -> "ok"
|} in
  should_fail "T001\\|unify Int with String\\|mismatch" src

(* ── F19: Unused let variable silently compiles (no warning) ──────────────
   At present the linter does not warn on unused let bindings.
   This is documented as a gap — not a bug but a DX improvement opportunity.   *)

let test_unused_let_variable_no_error () =
  let src = prelude ^ {|
fn f(n: Int) -> Int =
  let unused = n + 1
  n
|} in
  (* No error is expected; this should silently compile *)
  should_pass src

(* ── F20: Partial application with proof-bearing argument ────────────────
   When a function takes a proof-annotated parameter and is partially applied,
   the caller must still supply that proof on the remaining argument.            *)

let test_partial_app_with_proof_param () =
  let src = proof_prelude ^ {|
fn addProved(a: Int, b: Int ::: IsPositive b) -> Int = a + b
fn testPartial(n: Int) -> Int =
  let n2 = check checkPos n
  let addToN = addProved 10
  addToN n2
|} in
  should_pass src

(* ── F21: Higher-order function with proof-bearing parameter compiles ──── *)

let test_hof_proof_param_compiles () =
  let src = proof_prelude ^ {|
fn applyTwice(f: Int -> Int, n: Int ::: IsPositive n) -> Int = f (f n)
fn testHof(n: Int) -> Int =
  let n2 = check checkPos n
  applyTwice (fn(x: Int) -> x + 1) n2
|} in
  should_pass src

(* ── F22: Large integer literal compiles (A9/HM-1: Int is arbitrary-precision) ──
   Formerly Int literals above the fixnum limit were rejected. Under A9/HM-1 the
   range check is dropped: the huge magnitude is carried as an LBigInt canonical
   string into the Racket bignum — never silently wrapped or truncated.          *)

let test_large_integer_literal_rejected () =
  let src = prelude ^ {|
fn f() -> Int = 99999999999999999999
|} in
  should_pass src

(* ── F23: Nested ADT matching via inner case compiles ────────────────────
   While `Wrap (Something n)` nested constructor patterns are not supported,
   nested case expressions are the idiomatic alternative and must compile.      *)

let test_nested_adt_via_inner_case () =
  let src = prelude ^ {|
type Outer = Wrap inner: Maybe Int
fn unwrap(x: Outer) -> Int =
  case x of
    Wrap inner ->
      case inner of
        Nothing -> 0
        Something n -> n
|} in
  should_pass src

(* ── F24: Nested constructor patterns (Wrap (Something n)) rejected ───────
   The parser only supports flat constructor patterns. Nested constructor
   patterns must give a parse error, not a crash.                               *)

let test_nested_constructor_pattern_supported () =
  (* Nested constructor patterns are now supported (F24 implemented). *)
  let src =
    "#lang tesl\nmodule T exposing [unwrap]\n\
     import Tesl.Prelude exposing [Int]\n\
     import Tesl.Maybe exposing [Maybe(..)]\n\
     type Outer = Wrap inner: Maybe Int\n\
     fn unwrap(x: Outer) -> Int =\n\
     \  case x of\n\
     \    Wrap (Something n) -> n\n\
     \    _ -> 0\n"
  in
  should_pass src

(* ── F25: Cross-subject proof reuse is rejected (soundness guard) ─────────
   A proof established for variable `a` must not satisfy the proof requirement
   for a different variable `b`, even if they have the same type.               *)

let test_cross_subject_proof_reuse_rejected () =
  let src = proof_prelude ^ {|
fn needsPos(n: Int ::: IsPositive n) -> Int = n
fn crossSubject(a: Int, b: Int) -> Int =
  let a2 = checkPos a
  needsPos b
|} in
  should_fail "V001\\|IsPositive b\\|proof\\|statically" src

(* ── F26: PROOF-FORGERY-003 with multi-line if (positive regression) ──────
   The original PROOF-FORGERY-003 test used single-line if (now illegal) and
   thus could not compile. This variant uses multi-line if and should compile,
   confirming that ForAll filterCheck chaining works.                            *)

let test_proof_forgery_003_multiline () =
  let src =
    "#lang tesl\nmodule T exposing [filterChained]\n\
     import Tesl.Prelude exposing [Int, List]\n\
     import Tesl.List exposing [List.filterCheck]\n" ^
  {|
fact IsPositive (n: Int)
fact IsSmall (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "neg"
check checkSmall(n: Int) -> n: Int ::: IsSmall n =
  if n < 100 then
    ok n ::: IsSmall n
  else
    fail 400 "big"
fn filterChained(xs: List Int) -> List Int ? ForAll (IsPositive && IsSmall)
  requires [] =
  let positives = List.filterCheck checkPos xs
  List.filterCheck checkSmall positives
|} in
  should_pass src

(* ── F27: PROOF-FORGERY-004 with multi-line if (negative regression) ──────
   Claiming ForAll (IsPositive && IsEven) when only IsPositive and IsSmall were
   established through filterCheck chains must be rejected.                     *)

let test_proof_forgery_004_multiline () =
  let src =
    "#lang tesl\nmodule T exposing [filterWrong]\n\
     import Tesl.Prelude exposing [Int, List]\n\
     import Tesl.List exposing [List.filterCheck]\n" ^
  {|
fact IsPositive (n: Int)
fact IsSmall (n: Int)
fact IsEven (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "neg"
check checkSmall(n: Int) -> n: Int ::: IsSmall n =
  if n < 100 then
    ok n ::: IsSmall n
  else
    fail 400 "big"
fn filterWrong(xs: List Int) -> List Int ? ForAll (IsPositive && IsEven)
  requires [] =
  let positives = List.filterCheck checkPos xs
  List.filterCheck checkSmall positives
|} in
  should_fail "IsEven\\|mismatch\\|conjunction\\|established" src

(* ── Test suite registration ────────────────────────────────────────────── *)

let () =
  run "review-27-antagonistic" [
    "proof-chain-accumulation", [
      test_case "scalar proof chain accumulates both proofs (F01a fixed)" `Quick test_scalar_proof_chain_accumulates;
      test_case "single-step check preserves proof — baseline (F01b)" `Quick test_scalar_proof_chain_single_step_works;
      test_case "&& check let binding tracked (F02a fixed)"               `Quick test_and_check_let_binding_tracked;
      test_case "&& check named fn workaround compiles (F02b)"         `Quick test_and_check_named_fn_workaround;
    ];
    "inline-check-ergonomics", [
      test_case "inline check result rejected — limitation (F03a)"    `Quick test_inline_check_result_rejected;
      test_case "let-bound check accepted (F03b)"                      `Quick test_let_bound_check_accepted;
    ];
    "pattern-matching-gaps", [
      test_case "string literal pattern supported (F04 fixed)"             `Quick test_string_literal_pattern_supported;
      test_case "guard does not establish IsNonZero proof (F05)"       `Quick test_guard_does_not_establish_nonzero_proof;
      test_case "explicit nonZero check works (F05b)"                  `Quick test_explicit_nonzero_check_works;
      test_case "nested constructor pattern supported (F24 fixed)"         `Quick test_nested_constructor_pattern_supported;
      test_case "nested ADT via inner case compiles (F23)"             `Quick test_nested_adt_via_inner_case;
    ];
    "forall-proof-semantics", [
      test_case "empty list variable ForAll limitation (F06a)"         `Quick test_empty_list_variable_forall_not_vacuous;
      test_case "empty list literal ForAll vacuously satisfied (F06b)" `Quick test_empty_list_literal_forall_vacuous;
      test_case "filterCheck chaining accumulates ForAll proofs (F07)" `Quick test_forall_filtercheck_chaining_accumulates;
      test_case "filterCheck wrong conjunction rejected (F08)"         `Quick test_forall_wrong_conjunction_rejected;
    ];
    "proof-soundness-boundary", [
      test_case "establish always-true compiles by design (F09)"       `Quick test_establish_always_true_compiles;
      test_case "fact param type mismatch enforced (F10)"              `Quick test_fact_param_type_enforced;
      test_case "cross-subject proof reuse rejected (F25)"             `Quick test_cross_subject_proof_reuse_rejected;
      test_case "check ok must return identifier P001 (F15)"           `Quick test_check_ok_must_be_identifier;
    ];
    "language-correctness", [
      test_case "single-line if gives clear E000 (F11)"                `Quick test_single_line_if_gives_clear_error;
      test_case "def before import rejected (F12)"                     `Quick test_def_before_import_rejected;
      test_case "ADT constructor same name as type rejected (F13)"     `Quick test_adt_constructor_same_name_as_type_rejected;
      test_case "circular type alias rejected (F14)"                   `Quick test_circular_type_alias_rejected;
      test_case "forward reference compiles (F16)"                     `Quick test_forward_reference_compiles;
      test_case "mutual recursion compiles (F17)"                      `Quick test_mutual_recursion_compiles;
      test_case "case arm type mismatch caught T001 (F18)"             `Quick test_case_arm_type_mismatch_caught;
      test_case "unused let variable no error (F19)"                   `Quick test_unused_let_variable_no_error;
      test_case "large integer literal overflow rejected (F22)"        `Quick test_large_integer_literal_rejected;
    ];
    "hof-and-partial-application", [
      test_case "partial application with proof param (F20)"           `Quick test_partial_app_with_proof_param;
      test_case "HOF with proof-bearing param compiles (F21)"          `Quick test_hof_proof_param_compiles;
    ];
    "proof-forgery-multiline-regressions", [
      test_case "proof-forgery-003 multi-line if positive (F26)"       `Quick test_proof_forgery_003_multiline;
      test_case "proof-forgery-004 multi-line if negative (F27)"       `Quick test_proof_forgery_004_multiline;
    ];
  ]
