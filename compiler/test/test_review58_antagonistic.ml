(** Antagonistic regression tests for Critical Review 58.

    This review audits:
    1. Proof tracking through direct `case expr of` vs `let x = expr; case x of`
    2. Sequential filterCheck proof accumulation (limitation)
    3. ForAll proof loss on second sequential filter
    4. `establish` + `attachFact` bypass of `check` semantics
    5. Multi-parameter proof parameter swapping (same-type parameters)
    6. Proofs lost when stored in/extracted from ADT constructors
    7. Check function that always succeeds (no linter warning)
    8. Proof conjunction commutativity
    9. Deep proof chains (7+)
    10. ForAll empty-list rejection
    11. allCheck with named return type requirement
    12. Case exhaustiveness with all-guarded arms
    13. `ok` returning wrong value name vs declared binding
    14. Capability checking in fn vs handler
    15. Proof mismatch error message quality
    16. Shadowing of proof-carrying names
    17. Nested ADT proof loss verification
    18. ForAll proof forgery via establish
    19. ForAll direct case vs let-bound case (key bug)
    20. Fact redeclaration detection
*)

open Alcotest

let compiler =
  match Sys.getenv_opt "TESL_OCAML_COMPILER" with
  | Some p when Sys.file_exists p -> p
  | _ ->
    (match Sys.getenv_opt "TESL_BIN" with
     | Some v when Filename.basename v = "main.exe" && Sys.file_exists v -> v
     | _ ->
       let dir = Filename.dirname Sys.argv.(0) in
       let candidate = Filename.concat (Filename.dirname dir) "bin/main.exe" in
       let candidate2 = Filename.concat dir "../bin/main.exe" in
       if Sys.file_exists candidate then candidate
       else if Sys.file_exists candidate2 then candidate2
       else "tesl")

let run_command cmd =
  let ic = Unix.open_process_in cmd in
  let out = In_channel.input_all ic in
  let status = Unix.close_process_in ic in
  let code =
    match status with
    | Unix.WEXITED c -> c
    | Unix.WSIGNALED n -> 128 + n
    | Unix.WSTOPPED n -> 128 + n
  in
  (code, out)

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  run_command (String.concat " " quoted ^ " 2>&1")

let failf fmt = Printf.ksprintf failwith fmt

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-r58" "" in
  let name =
    let re = Str.regexp "module[ \\t\\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
    try
      ignore (Str.search_forward re content 0);
      let mname = Str.matched_group 1 content in
      let buf = Buffer.create (String.length mname + 4) in
      String.iteri (fun i c ->
        if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
        else if c >= 'A' && c <= 'Z' then begin
          Buffer.add_char buf '-';
          Buffer.add_char buf (Char.lowercase_ascii c)
        end else
          Buffer.add_char buf c
      ) mname;
      Buffer.contents buf ^ ".tesl"
    with Not_found -> "test.tesl"
  in
  let path = Filename.concat dir name in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected compilation success, got:\n%s" out)

let should_fail pattern src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but compilation succeeded" pattern;
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pattern out)

let base_header = {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, Bool(..), List, Fact, forgetFact, attachFact, detachFact, introAnd, andLeft, andRight]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.List exposing [List.filterCheck, List.allCheck, List.length]
|}

(* ══════════════════════════════════════════════════════════════════════════
   R58_DC — Direct case expression proof tracking
   ══════════════════════════════════════════════════════════════════════════ *)

(* R58_DC01 FIXED: direct `case f() of` now correctly tracks named proofs (fixed in R58).
   `case allCheckPos nums of Something r ->` and `let x = allCheckPos nums; case x of Something r ->`
   are now equivalent — proof propagates in both cases. *)
let r58_dc01_direct_case_loses_proof () =
  should_pass (
    base_header ^ {|
fact IsPositive (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

fn needsForAll(xs: List Int ::: ForAll (IsPositive) xs) -> Int =
  List.length xs

fn allCheckPos(nums: List Int) -> Maybe (r: List Int ::: ForAll (IsPositive) r) =
  List.allCheck checkPos nums

fn countDirect(nums: List Int) -> Int =
  case allCheckPos nums of
    Something r -> needsForAll r
    Nothing -> 0
|})

(* R58_DC02: let-bound case DOES preserve the named proof — positive control *)
let r58_dc02_let_case_preserves_proof () =
  should_pass (
    base_header ^ {|
fact IsPositive (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

fn needsForAll(xs: List Int ::: ForAll (IsPositive) xs) -> Int =
  List.length xs

fn allCheckPos(nums: List Int) -> Maybe (r: List Int ::: ForAll (IsPositive) r) =
  List.allCheck checkPos nums

# let-bound case preserves proof
fn countViaLet(nums: List Int) -> Int =
  let result = allCheckPos nums
  case result of
    Something r -> needsForAll r
    Nothing -> 0
|})

(* ══════════════════════════════════════════════════════════════════════════
   R58_SF — Sequential filterCheck proof loss
   ══════════════════════════════════════════════════════════════════════════ *)

(* R58_SF01: Sequential filterCheck DROPS the prior ForAll proof entirely.
   After filterCheck checkPos gives ForAll(IsPositive), a second
   filterCheck checkSmall REPLACES it with ForAll(IsSmall) — not accumulates. *)
let r58_sf01_sequential_filter_drops_prior_proof () =
  should_fail "does not statically satisfy.*ForAll.*IsPositive" (
    base_header ^ {|
fact IsPositive (n: Int)
fact IsSmall (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

check checkSmall(n: Int) -> n: Int ::: IsSmall n =
  if n < 100 then
    ok n ::: IsSmall n
  else
    fail 400 "too big"

fn needsPos(xs: List Int ::: ForAll (IsPositive) xs) -> Int =
  List.length xs

fn badSeqFilter(nums: List Int) -> Int =
  let pos = List.filterCheck checkPos nums
  let posSmall = List.filterCheck checkSmall pos
  needsPos posSmall
|})

(* R58_SF02: Combined filterCheck (&&) DOES accumulate both proofs *)
let r58_sf02_combined_filter_accumulates () =
  should_pass (
    base_header ^ {|
fact IsPositive (n: Int)
fact IsSmall (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

check checkSmall(n: Int) -> n: Int ::: IsSmall n =
  if n < 100 then
    ok n ::: IsSmall n
  else
    fail 400 "too big"

fn needsBoth(xs: List Int ::: ForAll (IsPositive && IsSmall) xs) -> Int =
  List.length xs

fn goodCombinedFilter(nums: List Int) -> Int =
  let filtered = List.filterCheck (checkPos && checkSmall) nums
  needsBoth filtered
|})

(* R58_SF03 FIXED: Sequential filterCheck now DOES produce the combined ForAll proof (fixed in R58).
   filterCheck(checkSmall, filterCheck(checkPos, xs)) → ForAll(IsPositive && IsSmall). *)
let r58_sf03_sequential_no_combined_proof () =
  should_pass (
    base_header ^ {|
fact IsPositive (n: Int)
fact IsSmall (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

check checkSmall(n: Int) -> n: Int ::: IsSmall n =
  if n < 100 then
    ok n ::: IsSmall n
  else
    fail 400 "too big"

fn needsBoth(xs: List Int ::: ForAll (IsPositive && IsSmall) xs) -> Int =
  List.length xs

fn seqFails(nums: List Int) -> Int =
  let pos = List.filterCheck checkPos nums
  let posSmall = List.filterCheck checkSmall pos
  needsBoth posSmall
|})

(* ══════════════════════════════════════════════════════════════════════════
   R58_ES — establish as trusted bypass
   ══════════════════════════════════════════════════════════════════════════ *)

(* R58_ES01: establish + attachFact bypasses check semantics — compiles successfully.
   This is by design (establish is a trusted boundary) but must be documented clearly.
   This test verifies the CURRENT behavior: establish can satisfy any check requirement. *)
let r58_es01_establish_bypasses_check_compiles () =
  should_pass (
    base_header ^ {|
fact IsPositive (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

fn requiresPositive(n: Int ::: IsPositive n) -> Int = n

establish forgePositive(n: Int) -> Fact (IsPositive n) =
  IsPositive n

fn forgery(n: Int) -> Int =
  let proof = forgePositive n
  let faked = attachFact n proof
  requiresPositive faked
|})

(* R58_ES02: calling a check function inline (without let) as argument to a proof-requiring fn
   is rejected — proof requires a trackable subject, not an inline expression.
   Note: the error is "no trackable subject", not "must be called with check keyword" — the
   inline call evaluates but the result has no named binding for proof tracking. *)
let r58_es02_establish_cannot_be_called_as_check () =
  should_fail "no trackable subject" (
    base_header ^ {|
fact IsPositive (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

fn requiresPositive(n: Int ::: IsPositive n) -> Int = n

fn badCall(n: Int) -> Int =
  # Calling check function without `check` keyword
  requiresPositive (checkPos n)
|})

(* ══════════════════════════════════════════════════════════════════════════
   R58_MP — Multi-parameter proof same-type parameter swapping
   ══════════════════════════════════════════════════════════════════════════ *)

(* R58_MP01: Same-type parameter swap IS detected at call site (not just definition).
   fact InBounds (lo: Int)(hi: Int)(n: Int) — swapping lo/hi at call site is rejected *)
let r58_mp01_same_type_param_swap_detected () =
  should_fail "does not statically satisfy" (
    base_header ^ {|
fact InBounds (lo: Int) (hi: Int) (n: Int)

check checkInBounds(lo: Int, hi: Int, n: Int) -> n: Int ::: InBounds lo hi n =
  if n >= lo && n <= hi then
    ok n ::: InBounds lo hi n
  else
    fail 400 "out of bounds"

# lo=1, hi=10 → proves InBounds 1 10 n
# But fn declares InBounds hi lo n (swapped!) — detectable because literal values
fn requiresSwapped(lo: Int, hi: Int, n: Int ::: InBounds hi lo n) -> Int = n

fn badSwap(n: Int) -> Int =
  let v = check checkInBounds 1 10 n
  requiresSwapped 1 10 v
|})

(* R58_MP02: Same-type param swap at declaration level IS detected (type-based) *)
let r58_mp02_same_type_param_swap_at_decl () =
  should_fail "does not statically satisfy" (
    base_header ^ {|
fact OwnedBy (userId: Int) (taskId: Int)

check checkOwned(userId: Int, taskId: Int) -> taskId: Int ::: OwnedBy userId taskId =
  if True then
    ok taskId ::: OwnedBy userId taskId
  else
    fail 403 "not owned"

# requiresOwned declares OwnedBy task user (swapped) — both are Int
fn requiresOwned(userId: Int, task: Int ::: OwnedBy task userId) -> Int = task

fn test(uid: Int, tid: Int) -> Int =
  let ownedTask = check checkOwned uid tid
  requiresOwned uid ownedTask
|})

(* ══════════════════════════════════════════════════════════════════════════
   R58_ADT — Proof behavior in ADT constructors
   ══════════════════════════════════════════════════════════════════════════ *)

(* R58_ADT01: Proof is LOST when stored in an UNANNOTATED ADT field.
   The fix is to declare the field with a proof annotation:
     type Container = Wrapped (value: Int ::: IsPositive value)
   and use the ? pack return syntax. See lesson52-maybe-proof.tesl. *)
let r58_adt01_proof_lost_in_adt () =
  should_fail "does not statically satisfy" (
    base_header ^ {|
fact IsPositive (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

fn requiresPositive(n: Int ::: IsPositive n) -> Int = n

type Container
  = Wrapped Int
  | Empty

fn wrapProven(n: Int ::: IsPositive n) -> Container = Wrapped n

fn extractAndUse(c: Container) -> Int =
  case c of
    Wrapped v -> requiresPositive v  # proof is lost after pattern match
    Empty -> 0
|})

(* R58_ADT02: Plain `Maybe Int` loses proof — use `Maybe (T ? P)` pack syntax instead.
   `fn f(...) -> Maybe (Int ? IsPositive)` preserves the proof through the Maybe wrapper. *)
let r58_adt02_proof_lost_through_maybe () =
  should_fail "does not statically satisfy" (
    base_header ^ {|
fact IsPositive (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

fn requiresPositive(n: Int ::: IsPositive n) -> Int = n

fn wrapInMaybe(n: Int ::: IsPositive n) -> Maybe Int = Something n

fn extractProof(m: Maybe Int) -> Int =
  case m of
    Something v -> requiresPositive v  # proof is lost through Maybe
    Nothing -> 0
|})

(* R58_ADT03: Proof is preserved within same scope (control case) *)
let r58_adt03_proof_preserved_in_scope () =
  should_pass (
    base_header ^ {|
fact IsPositive (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

fn requiresPositive(n: Int ::: IsPositive n) -> Int = n

fn testScope(n: Int) -> Int =
  let proven = check checkPos n
  # proof is still intact here (not stored in ADT)
  requiresPositive proven
|})

(* ══════════════════════════════════════════════════════════════════════════
   R58_CJ — Proof conjunction commutativity
   ══════════════════════════════════════════════════════════════════════════ *)

(* R58_CJ01: Proof conjunction IS commutative — having A && B satisfies B && A *)
let r58_cj01_conjunction_is_commutative () =
  should_pass (
    base_header ^ {|
fact A (n: Int)
fact B (n: Int)

check checkA(n: Int) -> n: Int ::: A n =
  if n > 0 then
    ok n ::: A n
  else
    fail 400 "bad"

check checkB(n: Int) -> n: Int ::: B n =
  if n < 100 then
    ok n ::: B n
  else
    fail 400 "bad"

fn needsBandA(n: Int ::: B n && A n) -> Int = n

fn testComm(n: Int) -> Int =
  let a = check checkA n
  let ab = check checkB a
  # ab has A && B, we need B && A — should work (commutative)
  needsBandA ab
|})

(* R58_CJ02: Deep conjunction commutativity (A && B && C == C && B && A) *)
let r58_cj02_deep_conjunction_commutative () =
  should_pass (
    base_header ^ {|
fact A (n: Int)
fact B (n: Int)
fact C (n: Int)

check checkA(n: Int) -> n: Int ::: A n =
  if n > 0 then
    ok n ::: A n
  else
    fail 400 "bad"

check checkB(n: Int ::: A n) -> n: Int ::: B n =
  if n < 1000 then
    ok n ::: B n
  else
    fail 400 "bad"

check checkC(n: Int ::: A n && B n) -> n: Int ::: C n =
  if n != 42 then
    ok n ::: C n
  else
    fail 400 "bad"

fn needsCBA(n: Int ::: C n && B n && A n) -> Int = n

fn testDeepComm(n: Int) -> Int =
  let a = check checkA n
  let b = check checkB a
  let c = check checkC b
  # c has A && B && C, we need C && B && A
  needsCBA c
|})

(* ══════════════════════════════════════════════════════════════════════════
   R58_GC — Guarded case exhaustiveness
   ══════════════════════════════════════════════════════════════════════════ *)

(* R58_GC01: All-guarded case IS rejected (requires catch-all) *)
let r58_gc01_all_guarded_requires_catchall () =
  should_fail "only appear in guarded arms" (
    base_header ^ {|
type Shape
  = Circle Int
  | Square Int
  | Triangle Int Int

fn describeGuarded(s: Shape) -> String =
  case s of
    Circle r where r > 0 -> "big circle"
    Square n where n > 0 -> "big square"
    Triangle a b where a > 0 -> "triangle"
|})

(* R58_GC02: Partial coverage (missing constructor) IS rejected *)
let r58_gc02_partial_coverage_rejected () =
  should_fail "non-exhaustive case.*Triangle" (
    base_header ^ {|
type Shape
  = Circle Int
  | Square Int
  | Triangle Int Int

fn partial(s: Shape) -> String =
  case s of
    Circle _ -> "circle"
    Square _ -> "square"
|})

(* R58_GC03 FIXED: Mixed guarded + unguarded arms for the SAME constructor now accepted (fixed in R58).
   `Circle r where r > 100` + `Circle _` correctly covers all Circle cases together.
   Multi-field unnamed constructors (`Triangle Int Int`) also now work correctly. *)
let r58_gc03_mixed_guarded_same_ctor_rejected () =
  should_pass (
    base_header ^ {|
type Shape
  = Circle Int
  | Square Int
  | Triangle Int Int

fn describeWithCatchAll(s: Shape) -> String =
  case s of
    Circle r where r > 100 -> "huge circle"
    Circle _ -> "small circle"
    Square _ -> "square"
    Triangle _ _ -> "triangle"
|})

(* ══════════════════════════════════════════════════════════════════════════
   R58_OK — Wrong ok return in check functions
   ══════════════════════════════════════════════════════════════════════════ *)

(* R58_OK01: ok returning wrong proof predicate is rejected *)
let r58_ok01_wrong_proof_in_ok () =
  should_fail "ok proof does not match declared return spec" (
    base_header ^ {|
fact IsPositive (n: Int)
fact IsSmall (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsSmall n  # wrong proof!
  else
    fail 400 "bad"
|})

(* R58_OK02: ok returning wrong binding name is rejected *)
let r58_ok02_wrong_binding_name_in_ok () =
  should_fail "ok expression returns" (
    base_header ^ {|
fact IsPositive (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    let one = 1
    ok one ::: IsPositive n  # wrong name: `one` instead of `n`
  else
    fail 400 "bad"
|})

(* ══════════════════════════════════════════════════════════════════════════
   R58_SH — Shadowing prevention
   ══════════════════════════════════════════════════════════════════════════ *)

(* R58_SH01: Shadowing a proof-carrying variable is rejected *)
let r58_sh01_shadowing_proof_var_rejected () =
  should_fail "shadows existing name" (
    base_header ^ {|
fact IsPositive (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

fn requiresPositive(n: Int ::: IsPositive n) -> Int = n

fn testShadow(n: Int) -> Int =
  let proven = check checkPos n
  let proven = 42  # shadow the proof-carrying binding
  requiresPositive proven
|})

(* R58_SH02: Shadowing a function parameter is rejected *)
let r58_sh02_shadowing_parameter_rejected () =
  should_fail "shadows existing name" (
    base_header ^ {|
fact IsPositive (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

fn test(n: Int) -> Int =
  let n = check checkPos n  # shadows parameter
  n
|})

(* ══════════════════════════════════════════════════════════════════════════
   R58_DU — Duplicate declarations
   ══════════════════════════════════════════════════════════════════════════ *)

(* R58_DU01: Duplicate fact declaration is rejected *)
let r58_du01_duplicate_fact_rejected () =
  should_fail "duplicate fact" (
    base_header ^ {|
fact IsPositive (n: Int)
fact IsPositive (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
|})

(* ══════════════════════════════════════════════════════════════════════════
   R58_CP — Capability propagation correctness
   ══════════════════════════════════════════════════════════════════════════ *)

(* R58_CP01: Missing capability in fn calling capability-requiring fn *)
let r58_cp01_missing_capability_rejected () =
  should_fail "uses privileged operations.*requiring" (
    base_header ^ {|
import Tesl.DB exposing [dbRead]
capability myDbRead implies dbRead

entity Item table "items" primaryKey id {
  id: String
  value: Int
}

database TestDb {
  backend postgres
  schema "test"
  entities [Item]
  postgres {
    database env("TESL_POSTGRES_DATABASE")
    user env("TESL_POSTGRES_USER")
    password env("TESL_POSTGRES_PASSWORD")
    host env("TESL_POSTGRES_HOST")
    port envInt("TESL_POSTGRES_PORT", 5432)
    socket env("TESL_POSTGRES_SOCKET")
  }
}

fn readItems() -> List Item
  requires [myDbRead] =
  select item from Item

fn callWithout() -> Int =
  List.length (readItems())
|})

(* R58_CP02: Capability transitivity through implies works correctly *)
let r58_cp02_capability_transitivity () =
  should_pass (
    base_header ^ {|
import Tesl.DB exposing [dbRead]
import Tesl.Random exposing [random]

capability myRandom implies random
capability myFull implies myRandom

fn needsRandom() -> Int
  requires [myRandom] = 0

fn testTransitive() -> Int
  requires [myFull] =
  needsRandom()
|})

(* ══════════════════════════════════════════════════════════════════════════
   R58_FC — ForAll fabrication prevention
   ══════════════════════════════════════════════════════════════════════════ *)

(* R58_FC01: Passing unfiltered list to ForAll-requiring fn is rejected *)
let r58_fc01_forall_fabrication_rejected () =
  should_fail "does not statically satisfy.*ForAll" (
    base_header ^ {|
fact IsPositive (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

fn needsForAll(xs: List Int ::: ForAll (IsPositive) xs) -> Int =
  List.length xs

fn badFabricate(nums: List Int) -> Int =
  needsForAll nums
|})

(* R58_FC02: Empty list does NOT vacuously satisfy ForAll *)
let r58_fc02_empty_list_no_forall () =
  should_fail "does not statically satisfy.*ForAll" (
    base_header ^ {|
fact IsPositive (n: Int)

fn needsForAll(xs: List Int ::: ForAll (IsPositive) xs) -> Int =
  List.length xs

fn testEmpty() -> Int =
  let emptyNums: List Int = []
  needsForAll emptyNums
|})

(* ══════════════════════════════════════════════════════════════════════════
   R58_CH — Complex proof chain tests
   ══════════════════════════════════════════════════════════════════════════ *)

(* R58_CH01: 4-check AND chain works with proof accumulation *)
let r58_ch01_4check_and_chain_works () =
  should_pass (
    base_header ^ {|
fact A (n: Int)
fact B (n: Int)
fact C (n: Int)
fact D (n: Int)

check checkA(n: Int) -> n: Int ::: A n =
  if n > 0 then
    ok n ::: A n
  else
    fail 400 "fail"

check checkB(n: Int) -> n: Int ::: B n =
  if n < 1000 then
    ok n ::: B n
  else
    fail 400 "fail"

check checkC(n: Int) -> n: Int ::: C n =
  if n != 42 then
    ok n ::: C n
  else
    fail 400 "fail"

check checkD(n: Int) -> n: Int ::: D n =
  if n != 99 then
    ok n ::: D n
  else
    fail 400 "fail"

fn needsAll4(n: Int ::: A n && B n && C n && D n) -> Int = n

fn checkAll4(n: Int) -> Int =
  let validated = check (checkA && checkB && checkC && checkD) n
  needsAll4 validated
|})

(* R58_CH02: 7-proof sequential chain through individual checks *)
let r58_ch02_7proof_sequential_chain () =
  should_pass (
    base_header ^ {|
fact A (n: Int)
fact B (n: Int)
fact C (n: Int)
fact D (n: Int)
fact E (n: Int)
fact F (n: Int)
fact G (n: Int)

check checkA(n: Int) -> n: Int ::: A n =
  if n > 0 then
    ok n ::: A n
  else
    fail 400 "fail"

check checkB(n: Int ::: A n) -> n: Int ::: B n =
  if n < 1000 then
    ok n ::: B n
  else
    fail 400 "fail"

check checkC(n: Int ::: A n && B n) -> n: Int ::: C n =
  if n != 42 then
    ok n ::: C n
  else
    fail 400 "fail"

check checkD(n: Int ::: A n && B n && C n) -> n: Int ::: D n =
  if n != 99 then
    ok n ::: D n
  else
    fail 400 "fail"

check checkE(n: Int ::: A n && B n && C n && D n) -> n: Int ::: E n =
  if n != 500 then
    ok n ::: E n
  else
    fail 400 "fail"

check checkF(n: Int ::: A n && B n && C n && D n && E n) -> n: Int ::: F n =
  if n != 777 then
    ok n ::: F n
  else
    fail 400 "fail"

check checkG(n: Int ::: A n && B n && C n && D n && E n && F n) -> n: Int ::: G n =
  ok n ::: G n

fn needs7(n: Int ::: A n && B n && C n && D n && E n && F n && G n) -> Int = n

fn build7(n: Int) -> Int =
  let a = check checkA n
  let b = check checkB a
  let c = check checkC b
  let d = check checkD c
  let e = check checkE d
  let f = check checkF e
  let g = check checkG f
  needs7 g
|})

(* R58_CH03: Partial chain fails at the missing step *)
let r58_ch03_partial_chain_fails () =
  should_fail "does not statically satisfy" (
    base_header ^ {|
fact A (n: Int)
fact B (n: Int)
fact C (n: Int)

check checkA(n: Int) -> n: Int ::: A n =
  if n > 0 then
    ok n ::: A n
  else
    fail 400 "fail"

check checkB(n: Int ::: A n) -> n: Int ::: B n =
  if n < 1000 then
    ok n ::: B n
  else
    fail 400 "fail"

fn needsABC(n: Int ::: A n && B n && C n) -> Int = n

fn missingC(n: Int) -> Int =
  let a = check checkA n
  let b = check checkB a
  needsABC b  # missing C proof
|})

(* ══════════════════════════════════════════════════════════════════════════
   R58_DA — Detach/attach subject mismatch
   ══════════════════════════════════════════════════════════════════════════ *)

(* R58_DA01: Attaching proof from subject x to different subject y is rejected *)
let r58_da01_cross_subject_attach_rejected () =
  should_fail "subject mismatch" (
    base_header ^ {|
fact IsPositive (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

fn requiresPositive(n: Int ::: IsPositive n) -> Int = n

fn sneakyAttach(x: Int, y: Int) -> Int =
  let validX = check checkPos x
  let proof = detachFact validX
  let fakeY = attachFact y proof  # attaching x's proof to y
  requiresPositive fakeY
|})

(* R58_DA02: detach and re-attach to SAME subject works correctly *)
let r58_da02_same_subject_reattach_ok () =
  should_pass (
    base_header ^ {|
fact IsPositive (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

fn requiresPositive(n: Int ::: IsPositive n) -> Int = n

fn detachReattach(n: Int) -> Int =
  let proven = check checkPos n
  let raw = forgetFact proven
  let pf = detachFact proven
  let back = attachFact raw pf
  requiresPositive back
|})

(* ══════════════════════════════════════════════════════════════════════════
   R58_ER — Error message quality
   ══════════════════════════════════════════════════════════════════════════ *)

(* R58_ER01: Partial proof error should mention required proof *)
let r58_er01_partial_proof_error_quality () =
  should_fail "A n && B n" (
    base_header ^ {|
fact A (n: Int)
fact B (n: Int)

check checkA(n: Int) -> n: Int ::: A n =
  if n > 0 then
    ok n ::: A n
  else
    fail 400 "bad"

fn needsAandB(n: Int ::: A n && B n) -> Int = n

fn onlyA(n: Int) -> Int =
  let a = check checkA n
  needsAandB a
|})

(* R58_ER02: ForAll proof error message mentions validate with check function *)
let r58_er02_forall_error_message () =
  should_fail "validate.*check function" (
    base_header ^ {|
fact IsPositive (n: Int)

fn needsForAll(xs: List Int ::: ForAll (IsPositive) xs) -> Int =
  List.length xs

fn badCall(nums: List Int) -> Int =
  needsForAll nums
|})

(* ══════════════════════════════════════════════════════════════════════════
   R58_IC — introAnd/andLeft/andRight with establish
   ══════════════════════════════════════════════════════════════════════════ *)

(* R58_IC01: introAnd with establish-produced Facts works *)
let r58_ic01_introand_with_establish () =
  should_pass (
    base_header ^ {|
fact A (n: Int)
fact B (n: Int)

establish makeA(n: Int) -> Fact (A n) = A n
establish makeB(n: Int) -> Fact (B n) = B n

fn needsBoth(n: Int ::: A n && B n) -> Int = n

fn testIntroAnd(n: Int) -> Int =
  let pA = makeA n
  let pB = makeB n
  let pAB = introAnd pA pB
  let proven = attachFact n pAB
  needsBoth proven
|})

(* R58_IC02: andLeft extracts A from A && B *)
let r58_ic02_andleft_extracts () =
  should_pass (
    base_header ^ {|
fact A (n: Int)
fact B (n: Int)

establish makeA(n: Int) -> Fact (A n) = A n
establish makeB(n: Int) -> Fact (B n) = B n

fn needsA(n: Int ::: A n) -> Int = n

fn testAndLeft(n: Int) -> Int =
  let pA = makeA n
  let pB = makeB n
  let pAB = introAnd pA pB
  let pA2 = andLeft pAB
  let nWithA = attachFact n pA2
  needsA nWithA
|})

(* ══════════════════════════════════════════════════════════════════════════
   Test suite registration
   ══════════════════════════════════════════════════════════════════════════ *)

let () =
  run "Review58-Antagonistic" [
    "direct-case-proof-loss", [
      test_case "R58_DC01 direct case now tracks named proof (fixed)" `Quick r58_dc01_direct_case_loses_proof;
      test_case "R58_DC02 let-bound case preserves proof (control)" `Quick r58_dc02_let_case_preserves_proof;
    ];
    "sequential-filter-proof-loss", [
      test_case "R58_SF01 sequential filterCheck drops prior ForAll" `Quick r58_sf01_sequential_filter_drops_prior_proof;
      test_case "R58_SF02 combined filterCheck accumulates ForAll" `Quick r58_sf02_combined_filter_accumulates;
      test_case "R58_SF03 sequential filterCheck now accumulates ForAll (fixed)" `Quick r58_sf03_sequential_no_combined_proof;
    ];
    "establish-bypass", [
      test_case "R58_ES01 establish+attachFact bypasses check (by design)" `Quick r58_es01_establish_bypasses_check_compiles;
      test_case "R58_ES02 establish fn cannot be called as check" `Quick r58_es02_establish_cannot_be_called_as_check;
    ];
    "multi-param-proof", [
      test_case "R58_MP01 same-type param swap detected at call site" `Quick r58_mp01_same_type_param_swap_detected;
      test_case "R58_MP02 same-type param swap at declaration level" `Quick r58_mp02_same_type_param_swap_at_decl;
    ];
    "adt-unannotated-proof-loss", [
      test_case "R58_ADT01 unannotated ADT field loses proof (use annotated fields instead)" `Quick r58_adt01_proof_lost_in_adt;
      test_case "R58_ADT02 plain Maybe Int loses proof (use Maybe (T ? P) instead)" `Quick r58_adt02_proof_lost_through_maybe;
      test_case "R58_ADT03 proof preserved within scope (control)" `Quick r58_adt03_proof_preserved_in_scope;
    ];
    "proof-conjunction-commutativity", [
      test_case "R58_CJ01 A&&B satisfies B&&A requirement" `Quick r58_cj01_conjunction_is_commutative;
      test_case "R58_CJ02 deep conjunction commutativity" `Quick r58_cj02_deep_conjunction_commutative;
    ];
    "guarded-case-exhaustiveness", [
      test_case "R58_GC01 all-guarded case requires catch-all" `Quick r58_gc01_all_guarded_requires_catchall;
      test_case "R58_GC02 partial coverage rejected" `Quick r58_gc02_partial_coverage_rejected;
      test_case "R58_GC03 mixed guarded same-ctor now accepted (fixed)" `Quick r58_gc03_mixed_guarded_same_ctor_rejected;
    ];
    "ok-return-validation", [
      test_case "R58_OK01 wrong proof predicate in ok rejected" `Quick r58_ok01_wrong_proof_in_ok;
      test_case "R58_OK02 wrong binding name in ok rejected" `Quick r58_ok02_wrong_binding_name_in_ok;
    ];
    "shadowing-prevention", [
      test_case "R58_SH01 shadowing proof-carrying var rejected" `Quick r58_sh01_shadowing_proof_var_rejected;
      test_case "R58_SH02 shadowing fn parameter rejected" `Quick r58_sh02_shadowing_parameter_rejected;
    ];
    "duplicate-declarations", [
      test_case "R58_DU01 duplicate fact rejected" `Quick r58_du01_duplicate_fact_rejected;
    ];
    "capability-propagation", [
      test_case "R58_CP01 missing capability in callee rejected" `Quick r58_cp01_missing_capability_rejected;
      test_case "R58_CP02 capability transitivity through implies" `Quick r58_cp02_capability_transitivity;
    ];
    "forall-fabrication-prevention", [
      test_case "R58_FC01 unfiltered list to ForAll rejected" `Quick r58_fc01_forall_fabrication_rejected;
      test_case "R58_FC02 empty list no vacuous ForAll" `Quick r58_fc02_empty_list_no_forall;
    ];
    "deep-proof-chains", [
      test_case "R58_CH01 4-check AND chain works" `Quick r58_ch01_4check_and_chain_works;
      test_case "R58_CH02 7-proof sequential chain works" `Quick r58_ch02_7proof_sequential_chain;
      test_case "R58_CH03 partial chain fails at missing step" `Quick r58_ch03_partial_chain_fails;
    ];
    "detach-attach-flow", [
      test_case "R58_DA01 cross-subject attach rejected" `Quick r58_da01_cross_subject_attach_rejected;
      test_case "R58_DA02 same-subject detach/reattach ok" `Quick r58_da02_same_subject_reattach_ok;
    ];
    "error-message-quality", [
      test_case "R58_ER01 partial proof error mentions requirement" `Quick r58_er01_partial_proof_error_quality;
      test_case "R58_ER02 ForAll error mentions check function" `Quick r58_er02_forall_error_message;
    ];
    "intro-and-operations", [
      test_case "R58_IC01 introAnd combines establish Facts" `Quick r58_ic01_introand_with_establish;
      test_case "R58_IC02 andLeft extracts A from A&&B" `Quick r58_ic02_andleft_extracts;
    ];
  ]
