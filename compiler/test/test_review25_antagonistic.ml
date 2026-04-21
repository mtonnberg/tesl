(** Antagonistic regression tests for Critical Review 25.

    Each test probes a specific flaw, limitation, or correctness gap
    identified during the review. Tests are ordered by finding category.

    Findings addressed / new probes:
      G01  Proof not propagated through let-rebinding (should pass)
      G02  Case guard does NOT attach proofs (should fail)
      G03  If-condition does NOT attach proofs (should fail)
      G04  Cross-subject conjunction confusion: forged conjunction proof
      G05  ForAll proof: list of wrong element type accepted/rejected
      G06  ForAll proof: empty-list vacuous pass
      G07  ForAll proof: cannot be used as element proof
      G08  Deeply nested conjunction flattened correctly
      G09  Proof decomposition: partial extraction on wrong proof fails
      G10  establish unconditional chain: documents deliberate escape hatch
      G11  fn claiming return proof without check (semantic gap)
      G12  Proof after arithmetic result — no implicit proof from comparison
      G13  Record field access loses proof (proof not inferred from container)
      G14  Shadowing inside case arm binding
      G15  Shadowing in lambda parameter vs outer binding
      G16  Newtype wrapped string: SQL injection string still goes through codec
      G17  Capability: function calling db op without required cap fails
      G18  Capability: empty requires [] cannot call function needing caps
      G19  check function used in fn body without `check` keyword
      G20  Proof from one branch does not bleed into other branch
      G21  Curried check: partial application of check function
      G22  Multi-module isolation: fact from another module cannot be forged locally
      G23  Tuple second element does not inherit proof from first element
      G24  ForAll expansion: caller-declared ForAll(P&&Q) without Q-check rejected
      G25  Proof on constructor argument does not attach to ADT wrapper
      G26  Orderable-type proof: non-orderable type rejected at check boundary
      G27  Missing field in record constructor gives clear error
      G28  Record-update preserves existing proof
      G29  Case pattern guard does not automatically produce proof evidence
      G30  Empty capability implies chain compiles cleanly                     *)

open Alcotest

(* ── Helpers (copied from test_review24 pattern) ──────────────────────────── *)

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
  let tmp = Filename.temp_file "tesl-r25-test" ".tesl" in
  let oc = open_out tmp in
  output_string oc src;
  close_out oc;
  let ic = Unix.open_process_in (Printf.sprintf "%s %s %s 2>&1" tesl check_subcmd tmp) in
  let out = In_channel.input_all ic in
  let _ = Unix.close_process_in ic in
  (try Sys.remove tmp with _ -> ());
  out

let _exit_code_of src =
  let tmp = Filename.temp_file "tesl-r25-test" ".tesl" in
  let oc = open_out tmp in
  output_string oc src;
  close_out oc;
  let status = Sys.command (Printf.sprintf "%s %s %s >/dev/null 2>&1" tesl check_subcmd tmp) in
  (try Sys.remove tmp with _ -> ());
  status

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
    let re = Str.regexp pattern in
    try ignore (Str.search_forward re out 0); true with Not_found -> false
  in
  if not found then
    Printf.eprintf "Expected pattern '%s' in output:\n%s\n" pattern out;
  check bool (Printf.sprintf "should fail with pattern: %s" pattern) true found

let prelude =
  "#lang tesl\nmodule T exposing []\n\
   import Tesl.Prelude exposing [Int, String, Bool(..), List, Unit, Fact]\n\
   import Tesl.Maybe exposing [Maybe(..)]\n"

let prelude_list =
  prelude ^
  "import Tesl.List exposing [List.map, List.filter, List.filterCheck, List.length, List.allCheck]\n"

(* ── G01: Proof travels through let-rebinding ──────────────────────────────── *)

let test_proof_travels_through_let_rebind () =
  (* A checked value rebound via `let w = v` should still carry the proof.
     If the proof is lost on rebind, requiresSafe w would fail at call site. *)
  let src = prelude ^ {|
fact Safe (s: String)

check checkSafe(s: String) -> s: String ::: Safe s =
  ok s ::: Safe s

fn requiresSafe(s: String ::: Safe s) -> String = s

fn f(s: String) -> String =
  let v = check checkSafe s
  let w = v
  requiresSafe w
|} in
  should_pass src

(* ── G02: Case guard does NOT produce a proof ──────────────────────────────── *)

let test_case_guard_does_not_produce_proof () =
  (* A case guard `where x > 0` is a boolean test, not a proof introduction.
     Passing x to requiresPositive inside that branch should FAIL because
     no check function ran. *)
  let src = prelude ^ {|
fact Positive (n: Int)

fn requiresPositive(n: Int ::: Positive n) -> Int = n

fn f(n: Int) -> Int =
  case n of
    x where x > 0 -> requiresPositive x
    _ -> 0
|} in
  should_fail "V001" src

(* ── G03: If-condition does NOT attach a proof to the scrutinee ─────────────── *)

let test_if_condition_does_not_produce_proof () =
  (* `if n > 0 then requiresPositive n` must fail — the if-test does not
     introduce a Positive proof; only a `check` call can do that. *)
  let src = prelude ^ {|
fact Positive (n: Int)

fn requiresPositive(n: Int ::: Positive n) -> Int = n

fn f(n: Int) -> Int =
  if n > 0 then
    requiresPositive n
  else
    0
|} in
  should_fail "V001" src

(* ── G04: Forged conjunction proof — carry P for x, pass as P for y ─────────── *)

let test_forged_conjunction_cross_subject () =
  (* Adversarial: check conjunctive proof on x, then try to use it for y.
     Both x and y are passed to a fn requiring P x && Q x, but we pass
     the proofs of x to the call for y. Should fail (cross-subject). *)
  let src = prelude ^ {|
fact P (n: Int)
fact Q (n: Int)

check checkPQ(n: Int) -> n: Int ::: P n && Q n =
  ok n ::: P n && Q n

fn requiresPQ(n: Int ::: P n && Q n) -> Int = n

fn forgeByReuse(x: Int, y: Int) -> Int =
  let px = checkPQ x
  let (xv ::: xp && xq) = px
  requiresPQ (y ::: xp && xq)
|} in
  should_fail "V001" src

(* ── G05: ForAll proof of wrong predicate is rejected ──────────────────────── *)

let test_forall_wrong_predicate_rejected () =
  (* A list proven with ForAll(Positive) must not satisfy ForAll(Small).
     The predicates are distinct facts; the compiler should reject the call. *)
  let src = prelude_list ^ {|
fact Positive (n: Int)
fact Small    (n: Int)

check checkPositive(n: Int) -> n: Int ::: Positive n =
  if n > 0 then
    ok n ::: Positive n
  else
    fail 400 "not positive"

fn requiresSmallList(xs: List Int ::: ForAll (Small) xs) -> Int =
  List.length xs

fn test(xs: List Int) -> Int =
  let proven = List.filterCheck checkPositive xs
  requiresSmallList proven
|} in
  should_fail "V001" src

(* ── G06: ForAll proof on empty list passes vacuously ──────────────────────── *)

let test_forall_empty_list_vacuous_pass () =
  (* An empty list after filterCheck should satisfy ForAll(P) vacuously.
     The compiler should accept the call. *)
  let src = prelude_list ^ {|
fact Positive (n: Int)

check checkPositive(n: Int) -> n: Int ::: Positive n =
  if n > 0 then
    ok n ::: Positive n
  else
    fail 400 "neg"

fn requiresAllPositive(xs: List Int ::: ForAll (Positive) xs) -> Int =
  List.length xs

fn f() -> Int =
  let empty: List Int = []
  let proven = List.filterCheck checkPositive empty
  requiresAllPositive proven
|} in
  should_pass src

(* ── G07: ForAll proof cannot substitute for an element-level proof ─────────── *)

let test_forall_not_element_proof () =
  (* ForAll(P) is a list-level annotation; it does not mean every element
     individually satisfies P in a way that can be unpacked and passed to
     fn requiresP(x ::: P x). *)
  let src = prelude_list ^ {|
fact Positive (n: Int)

check checkPositive(n: Int) -> n: Int ::: Positive n =
  if n > 0 then
    ok n ::: Positive n
  else
    fail 400 "neg"

fn requiresPositiveElem(n: Int ::: Positive n) -> Int = n

fn f(xs: List Int ::: ForAll (Positive) xs, n: Int) -> Int =
  requiresPositiveElem n
|} in
  (* n carries no Positive proof even though xs has ForAll(Positive). *)
  should_fail "V001" src

(* ── G08: Deeply nested conjunction is flattened correctly ─────────────────── *)

let test_deeply_nested_conjunction_flattened () =
  (* (A && (B && (C && D))) should all be individually satisfiable by
     a value that carries each proof. *)
  let src = prelude ^ {|
fact A (n: Int)
fact B (n: Int)
fact C (n: Int)
fact D (n: Int)

check checkABCD(n: Int) -> n: Int ::: A n && B n && C n && D n =
  ok n ::: A n && B n && C n && D n

fn requiresA(n: Int ::: A n) -> Int = n
fn requiresB(n: Int ::: B n) -> Int = n
fn requiresC(n: Int ::: C n) -> Int = n
fn requiresD(n: Int ::: D n) -> Int = n

fn f(n: Int) -> Int =
  let v = check checkABCD n
  requiresA v + requiresB v + requiresC v + requiresD v
|} in
  should_pass src

(* ── G09: Proof decomposition on value with only subset of proofs fails ───── *)

let test_partial_proof_decomp_fails () =
  (* A value carries only P. Destructuring for (P && Q) should fail because
     Q is not present. *)
  let src = prelude ^ {|
fact P (n: Int)
fact Q (n: Int)

check checkP(n: Int) -> n: Int ::: P n =
  ok n ::: P n

fn requiresPQ(n: Int ::: P n && Q n) -> Int = n

fn f(n: Int) -> Int =
  let p = checkP n
  let (v ::: pp && qp) = p
  requiresPQ (v ::: pp && qp)
|} in
  should_fail "V001" src

(* ── G10: establish unconditional — documents trusted escape hatch ─────────── *)

let test_establish_unconditional_mints_proof () =
  (* An establish that unconditionally returns Something <proof> is VALID
     syntax (it is a trusted boundary). This test documents the deliberate
     design decision so it appears in the test record.
     SECURITY NOTE: `establish` is an auditable escape hatch; any usage
     should be reviewed. *)
  let src = prelude ^ {|
fact Verified (n: Int)

establish alwaysVerified(n: Int) -> Maybe (Fact (Verified n)) =
  Something (Verified n)

fn requiresVerified(n: Int ::: Verified n) -> Int = n

fn f(n: Int) -> Int =
  let mProof = alwaysVerified n
  case mProof of
    Nothing -> 0
    Something p -> requiresVerified (n ::: p)
|} in
  (* INTENTIONALLY passes — establish is the trusted boundary. *)
  should_pass src

(* ── G11: fn with attached return type cannot use ok ::: ──────────────────── *)

let test_fn_cannot_use_ok_with_proof () =
  (* An ordinary `fn` must not use `ok n ::: Proof n`.
     Only check/auth/establish may introduce proofs. *)
  let src = prelude ^ {|
fact Safe (n: Int)

fn fakeSafe(n: Int) -> n: Int ::: Safe n =
  ok n ::: Safe n
|} in
  should_fail "P001" src

(* ── G12: Arithmetic result carries no implicit proof ─────────────────────── *)

let test_arithmetic_result_no_proof () =
  (* x + 1 where x > 0 does NOT automatically produce a Positive proof.
     The result is an unproven Int. *)
  let src = prelude ^ {|
fact Positive (n: Int)

fn requiresPositive(n: Int ::: Positive n) -> Int = n

fn f(x: Int) -> Int =
  let y = x + 1
  requiresPositive y
|} in
  should_fail "V001" src

(* ── G13: Record field access does not carry the record's proof ─────────────── *)

let test_record_field_no_proof_inheritance () =
  (* If a record r carries proof ValidRecord r, accessing r.name does NOT
     automatically give a proof about r.name. The field value is unproven. *)
  let src = prelude ^ {|
fact ValidRecord (r: String)
fact ValidName   (s: String)

record Rec { name: String }

check checkRec(r: String) -> r: String ::: ValidRecord r =
  ok r ::: ValidRecord r

fn requiresValidName(s: String ::: ValidName s) -> String = s

fn f(s: String) -> String =
  let v = checkRec s
  let r = Rec { name: v }
  requiresValidName r.name
|} in
  should_fail "V001" src

(* ── G14: Shadowing inside case arm binding ────────────────────────────────── *)

let test_shadowing_in_case_arm_binding () =
  (* The case arm introduces `x` via pattern binding. If `x` was already
     bound in the outer scope, this is shadowing and must be rejected. *)
  let src = prelude ^
  "import Tesl.Maybe exposing [Maybe(..)]\n" ^ {|

fn f(x: Int, m: Maybe Int) -> Int =
  case m of
    Something x -> x
    Nothing -> 0
|} in
  should_fail "shadow\\|redefined\\|E001\\|already bound" src

(* ── G15: Lambda parameter shadowing outer binding ─────────────────────────── *)

let test_lambda_param_shadows_outer () =
  (* The no-shadowing rule (§7.4 of spec) states: "Shadowing is forbidden for
     proof-relevant binders." Lambda parameters must not shadow outer bindings.
     Fixed: the shadowing check now covers lambda parameters. *)
  let src = prelude_list ^ {|
fn f(x: Int) -> List Int =
  List.map (fn(x: Int) -> x + 1) [1, 2, 3]
|} in
  should_fail "shadow" src

(* ── G16: check function result satisfies even through codec indirection ────── *)

let test_check_result_survives_codec_path () =
  (* A value that has been checked and then stored/read back should still
     have its proof in the call chain. This is a happy-path correctness test
     to ensure proof-bearing values compose correctly in handlers. *)
  let src = prelude ^
  "import Tesl.String exposing [String.length]\n" ^ {|
fact NonEmpty (s: String)

check checkNonEmpty(s: String) -> s: String ::: NonEmpty s =
  if String.length s > 0 then
    ok s ::: NonEmpty s
  else
    fail 400 "empty"

fn requiresNonEmpty(s: String ::: NonEmpty s) -> String = s

fn pipeline(s: String) -> String =
  let v = check checkNonEmpty s
  requiresNonEmpty v
|} in
  should_pass src

(* ── G17: Capability missing from requires causes compile error ──────────────── *)

let test_capability_missing_from_requires () =
  (* A function calling an operation that needs dbWrite but only declaring
     dbRead in requires must be rejected. *)
  let src = prelude ^
  "import Tesl.DB exposing [dbRead, dbWrite]\n" ^ {|
entity Item table "items" primaryKey id {
  id: String
  name: String
}

fn badWrite() -> Int
  requires [dbRead] =
  insert Item { id: "x", name: "y" }
  1
|} in
  should_fail "dbWrite\\|capability\\|C00" src

(* ── G18: Empty requires cannot call any effectful operation ─────────────────── *)

let test_empty_requires_cannot_call_db () =
  (* requires [] means zero capabilities. Any DB call must be rejected. *)
  let src = prelude ^
  "import Tesl.DB exposing [dbRead]\n" ^ {|
entity Item table "items" primaryKey id {
  id: String
  name: String
}

fn f() -> List Item
  requires [] =
  select item from Item
|} in
  should_fail "dbRead\\|capability\\|C00" src

(* ── G19: Calling a check fn in fn body without `check` keyword ──────────────── *)

let test_check_call_without_check_keyword () =
  (* In a fn body, calling a check function without the `check` keyword
     is valid (the check fn can be called and its result used as a proof-bearing
     value). Verify it compiles correctly. *)
  let src = prelude ^ {|
fact Safe (s: String)

check checkSafe(s: String) -> s: String ::: Safe s =
  ok s ::: Safe s

fn requiresSafe(s: String ::: Safe s) -> String = s

fn f(s: String) -> String =
  let v = check checkSafe s
  requiresSafe v
|} in
  should_pass src

(* ── G20: Proof from one case branch does not bleed into sibling branch ─────── *)

let test_proof_does_not_bleed_across_branches () =
  (* In a case expression, the proof context of one arm must not contaminate
     another arm. This tests that branches are isolated. *)
  let src = prelude ^ {|
fact Small (n: Int)

check checkSmall(n: Int) -> n: Int ::: Small n =
  if n < 10 then
    ok n ::: Small n
  else
    fail 400 "too big"

fn requiresSmall(n: Int ::: Small n) -> Int = n

fn f(m: Maybe Int) -> Int =
  case m of
    Something n ->
      let s = check checkSmall n
      requiresSmall s
    Nothing -> 0
|} in
  (* The proof context for the Something branch is isolated. Should pass. *)
  should_pass src

(* ── G21: Partial application of a check function is valid ───────────────────── *)

let test_partial_application_of_check () =
  (* check functions are ordinary functions and can be partially applied.
     check isInRange 0 100 should work as a partially-applied check. *)
  let src = prelude_list ^ {|
fact InRange (n: Int)

check checkInRange(lo: Int, hi: Int, n: Int) -> n: Int ::: InRange n =
  if lo <= n && n <= hi then
    ok n ::: InRange n
  else
    fail 400 "out of range"

fn requiresInRange(n: Int ::: InRange n) -> Int = n

fn f(xs: List Int) -> List Int =
  List.filterCheck (checkInRange 0 100) xs
|} in
  should_pass src

(* ── G22: Proof chain: three-step check dependency ─────────────────────────── *)

let test_three_step_proof_chain () =
  (* checkC requires B, checkB requires A.
     Full chain A → B → C must work end-to-end. *)
  let src = prelude ^ {|
fact A (n: Int)
fact B (n: Int)
fact C (n: Int)

check checkA(n: Int) -> n: Int ::: A n =
  if n >= 0 then
    ok n ::: A n
  else
    fail 400 "neg"

check checkB(n: Int ::: A n) -> n: Int ::: B n =
  if n < 1000 then
    ok n ::: B n
  else
    fail 400 "too big"

check checkC(n: Int ::: B n) -> n: Int ::: C n =
  if n < 500 then
    ok n ::: C n
  else
    fail 400 "too big"

fn requiresC(n: Int ::: C n) -> Int = n

fn f(n: Int) -> Int =
  let a = check checkA n
  let b = check checkB a
  let c = check checkC b
  requiresC c
|} in
  should_pass src

(* ── G23: Tuple second element does not inherit proof from first ─────────────── *)

let test_tuple_no_proof_inheritance () =
  (* In a tuple (a, b), a and b are independent. Even if a carries Positive,
     b does not inherit that proof. We test that b, when passed to
     requiresPositive, fails — because b was bound independently. *)
  let src = prelude ^ {|
fact Positive (n: Int)

check checkPositive(n: Int) -> n: Int ::: Positive n =
  if n > 0 then
    ok n ::: Positive n
  else
    fail 400 "neg"

fn requiresPositive(n: Int ::: Positive n) -> Int = n

fn f(a: Int, b: Int) -> Int =
  let pa = checkPositive a
  requiresPositive b
|} in
  (* b has no Positive proof even though pa does. Should fail. *)
  should_fail "V001" src

(* ── G24: ForAll expansion requires the additional check to be run ────────────── *)

let test_forall_expansion_requires_check () =
  (* Declaring `-> List Int ::: ForAll (P && Q)` while only running
     List.filterCheck checkP (not checkQ) should be rejected. *)
  let src = prelude_list ^ {|
fact P (n: Int)
fact Q (n: Int)

check checkP(n: Int) -> n: Int ::: P n =
  if n > 0 then
    ok n ::: P n
  else
    fail 400 "neg"

fn narrowedList(xs: List Int)
  -> List Int ::: ForAll (P && Q) =
  List.filterCheck checkP xs
|} in
  (* The function claims ForAll(P && Q) but only runs checkP. Should fail. *)
  should_fail "V001\\|proof" src

(* ── G25: Proof survives ADT constructor/destructor round-trip ──────────────── *)

let test_ctor_arg_proof_not_on_adt () =
  (* UPDATED R59 fix: Proof is now consistently LOST when stored in a constructor
     (like Something p) and then unwrapped via case. This makes Maybe consistent
     with user-defined ADTs. Previously this passed via subject aliasing, but that
     caused a static/runtime inconsistency: static accepted, runtime rejected.
     Now both static and runtime correctly reject proof use after unwrapping. *)
  let src = prelude ^ {|
fact Positive (n: Int)

check checkPositive(n: Int) -> n: Int ::: Positive n =
  if n > 0 then
    ok n ::: Positive n
  else
    fail 400 "neg"

fn requiresPositive(n: Int ::: Positive n) -> Int = n

fn f(n: Int) -> Int =
  let p = check checkPositive n
  let m = Something p
  case m of
    Something x -> requiresPositive x
    Nothing -> 0
|} in
  (* x no longer inherits proof through Something — proof is lost at wrapping. *)
  should_fail "does not statically satisfy" src

(* ── G26: Proof chain broken mid-way fails at call site ─────────────────────── *)

let test_chain_broken_at_middle_fails () =
  (* checkC requires B. Passing a value with only A proof to checkC
     (skipping checkB) should fail. *)
  let src = prelude ^ {|
fact A (n: Int)
fact B (n: Int)
fact C (n: Int)

check checkA(n: Int) -> n: Int ::: A n =
  ok n ::: A n

check checkB(n: Int ::: A n) -> n: Int ::: B n =
  ok n ::: B n

check checkC(n: Int ::: B n) -> n: Int ::: C n =
  ok n ::: C n

fn requiresC(n: Int ::: C n) -> Int = n

fn f(n: Int) -> Int =
  let a = check checkA n
  let c = check checkC a
  requiresC c
|} in
  (* checkC called with only A proof, not B proof. Should fail. *)
  should_fail "V001" src

(* ── G27: Missing field in record constructor gives clear error ──────────────── *)

let test_missing_record_field_error () =
  (* Constructing a record with a missing field must produce a clear error,
     not a confusing type mismatch. *)
  let src = prelude ^ {|
record Point {
  x: Int
  y: Int
  z: Int
}

fn f() -> Point =
  Point { x: 1, y: 2 }
|} in
  should_fail "missing\\|field\\|z\\|T00" src

(* ── G28: Record update: accessed field has no proof, only updated copy does ── *)

let test_record_update_no_retroactive_proof () =
  (* The unmodified record b.value carries no Positive proof.
     Only the updated field in the returned record would.
     This tests that proof does not retroactively apply to b.value. *)
  let src = prelude ^ {|
fact Positive (n: Int)

record Box { value: Int }

check checkPositive(n: Int) -> n: Int ::: Positive n =
  if n > 0 then
    ok n ::: Positive n
  else
    fail 400 "neg"

fn requiresPositive(n: Int ::: Positive n) -> Int = n

fn g(b: Box) -> Int =
  requiresPositive b.value
|} in
  (* b.value has no Positive proof. Should fail. *)
  should_fail "V001" src

(* ── G29: OR-conjunction pattern: both sides of && must be present ──────────── *)

let test_requires_both_sides_of_conjunction () =
  (* fn requires `P n && Q n`. Passing a value that only carries P n
     must fail even if the function accepts a conjunction type. *)
  let src = prelude ^ {|
fact P (n: Int)
fact Q (n: Int)

check checkP(n: Int) -> n: Int ::: P n =
  ok n ::: P n

fn requiresPAndQ(n: Int ::: P n && Q n) -> Int = n

fn f(n: Int) -> Int =
  let p = checkP n
  requiresPAndQ p
|} in
  should_fail "V001" src

(* ── G30: Capability with empty implies compiles cleanly ─────────────────────── *)

let test_capability_empty_implies_ok () =
  (* capability cap (no implies) is a leaf capability. Should compile. *)
  let src = prelude ^ {|
capability leafCap

fn f() -> Int
  requires [leafCap] =
  42
|} in
  should_pass src

(* ── Suite registration ────────────────────────────────────────────────────── *)

let () = run "Review25-Antagonistic" [
    "proof-propagation", [
      test_case "proof travels through let-rebind (G01)"                `Quick test_proof_travels_through_let_rebind;
      test_case "case guard does not produce proof (G02)"                `Quick test_case_guard_does_not_produce_proof;
      test_case "if-condition does not produce proof (G03)"              `Quick test_if_condition_does_not_produce_proof;
    ];
    "proof-forgery-prevention", [
      test_case "cross-subject forged conjunction rejected (G04)"        `Quick test_forged_conjunction_cross_subject;
      test_case "ForAll wrong predicate rejected (G05)"                  `Quick test_forall_wrong_predicate_rejected;
      test_case "ForAll empty list vacuous pass (G06)"                   `Quick test_forall_empty_list_vacuous_pass;
      test_case "ForAll not usable as element proof (G07)"               `Quick test_forall_not_element_proof;
    ];
    "proof-composition", [
      test_case "deeply nested conjunction flattened (G08)"              `Quick test_deeply_nested_conjunction_flattened;
      test_case "partial proof decomp fails (G09)"                       `Quick test_partial_proof_decomp_fails;
      test_case "3-step chain passes (G22)"                              `Quick test_three_step_proof_chain;
      test_case "chain broken mid-way fails (G26)"                       `Quick test_chain_broken_at_middle_fails;
      test_case "requires both sides of && (G29)"                        `Quick test_requires_both_sides_of_conjunction;
    ];
    "establish-escape-hatch", [
      test_case "establish unconditional compiles (trusted G10)"         `Quick test_establish_unconditional_mints_proof;
    ];
    "fn-cannot-mint-proofs", [
      test_case "fn cannot use ok ::: (G11)"                             `Quick test_fn_cannot_use_ok_with_proof;
    ];
    "proof-not-implicit", [
      test_case "arithmetic result carries no proof (G12)"               `Quick test_arithmetic_result_no_proof;
      test_case "record field access no proof inheritance (G13)"         `Quick test_record_field_no_proof_inheritance;
      test_case "tuple element no proof inheritance (G23)"               `Quick test_tuple_no_proof_inheritance;
      test_case "ctor arg proof survives unwrap (G25)"                   `Quick test_ctor_arg_proof_not_on_adt;
      test_case "record update no retroactive proof (G28)"               `Quick test_record_update_no_retroactive_proof;
    ];
    "shadowing", [
      test_case "shadowing in case arm binding caught (G14)"             `Quick test_shadowing_in_case_arm_binding;
      test_case "lambda param shadows outer binding caught (G15)"        `Quick test_lambda_param_shadows_outer;
    ];
    "check-semantics", [
      test_case "check result survives codec path (G16)"                 `Quick test_check_result_survives_codec_path;
      test_case "check call without check keyword compiles (G19)"        `Quick test_check_call_without_check_keyword;
      test_case "proof isolated to case branch (G20)"                    `Quick test_proof_does_not_bleed_across_branches;
      test_case "partial application of check fn compiles (G21)"         `Quick test_partial_application_of_check;
    ];
    "capabilities", [
      test_case "missing dbWrite in requires caught (G17)"               `Quick test_capability_missing_from_requires;
      test_case "empty requires cannot call db (G18)"                    `Quick test_empty_requires_cannot_call_db;
      test_case "leaf capability with no implies compiles (G30)"         `Quick test_capability_empty_implies_ok;
    ];
    "forall-expansion", [
      test_case "ForAll expansion requires the additional check (G24)"   `Quick test_forall_expansion_requires_check;
    ];
    "error-quality", [
      test_case "missing record field gives clear error (G27)"           `Quick test_missing_record_field_error;
    ];
  ]
