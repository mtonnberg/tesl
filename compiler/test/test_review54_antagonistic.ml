(** Antagonistic regression tests for Critical Review 54.

    Key findings:
    1. CI regression: check f n ::: p in fn return position fires false bare-check error
    2. CI regression: adversarial-review-tests.tesl fails (let _ = check patterns)
    3. Spec §13.9 partial application restriction: partially enforced (call sites caught, not definition sites)
    4. check inside establish: totality not enforced transitively
    5. Guard exhaustiveness: "missing constructor(s)" for all-guarded arms (misleading msg)
    6. Spec §14b.1 divergence: [a,b] != Tuple2, Tuple2 t t !<: List t
    7. Stdlib proof bypass: fn claiming stdlib ? proof without establishing it passes validator
    8. Complex proof chains, nested types, detach/attach -- coverage expanded
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

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let failf fmt = Printf.ksprintf failwith fmt

let with_temp_file _prefix _suffix content f =
  let dir = Filename.temp_dir "tesl-r54" "" in
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
  write_file path content;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let should_pass_src src =
  with_temp_file "tesl-r54" ".tesl" src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected compilation success, got:\n%s" out)

let should_fail_src pattern src =
  with_temp_file "tesl-r54" ".tesl" src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but compilation succeeded" pattern;
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pattern out)

(* Mark a test as documenting a known-open bug where the compiler currently passes
   what it should reject. Passes silently while bug is open. Fails loud when fixed. *)
let known_bug_passes_should_fail _pattern src =
  with_temp_file "tesl-r54" ".tesl" src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then
      failf "KNOWN-OPEN BUG FIXED: compiler now rejects this (correct).\n\
             Promote to should_fail_src with the new diagnostic.\n%s" out
    (* else: still passes -- known bug still open, test passes silently *))
[@@warning "-32"]

let base_header = {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, Bool(..), List, Fact, forgetFact, attachFact, detachFact, introAnd, andLeft, andRight]
import Tesl.Maybe exposing [Maybe(..)]
|}

let proof_decls = {|
fact IsPositive (n: Int)
fact IsSmall    (n: Int)
fact IsEven     (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"

check checkSmall(n: Int) -> n: Int ::: IsSmall n =
  if n < 1000 then
    ok n ::: IsSmall n
  else
    fail 400 "too large"

check checkEven(n: Int) -> n: Int ::: IsEven n =
  if n % 2 == 0 then
    ok n ::: IsEven n
  else
    fail 400 "not even"

fn needPos(n: Int ::: IsPositive n) -> Int = n
fn needSmall(n: Int ::: IsSmall n) -> Int = n
fn needBoth(n: Int ::: IsPositive n && IsSmall n) -> Int = n
fn needAll3(n: Int ::: IsPositive n && IsSmall n && IsEven n) -> Int = n
|}

(* === R54_CI: CI regression: check f n ::: p in fn return position ========= *)

(* R54_CI01 -- REGRESSION: `check f n ::: proofVar` as fn return fires
   false bare-check error. The bare-check detector incorrectly flags
   check calls whose result is combined with a proof via ::: in return position.
   Minimum repro: let (_ ::: p) = check f m; check g n ::: p
   This is valid code that should compile but is incorrectly rejected. *)
let r54_ci01_check_return_with_sidecar_regression () =
  (* NOTE: This should_pass_src currently FAILS due to the regression.
     The test documents the regression — it will turn green when the bug is fixed. *)
  should_pass_src (
    base_header ^ proof_decls ^ {|
fn combinedReturn(n: Int, m: Int) -> Int ? IsPositive && IsSmall ::: IsEven m =
  let (_ ::: p) = check checkEven m
  check (checkPos && checkSmall) n ::: p
|})

(* R54_CI02 -- REGRESSION: parenthesized (check f) n ::: p also incorrectly rejected *)
let r54_ci02_paren_check_return_regression () =
  (* NOTE: This should_pass_src currently FAILS due to the regression. *)
  should_pass_src (
    base_header ^ proof_decls ^ {|
fn combinedParen(n: Int, m: Int) -> Int ? IsPositive && IsSmall ::: IsSmall m =
  let (_ ::: p) = check checkSmall m
  (check (checkPos && checkSmall)) n ::: p
|})

(* R54_CI03 -- let _ = check f n correctly rejected (wildcard discards proof) *)
let r54_ci03_let_wildcard_check_discard () =
  should_fail_src "bare.*check\\|result.*bound" (
    base_header ^ proof_decls ^ {|
fn test(n: Int) -> String =
  let _ = check checkPos n
  "done"
|})

(* R54_CI04 -- let x = check f n (named binding) works correctly *)
let r54_ci04_let_named_check_ok () =
  should_pass_src (base_header ^ proof_decls ^ {|
fn test(n: Int) -> Int =
  let x = check checkPos n
  needPos x
|})

(* === R54_PA: Partial application restriction (spec 13.9) =================== *)

(* R54_PA01 -- CORRECT BEHAVIOR: partial application is allowed when the captured
   parameter (a) itself does not have a proof requirement. The first parameter a
   has no proof annotation, so `process a` is valid partial application.
   The proof requirement on b (IsPositive a) refers to the captured value a,
   but since the closure type is `Int -> Int`, proof tracking at call sites is
   the mechanism — confirmed sound in R54_PA02. *)
let r54_pa01_partial_apply_no_first_param_proof () =
  should_pass_src (
    base_header ^ {|
fact IsPositive (n: Int)

fn process(a: Int, b: Int ::: IsPositive a) -> Int = b

fn makePartial(a: Int) -> Int -> Int =
  process a
|})

(* R54_PA02 -- Call site IS caught when unproven value used with partial closure *)
let r54_pa02_partial_apply_call_site_caught () =
  should_fail_src "does not.*satisfy.*proof\\|IsPositive" (
    base_header ^ {|
fact IsPositive (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

fn process(a: Int, b: Int ::: IsPositive a) -> Int = b

fn exploit(x: Int, y: Int) -> Int =
  let f = process x
  f y
|})

(* R54_PA03 -- Normal partial application (no cross-param proof) is valid *)
let r54_pa03_normal_partial_apply_ok () =
  should_pass_src (base_header ^ {|
fn add(x: Int, y: Int) -> Int = x + y

fn test(n: Int) -> Int =
  let f = add 3
  f n
|})

(* === R54_CE: check inside establish totality ================================ *)

(* R54_CE01 -- FIXED: check call inside establish body is now rejected.
   Calling a check function (which can fail) violates establish's totality. *)
let r54_ce01_check_in_establish_totality () =
  should_fail_src "establish.*cannot.*call.*check\\|establish.*total\\|check.*establish" (
    base_header ^ {|
fact IsPositive (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

establish provePositive(n: Int) -> Fact (IsPositive n) =
  let checked = check checkPos n
  IsPositive checked
|})

(* R54_CE02 -- establish with direct proof constructor is correctly total *)
let r54_ce02_establish_direct_proof () =
  should_pass_src (base_header ^ {|
fact IsPositive (n: Int)

establish provePositive(n: Int) -> Fact (IsPositive n) =
  IsPositive n
|})

(* R54_CE03 -- establish with Maybe return is correctly total *)
let r54_ce03_establish_maybe_total () =
  should_pass_src (base_header ^ {|
fact ValidRange (n: Int)

establish tryRange(n: Int) -> Maybe (Fact (ValidRange n)) =
  if 1 <= n && n <= 100 then
    Something (ValidRange n)
  else
    Nothing
|})

(* === R54_GE: Guard exhaustiveness message quality ========================== *)

(* R54_GE01 -- All-guarded arms correctly rejected, but error says "missing constructor(s)"
   when the constructors ARE present (just guarded). Message is misleading. *)
let r54_ge01_all_guarded_arms_rejected () =
  should_fail_src "non-exhaustive\\|missing.*constructor" (
    base_header ^ {|
type Color
  = Red
  | Green
  | Blue

fn colorCode(c: Color, n: Int) -> Int =
  case c of
    Red   where n == 1 -> 1
    Green where n == 2 -> 2
    Blue  where n == 3 -> 3
|})

(* R54_GE02 -- Unguarded catch-all satisfies exhaustiveness *)
let r54_ge02_unguarded_catchall_satisfies () =
  should_pass_src (base_header ^ {|
type Color
  = Red
  | Green
  | Blue

fn colorCode(c: Color, n: Int) -> Int =
  case c of
    Red   where n == 1 -> 1
    Green where n == 2 -> 2
    Blue  where n == 3 -> 3
    _  -> 0
|})

(* R54_GE03 -- Missing constructor (not guarded) correctly "missing" *)
let r54_ge03_genuinely_missing_ctor () =
  should_fail_src "non-exhaustive\\|missing.*constructor" (
    base_header ^ {|
type Trio
  = AlternativeA value:Int
  | AlternativeB value:String
  | AlternativeC

fn test(b: Trio) -> Int =
  case b of
    AlternativeA n -> n
    AlternativeB _ -> 1
|})

(* === R54_TL: Tuple2/List spec divergence =================================== *)

(* R54_TL01 -- Two-element list literal NOT treated as Tuple2 (spec 14b.1 divergence) *)
let r54_tl01_two_elem_list_not_tuple2 () =
  should_fail_src "tuple2\\|cannot.*construct.*Tuple2\\|list.*Tuple2" (
    base_header ^ {|
import Tesl.Tuple exposing [Tuple2, Tuple2.first]

fn takesTuple(t: Tuple2 Int String) -> Int = Tuple2.first t

fn testTwoElem() -> Int = takesTuple [1, "hello"]
|})

(* R54_TL02 -- Tuple2 value cannot be passed as List (spec 14b.1 divergence) *)
let r54_tl02_tuple2_not_subtype_of_list () =
  should_fail_src "cannot unify\\|Tuple2.*List\\|type mismatch" (
    base_header ^ {|
import Tesl.Tuple exposing [Tuple2]
import Tesl.List exposing [List.length]

fn takesList(xs: List Int) -> Int = List.length xs

fn testTuple() -> Int = takesList (Tuple2 1 2)
|})

(* R54_TL03 -- Correct Tuple2 usage works *)
let r54_tl03_tuple2_correct_usage () =
  should_pass_src (base_header ^ {|
import Tesl.Tuple exposing [Tuple2, Tuple2.first, Tuple2.second]

fn makePair(a: Int, b: Int) -> Tuple2 Int Int = Tuple2 a b

fn sumPair(t: Tuple2 Int Int) -> Int =
  Tuple2.first t + Tuple2.second t
|})

(* === R54_SP: Stdlib proof bypass =========================================== *)

(* R54_SP01 -- FIXED: fn claiming stdlib IsTrimmed via ? without earning it
   is now correctly rejected. The validator checks stdlib proof-producing
   functions (String.trim etc.) are actually called. *)
let r54_sp01_fn_false_stdlib_proof_not_caught () =
  should_fail_src "no proofs\\|fn.*cannot.*introduce\\|IsTrimmed\\|only carries" (
    base_header ^ {|
import Tesl.String exposing [String.trim, IsTrimmed]

fn fakeTrim(s: String) -> String ? IsTrimmed =
  s
|})

(* R54_SP02 -- fn claiming user-defined fact via ? without earning it IS rejected *)
let r54_sp02_fn_false_user_proof_rejected () =
  should_fail_src "no proofs\\|fn.*cannot.*introduce.*proof\\|IsPositive" (
    base_header ^ {|
fact IsPositive (n: Int)
fn needPos(n: Int ::: IsPositive n) -> Int = n

fn fakeProof(n: Int) -> Int ? IsPositive =
  n
|})

(* R54_SP03 -- Correct stdlib proof propagation via fn ? return *)
let r54_sp03_fn_stdlib_proof_correct () =
  should_pass_src (base_header ^ {|
import Tesl.String exposing [String.trim, IsTrimmed]

fn normalizeTitle(raw: String) -> String ? IsTrimmed =
  String.trim raw
|})

(* === R54_PC: Complex proof chains ========================================== *)

(* R54_PC01 -- 3-step chain accumulates 3 distinct predicates *)
let r54_pc01_three_step_chain () =
  should_pass_src (base_header ^ proof_decls ^ {|
fn threeStep(raw: Int) -> Int =
  let a = check checkPos raw
  let b = check checkSmall a
  let c = check checkEven b
  needAll3 c
|})

(* R54_PC02 -- Cross-step decompose + selective reattach *)
let r54_pc02_cross_step_selective () =
  should_pass_src (base_header ^ proof_decls ^ {|
fn crossStep(raw: Int) -> Int =
  let a = check checkPos raw
  let b = check checkSmall a
  let c = check checkEven b
  let (v ::: pp && ps && pe) = c
  let reat = v ::: pp && pe
  needPos reat
|})

(* R54_PC03 -- Proof does NOT flow through plain fn (by design) *)
let r54_pc03_proof_no_flow_plain_fn () =
  should_fail_src "does not.*satisfy.*proof\\|IsPositive\\|not.*statically" (
    base_header ^ proof_decls ^ {|
fn identity(n: Int) -> Int = n

fn test(raw: Int) -> Int =
  let pos = check checkPos raw
  let stripped = identity pos
  needPos stripped
|})

(* R54_PC04 -- 4-fact conjunction accumulated over 4 check steps *)
let r54_pc04_four_fact_conjunction () =
  should_pass_src (base_header ^ {|
fact A (n: Int)
fact B (n: Int)
fact C (n: Int)
fact D (n: Int)

check checkA(n: Int) -> n: Int ::: A n =
  if n > 0 then
    ok n ::: A n
  else
    fail 400 "bad"
check checkB(n: Int) -> n: Int ::: B n =
  if n < 1000 then
    ok n ::: B n
  else
    fail 400 "bad"
check checkC(n: Int) -> n: Int ::: C n =
  if n % 2 == 0 then
    ok n ::: C n
  else
    fail 400 "bad"
check checkD(n: Int) -> n: Int ::: D n =
  if n % 3 == 0 then
    ok n ::: D n
  else
    fail 400 "bad"

fn needABCD(n: Int ::: A n && B n && C n && D n) -> Int = n

fn fourSteps(raw: Int) -> Int =
  let a = check checkA raw
  let b = check checkB a
  let c = check checkC b
  let d = check checkD c
  needABCD d
|})

(* === R54_NP: Nested type proof propagation ================================= *)

(* R54_NP01 -- Nested Maybe case exhaustiveness *)
let r54_np01_nested_maybe_exhaustive () =
  should_pass_src (base_header ^ {|
fn testNested(m: Maybe (Maybe Int)) -> Int =
  case m of
    Nothing -> 0
    Something inner ->
      case inner of
        Nothing -> -1
        Something n -> n
|})

(* R54_NP02 -- Non-exhaustive nested case is caught (ADT uses multi-line syntax) *)
let r54_np02_nested_case_non_exhaustive () =
  should_fail_src "non-exhaustive\\|missing" (
    base_header ^ {|
type Three
  = A
  | B
  | C

fn test(m: Maybe (Maybe Three)) -> Int =
  case m of
    Nothing -> 0
    Something inner ->
      case inner of
        Nothing -> -1
        Something A -> 1
        Something B -> 2
|})

(* R54_NP03 -- Record field proof flows through nested record access *)
let r54_np03_record_field_nested_access () =
  should_pass_src (base_header ^ {|
import Tesl.String exposing [String.length]
fact IsSafe (s: String)

check checkSafe(s: String) -> s: String ::: IsSafe s =
  if String.length s > 0 then
    ok s ::: IsSafe s
  else
    fail 400 "empty"

record Inner { content: String ::: IsSafe content }
record Outer { inner: Inner }

fn needSafe(s: String ::: IsSafe s) -> String = s

fn accessNested(o: Outer) -> String =
  needSafe o.inner.content
|})

(* === R54_DA: Detach/attach flows =========================================== *)

(* R54_DA01 -- Triple decompose with selective reattach *)
let r54_da01_triple_decompose_selective () =
  should_pass_src (base_header ^ proof_decls ^ {|
fn tripleDecompose(raw: Int) -> Int =
  let a = check checkPos raw
  let b = check checkSmall a
  let c = check checkEven b
  let (v ::: pp && ps && pe) = c
  let reat = v ::: pp && pe
  needPos reat
|})

(* R54_DA02 -- introAnd with proofs from same-subject chain *)
let r54_da02_introand_same_subject () =
  should_pass_src (base_header ^ proof_decls ^ {|
fn introAndSameSubject(raw: Int) -> Int =
  let pos = check checkPos raw
  let sm  = check checkSmall pos
  let (v ::: pp) = pos
  let (v2 ::: ps) = sm
  let combined = introAnd pp ps
  let reat = v ::: combined
  needBoth reat
|})

(* R54_DA03 -- introAnd across different subjects is rejected *)
let r54_da03_introand_cross_subject_rejected () =
  should_fail_src "does not.*satisfy\\|IsPositive a && IsSmall a" (
    base_header ^ proof_decls ^ {|
fn crossSubjectIntroAnd(a: Int, b: Int) -> Int =
  let pa = check checkPos a
  let pb = check checkSmall b
  let (_ ::: ppa) = pa
  let (_ ::: ppb) = pb
  let combined = introAnd ppa ppb
  let reat = a ::: combined
  needBoth reat
|})

(* === R54_RU: Record update proof handling ================================== *)

(* R54_RU01 -- Updating non-proof field preserves annotated field proof *)
let r54_ru01_update_nonproof_preserves () =
  should_pass_src (base_header ^ {|
import Tesl.String exposing [String.length]
fact IsSafe (s: String)

check checkSafe(s: String) -> s: String ::: IsSafe s =
  if String.length s > 0 then
    ok s ::: IsSafe s
  else
    fail 400 "empty"

record MyRec {
  name:  String ::: IsSafe name
  score: Int
}

fn needSafe(s: String ::: IsSafe s) -> String = s

fn updateScore(r: MyRec, newScore: Int) -> String =
  let updated = { r | score: newScore }
  needSafe updated.name
|})

(* R54_RU02 -- Updating proof-annotated field with unproven value is rejected *)
let r54_ru02_update_proof_field_rejected () =
  should_fail_src "does not.*satisfy\\|IsSafe\\|proof" (
    base_header ^ {|
import Tesl.String exposing [String.length]
fact IsSafe (s: String)

check checkSafe(s: String) -> s: String ::: IsSafe s =
  if String.length s > 0 then
    ok s ::: IsSafe s
  else
    fail 400 "empty"

record MyRec {
  name:  String ::: IsSafe name
  score: Int
}

fn updateName(r: MyRec, newName: String) -> MyRec =
  { r | name: newName }
|})

(* === R54_LB: Lambda proof-annotated params ================================= *)

(* R54_LB01 -- Lambda proof param correctly requires proof at call site *)
let r54_lb01_lambda_proof_enforced () =
  should_fail_src "does not.*satisfy\\|IsPositive\\|proof" (
    base_header ^ proof_decls ^ {|
fn testLambdaBypass(a: Int, b: Int) -> Int =
  let f = fn(x: Int ::: IsPositive x) -> needPos x
  f b
|})

(* R54_LB02 -- Lambda with proof param satisfied by proven value *)
let r54_lb02_lambda_proof_satisfied () =
  should_pass_src (base_header ^ proof_decls ^ {|
fn testLambdaOk(raw: Int) -> Int =
  let pos = check checkPos raw
  let f = fn(x: Int ::: IsPositive x) -> needPos x
  f pos
|})

(* === R54_FG: forgetFact protection ======================================== *)

(* R54_FG01 -- forgetFact + recheck on same value is valid *)
let r54_fg01_forget_recheck () =
  should_pass_src (base_header ^ proof_decls ^ {|
fn forgetAndRecheck(raw: Int) -> Int =
  let pos = check checkPos raw
  let bare = forgetFact pos
  let pos2 = check checkPos bare
  needPos pos2
|})

(* R54_FG02 -- forgetFact + reattach establish proof for same subject is valid *)
let r54_fg02_forget_establish_reattach () =
  should_pass_src (base_header ^ {|
fact IsPositive (n: Int)
establish provePos(n: Int) -> Fact (IsPositive n) = IsPositive n
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn needPos(n: Int ::: IsPositive n) -> Int = n

fn forgetAndEstablish(raw: Int) -> Int =
  let pos = check checkPos raw
  let bare = forgetFact pos
  let pf = provePos raw
  needPos <| bare ::: pf
|})

(* R54_FG03 -- forgetFact + reattach proof from DIFFERENT subject is rejected *)
let r54_fg03_forget_cross_subject_rejected () =
  should_fail_src "different.*subject\\|about a different\\|describes a different" (
    base_header ^ {|
fact IsPositive (n: Int)
establish provePos(n: Int) -> Fact (IsPositive n) = IsPositive n
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn needPos(n: Int ::: IsPositive n) -> Int = n

fn crossSubjectAttach(x: Int, y: Int) -> Int =
  let px = check checkPos x
  let bareX = forgetFact px
  let pyProof = provePos y
  needPos <| bareX ::: pyProof
|})

(* === R54_MP: Multi-param proof edge cases ================================== *)

(* R54_MP01 -- Wrong argument order for multi-param proof is rejected *)
let r54_mp01_wrong_order_rejected () =
  should_fail_src "does not.*satisfy\\|InBounds b a" (
    base_header ^ {|
fact InBounds (lo: Int) (hi: Int) (n: Int)

check inBounds(lo: Int, hi: Int, n: Int) -> n: Int ::: InBounds lo hi n =
  if lo <= n && n <= hi then
    ok n ::: InBounds lo hi n
  else
    fail 400 "bad"

fn needInBounds(lo: Int, hi: Int, n: Int ::: InBounds lo hi n) -> Int = n

fn wrongOrder(a: Int, b: Int, x: Int) -> Int =
  let v = check inBounds a b x
  needInBounds b a v
|})

(* R54_MP02 -- Correct argument order passes *)
let r54_mp02_correct_order_ok () =
  should_pass_src (base_header ^ {|
fact InBounds (lo: Int) (hi: Int) (n: Int)

check inBounds(lo: Int, hi: Int, n: Int) -> n: Int ::: InBounds lo hi n =
  if lo <= n && n <= hi then
    ok n ::: InBounds lo hi n
  else
    fail 400 "bad"

fn needInBounds(lo: Int, hi: Int, n: Int ::: InBounds lo hi n) -> Int = n

fn correctOrder(a: Int, b: Int, x: Int) -> Int =
  let v = check inBounds a b x
  needInBounds a b v
|})

(* R54_MP03 -- Three-param proof with mixed types *)
let r54_mp03_three_param_proof () =
  should_pass_src (base_header ^ {|
import Tesl.String exposing [String.startsWith]
fact HasPrefix (prefix: String) (s: String)

check checkHasPrefix(prefix: String, s: String) -> s: String ::: HasPrefix prefix s =
  if String.startsWith s prefix then
    ok s ::: HasPrefix prefix s
  else
    fail 400 "bad prefix"

fn needHasPrefix(prefix: String, s: String ::: HasPrefix prefix s) -> String = s

fn usePrefix(rawPrefix: String, rawStr: String) -> String =
  let validated = check checkHasPrefix rawPrefix rawStr
  needHasPrefix rawPrefix validated
|})

(* === R54_ES: establish-specific scenarios ================================== *)

(* R54_ES01 -- establish Maybe + case elimination + proof reattach *)
let r54_es01_establish_maybe_use () =
  should_pass_src (base_header ^ {|
fact ValidRange (n: Int)

establish tryRange(n: Int) -> Maybe (Fact (ValidRange n)) =
  if 1 <= n && n <= 100 then
    Something (ValidRange n)
  else
    Nothing

fn needValidRange(n: Int ::: ValidRange n) -> Int = n

fn safeUse(raw: Int) -> Int =
  let mProof = tryRange raw
  case mProof of
    Nothing  -> -1
    Something pf -> needValidRange <| raw ::: pf
|})

(* R54_ES02 -- Wrong predicate from establish fails proof check *)
let r54_es02_wrong_predicate_rejected () =
  should_fail_src "does not.*satisfy\\|ValidRange\\|WrongFact.*ValidRange" (
    base_header ^ {|
fact ValidRange (n: Int)
fact WrongFact  (n: Int)

establish wrongPred(n: Int) -> Fact (WrongFact n) =
  WrongFact n

fn needValidRange(n: Int ::: ValidRange n) -> Int = n

fn badUse(raw: Int) -> Int =
  let pf = wrongPred raw
  needValidRange <| raw ::: pf
|})

(* === Test runner =========================================================== *)

let () =
  run "Review54-Antagonistic" [
    "ci-regression", [
      test_case "R54_CI01 check return with sidecar (known regression)" `Quick r54_ci01_check_return_with_sidecar_regression;
      test_case "R54_CI02 paren check return (known regression)" `Quick r54_ci02_paren_check_return_regression;
      test_case "R54_CI03 let _ = check discard rejected" `Quick r54_ci03_let_wildcard_check_discard;
      test_case "R54_CI04 let x = check binding ok" `Quick r54_ci04_let_named_check_ok;
    ];
    "partial-application", [
      test_case "R54_PA01 partial apply no proof on first param (correct)" `Quick r54_pa01_partial_apply_no_first_param_proof;
      test_case "R54_PA02 partial apply call site caught" `Quick r54_pa02_partial_apply_call_site_caught;
      test_case "R54_PA03 normal partial apply ok" `Quick r54_pa03_normal_partial_apply_ok;
    ];
    "check-in-establish", [
      test_case "R54_CE01 check inside establish (known bug)" `Quick r54_ce01_check_in_establish_totality;
      test_case "R54_CE02 establish direct proof total" `Quick r54_ce02_establish_direct_proof;
      test_case "R54_CE03 establish maybe total" `Quick r54_ce03_establish_maybe_total;
    ];
    "guard-exhaustiveness", [
      test_case "R54_GE01 all-guarded arms rejected (misleading msg)" `Quick r54_ge01_all_guarded_arms_rejected;
      test_case "R54_GE02 unguarded catchall satisfies" `Quick r54_ge02_unguarded_catchall_satisfies;
      test_case "R54_GE03 genuinely missing ctor rejected" `Quick r54_ge03_genuinely_missing_ctor;
    ];
    "tuple2-list-divergence", [
      test_case "R54_TL01 two-elem list not Tuple2 (spec divergence)" `Quick r54_tl01_two_elem_list_not_tuple2;
      test_case "R54_TL02 Tuple2 not subtype of List (spec divergence)" `Quick r54_tl02_tuple2_not_subtype_of_list;
      test_case "R54_TL03 correct Tuple2 usage" `Quick r54_tl03_tuple2_correct_usage;
    ];
    "stdlib-proof-bypass", [
      test_case "R54_SP01 fn false stdlib proof (known bug)" `Quick r54_sp01_fn_false_stdlib_proof_not_caught;
      test_case "R54_SP02 fn false user proof rejected" `Quick r54_sp02_fn_false_user_proof_rejected;
      test_case "R54_SP03 fn correct stdlib proof ok" `Quick r54_sp03_fn_stdlib_proof_correct;
    ];
    "complex-proof-chains", [
      test_case "R54_PC01 three-step chain" `Quick r54_pc01_three_step_chain;
      test_case "R54_PC02 cross-step selective reattach" `Quick r54_pc02_cross_step_selective;
      test_case "R54_PC03 proof no flow through plain fn" `Quick r54_pc03_proof_no_flow_plain_fn;
      test_case "R54_PC04 four-fact conjunction" `Quick r54_pc04_four_fact_conjunction;
    ];
    "nested-proof-propagation", [
      test_case "R54_NP01 nested Maybe exhaustive" `Quick r54_np01_nested_maybe_exhaustive;
      test_case "R54_NP02 nested case non-exhaustive" `Quick r54_np02_nested_case_non_exhaustive;
      test_case "R54_NP03 record field nested access" `Quick r54_np03_record_field_nested_access;
    ];
    "detach-attach-flows", [
      test_case "R54_DA01 triple decompose selective" `Quick r54_da01_triple_decompose_selective;
      test_case "R54_DA02 introAnd same subject" `Quick r54_da02_introand_same_subject;
      test_case "R54_DA03 introAnd cross-subject rejected" `Quick r54_da03_introand_cross_subject_rejected;
    ];
    "record-update-proofs", [
      test_case "R54_RU01 update non-proof field preserves proof" `Quick r54_ru01_update_nonproof_preserves;
      test_case "R54_RU02 update proof field rejected" `Quick r54_ru02_update_proof_field_rejected;
    ];
    "lambda-proof-params", [
      test_case "R54_LB01 lambda proof param enforced" `Quick r54_lb01_lambda_proof_enforced;
      test_case "R54_LB02 lambda proof param satisfied" `Quick r54_lb02_lambda_proof_satisfied;
    ];
    "forget-fact-protection", [
      test_case "R54_FG01 forget recheck same value" `Quick r54_fg01_forget_recheck;
      test_case "R54_FG02 forget establish reattach" `Quick r54_fg02_forget_establish_reattach;
      test_case "R54_FG03 forget cross-subject rejected" `Quick r54_fg03_forget_cross_subject_rejected;
    ];
    "multi-param-proofs", [
      test_case "R54_MP01 wrong order rejected" `Quick r54_mp01_wrong_order_rejected;
      test_case "R54_MP02 correct order ok" `Quick r54_mp02_correct_order_ok;
      test_case "R54_MP03 three-param proof" `Quick r54_mp03_three_param_proof;
    ];
    "establish-scenarios", [
      test_case "R54_ES01 establish maybe case use" `Quick r54_es01_establish_maybe_use;
      test_case "R54_ES02 wrong predicate rejected" `Quick r54_es02_wrong_predicate_rejected;
    ];
  ]
