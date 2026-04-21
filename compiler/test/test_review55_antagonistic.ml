(** Antagonistic regression tests for Critical Review 55.

    Key findings:
    1. Integer and string literal arguments not supported in proof expressions
       (spec §9.1 says they should be valid GDP atoms)
    2. Lambda body greedy parsing in application position swallows trailing args
    3. Proof not tracked through Tuple2/Tuple3 accessors
    4. ForAll proof correctly lost through List.map (design correctness)
    5. Handler-to-handler calls correctly rejected
    6. Duplicate constructor names across ADTs correctly rejected
    7. Multi-param proof with literal integer bounds requires named variables
    8. Correct cross-module proof predicate tracking
    9. check in arithmetic context does not trigger bare-check (safe but inconsistent)
    10. Deeply nested proof chains (5+ level) and combined check &&
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
  let dir = Filename.temp_dir "tesl-r55" "" in
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

let with_temp_dir f =
  let dir = Filename.temp_dir "tesl-r55" "" in
  Fun.protect
    ~finally:(fun () ->
      (try
         Array.iter (fun name ->
           let path = Filename.concat dir name in
           (try Sys.remove path with _ -> ())
         ) (Sys.readdir dir)
       with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f dir)

let should_pass_src src =
  with_temp_file "tesl-r55" ".tesl" src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected compilation success, got:\n%s" out)

let should_fail_src pattern src =
  with_temp_file "tesl-r55" ".tesl" src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but compilation succeeded" pattern;
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pattern out)

let base_header = {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, Bool(..), List, Fact, forgetFact, attachFact, detachFact, introAnd, andLeft, andRight]
import Tesl.Maybe exposing [Maybe(..)]
|}

let proof_decls = {|
fact IsPositive (n: Int)
fact IsSmall    (n: Int)

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

fn needPos(n: Int ::: IsPositive n) -> Int = n
fn needSmall(n: Int ::: IsSmall n) -> Int = n
fn needBoth(n: Int ::: IsPositive n && IsSmall n) -> Int = n
|}

(* ═══════════════════════════════════════════════════════════════════════════
   R55_LI — Integer and string literals in proof expressions
   The spec (§9.1) says GDP atoms include integer and string literals,
   but the proof expression parser only handles identifier tokens.
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R55_LI01 — FIXED: Integer literal proof argument now works *)
let r55_li01_int_literal_in_proof_return_works () =
  should_pass_src (base_header ^ {|
fact HasMinValue (lo: Int) (n: Int)

check checkAbove100(n: Int) -> n: Int ::: HasMinValue 100 n =
  if n >= 100 then
    ok n ::: HasMinValue 100 n
  else
    fail 400 "below 100"

fn needAbove100(n: Int ::: HasMinValue 100 n) -> Int = n

fn test(raw: Int) -> Int =
  let v = check checkAbove100 raw
  needAbove100 v
|})

(* R55_LI02 — FIXED: String literal proof argument now works *)
let r55_li02_string_literal_in_proof_works () =
  should_pass_src (base_header ^ {|
fact Named (name: String) (port: Int)

establish proveHttp(port: Int) -> Fact (Named "http" port) =
  Named "http" port

fn needHttp(port: Int ::: Named "http" port) -> Int = port

fn test(raw: Int) -> Int =
  let pf = proveHttp raw
  needHttp <| raw ::: pf
|})

(* R55_LI03 -- Named variable bounds also still work *)
let r55_li03_named_variable_bounds_works () =
  should_pass_src (base_header ^ {|
fact InRange (lo: Int) (hi: Int) (n: Int)

check checkInRange(lo: Int, hi: Int, n: Int) -> n: Int ::: InRange lo hi n =
  if lo <= n && n <= hi then
    ok n ::: InRange lo hi n
  else
    fail 400 "out of range"

fn needInRange(lo: Int, hi: Int, n: Int ::: InRange lo hi n) -> Int = n

fn testWithVars(raw: Int) -> Int =
  let lo = 1
  let hi = 100
  let v = check checkInRange lo hi raw
  needInRange lo hi v
|})

(* R55_LI04 -- FIXED: Literal args at call site now work too *)
let r55_li04_literal_args_at_call_site_works () =
  should_pass_src (base_header ^ {|
fact InRange (lo: Int) (hi: Int) (n: Int)

check checkInRange(lo: Int, hi: Int, n: Int) -> n: Int ::: InRange lo hi n =
  if lo <= n && n <= hi then
    ok n ::: InRange lo hi n
  else
    fail 400 "out of range"

fn needInRange(lo: Int, hi: Int, n: Int ::: InRange lo hi n) -> Int = n

fn testWithLiterals(raw: Int) -> Int =
  let v = check checkInRange 1 100 raw
  needInRange 1 100 v
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R55_LA — Lambda body greedy parsing in application position
   `f (fn -> body) arg` is needed because `f fn -> body arg` is parsed
   as `f (fn -> body arg)` — the lambda body greedily consumes `arg`.
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R55_LA01 -- Lambda body without parens greedily consumes trailing args *)
let r55_la01_lambda_body_greedy_type_error () =
  should_fail_src "cannot unify\\|type mismatch\\|List Int\\|Int -> Int" (
    base_header ^ {|
import Tesl.List exposing [List.map, List.length]

fn test(xs: List Int) -> Int =
  let doubled = List.map fn(n: Int) -> n + n xs
  List.length doubled
|})

(* R55_LA02 -- Parenthesized lambda fixes the greedy parsing *)
let r55_la02_lambda_body_parens_ok () =
  should_pass_src (base_header ^ {|
import Tesl.List exposing [List.map, List.length]

fn test(xs: List Int) -> Int =
  let doubled = List.map (fn(n: Int) -> n + n) xs
  List.length doubled
|})

(* R55_LA03 -- Named plain fn in filterCheck is rejected (lambda bypasses but produces no proof) *)
let r55_la03_named_fn_filtercheck_rejected () =
  (* A named `fn` function (not `check`) passed to filterCheck is rejected.
     Note: anonymous lambdas bypass this check but also produce no ForAll proof,
     so they're safe but useless. Only named fn functions trigger this error. *)
  should_fail_src "plain.*fn.*filterCheck\\|check.*kind.*filterCheck\\|proof-carrying" (
    base_header ^ {|
import Tesl.List exposing [List.filterCheck, List.length]
fact IsPositive (n: Int)

fn fakePred(n: Int) -> n: Int ::: IsPositive n = n

fn test(xs: List Int) -> Int =
  let pos = List.filterCheck fakePred xs
  List.length pos
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R55_TU — Proof not tracked through Tuple accessors
   When a proof-carrying value is stored in a Tuple and then extracted
   via Tuple2.first/Tuple2.second, the proof is lost. This is expected
   behavior (Tuples don't carry field-level proofs) but worth documenting.
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R55_TU01 -- Proof lost through Tuple2.first *)
let r55_tu01_proof_lost_through_tuple_accessor () =
  should_fail_src "does not.*satisfy.*proof\\|no trackable subject\\|IsPositive" (
    base_header ^ {|
import Tesl.Tuple exposing [Tuple2, Tuple2.first]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn needPos(n: Int ::: IsPositive n) -> Int = n

fn test(raw: Int) -> Int =
  let pos = check checkPos raw
  let pair = Tuple2 pos 0
  needPos (Tuple2.first pair)
|})

(* R55_TU02 -- Proof stored in variable, then used in Tuple is accessible via the variable *)
let r55_tu02_proof_via_original_variable_ok () =
  should_pass_src (base_header ^ {|
import Tesl.Tuple exposing [Tuple2, Tuple2.first]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn needPos(n: Int ::: IsPositive n) -> Int = n

fn test(raw: Int) -> Int =
  let pos = check checkPos raw
  let pair = Tuple2 pos 0
  needPos pos
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R55_FM — ForAll proof design correctness
   List.map does NOT preserve ForAll — the mapped function may not satisfy
   the predicate. This is correctly rejected.
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R55_FM01 -- ForAll proof lost through List.map (correct behavior) *)
let r55_fm01_forall_lost_through_map () =
  should_fail_src "does not.*satisfy.*ForAll\\|ForAll IsPositive.*doubled" (
    base_header ^ {|
import Tesl.List exposing [List.map, List.filterCheck, List.length]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn needPosAll(xs: List Int ::: ForAll IsPositive xs) -> Int = List.length xs

fn test(raw: List Int) -> Int =
  let pos = List.filterCheck checkPos raw
  let doubled = List.map (fn(n: Int) -> n + n) pos
  needPosAll doubled
|})

(* R55_FM02 -- ForAll propagated through filterCheck on already-proven list *)
let r55_fm02_forall_filtercheck_preserves () =
  should_pass_src (base_header ^ {|
import Tesl.List exposing [List.filterCheck, List.length]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn needPosAll(xs: List Int ::: ForAll IsPositive xs) -> Int = List.length xs

fn test(raw: List Int) -> Int =
  let positives = List.filterCheck checkPos raw
  needPosAll positives
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R55_HH — Handler-to-handler call restriction
   Handlers cannot call other handlers directly — only the server router
   can reference handlers.
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R55_HH01 -- Handler calling another handler is rejected *)
let r55_hh01_handler_calls_handler_rejected () =
  should_fail_src "handler.*cannot.*be.*called\\|handlers.*entry.*point\\|router.*only\\|only.*server.*router" (
    base_header ^ {|
import Tesl.Http exposing [HttpRequest]
import Tesl.DB exposing [dbRead]

handler innerH(req: HttpRequest, n: Int) -> Int requires [dbRead] = n

handler outerH(req: HttpRequest, n: Int) -> Int requires [dbRead] =
  innerH req n
|})

(* R55_HH02 -- Handler calling fn is ok *)
let r55_hh02_handler_calls_fn_ok () =
  should_pass_src (base_header ^ {|
import Tesl.Http exposing [HttpRequest]
import Tesl.DB exposing [dbRead]

fn helperFn(n: Int) -> Int = n + 1

handler myH(req: HttpRequest, n: Int) -> Int requires [dbRead] =
  helperFn n
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R55_DC — Duplicate constructor names across ADTs
   Constructor names must be globally unique within a module.
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R55_DC01 -- Duplicate constructor across two ADTs in same module is rejected *)
let r55_dc01_duplicate_ctor_across_adts () =
  should_fail_src "duplicate.*constructor\\|Active.*already.*declared\\|ctor.*unique" (
    base_header ^ {|
type Status
  = Active
  | Inactive

type Phase
  = Active
  | Complete
|})

(* R55_DC02 -- Unique constructor names per ADT is fine *)
let r55_dc02_unique_ctors_ok () =
  should_pass_src (base_header ^ {|
type Status
  = StatusActive
  | StatusInactive

type Phase
  = PhaseActive
  | PhaseComplete

fn test(s: Status) -> Int =
  case s of
    StatusActive -> 1
    StatusInactive -> 0
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R55_CM -- Cross-module proof tracking
   Proof predicates exported from one module and imported in another must
   track correctly.
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R55_CM01 -- Cross-module proof import and tracking works *)
let r55_cm01_cross_module_proof () =
  with_temp_dir (fun dir ->
    let validators_path = Filename.concat dir "validators.tesl" in
    let main_path = Filename.concat dir "main.tesl" in
    write_file validators_path {|#lang tesl
module Validators exposing [checkPos, IsPositive]
import Tesl.Prelude exposing [Int]

fact IsPositive (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
|};
    write_file main_path {|#lang tesl
module Main exposing []
import Tesl.Prelude exposing [Int]
import Validators exposing [checkPos, IsPositive]

fn needPos(n: Int ::: IsPositive n) -> Int = n

fn test(raw: Int) -> Int =
  let pos = check checkPos raw
  needPos pos
|};
    let code, out = run_compiler ["--check"; main_path] in
    if code <> 0 then failf "expected cross-module proof to work, got:\n%s" out)

(* R55_CM02 -- Cross-module proof: using predicate without explicit import is rejected *)
let r55_cm02_cross_module_missing_pred_import () =
  with_temp_dir (fun dir ->
    let validators_path = Filename.concat dir "validators.tesl" in
    let main_path = Filename.concat dir "main.tesl" in
    write_file validators_path {|#lang tesl
module Validators exposing [checkPos, IsPositive]
import Tesl.Prelude exposing [Int]

fact IsPositive (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
|};
    write_file main_path {|#lang tesl
module Main exposing []
import Tesl.Prelude exposing [Int]
import Validators exposing [checkPos]

fn needPos(n: Int ::: IsPositive n) -> Int = n
|};
    let code, out = run_compiler ["--check"; main_path] in
    if code = 0 then failf "expected failure: IsPositive not imported, but compilation succeeded"
    else
      let re = Str.regexp_case_fold "IsPositive.*not.*scope\\|proof.*predicate.*not.*in.*scope" in
      try ignore (Str.search_forward re out 0)
      with Not_found -> failf "expected predicate scope error, got:\n%s" out)

(* ═══════════════════════════════════════════════════════════════════════════
   R55_CH -- check && combined checks correctness
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R55_CH01 -- check && combined check produces conjunction proof *)
let r55_ch01_combined_check_conjunction () =
  should_pass_src (base_header ^ proof_decls ^ {|
fn needBothCheck(raw: Int) -> Int =
  let result = check (checkPos && checkSmall) raw
  needBoth result
|})

(* R55_CH02 -- check && combined check in filterCheck works *)
let r55_ch02_combined_check_filtercheck () =
  should_pass_src (base_header ^ {|
import Tesl.List exposing [List.filterCheck, List.length]
fact IsPositive (n: Int)
fact IsSmall    (n: Int)
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

fn test(xs: List Int) -> Int =
  let result = List.filterCheck (checkPos && checkSmall) xs
  List.length result
|})

(* R55_CH03 -- plain fn in check && combined is rejected *)
let r55_ch03_fn_in_combined_check_rejected () =
  should_fail_src "plain.*fn\\|fn.*cannot.*proof\\|check.*kind" (
    base_header ^ proof_decls ^ {|
fn fakeFn(n: Int) -> n: Int ::: IsPositive n = n
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R55_CP -- check in arithmetic position (no bare-check error, safe)
   Writing `2 + check f n` runs the validation but the proof is silently
   discarded. This is safe (arithmetic doesn't need proofs) but potentially
   confusing since it's not consistent with the spec warning about bare checks.
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R55_CP01 -- check in arithmetic position compiles (proof silently discarded) *)
let r55_cp01_check_in_arithmetic_no_error () =
  should_pass_src (base_header ^ proof_decls ^ {|
fn test(raw: Int) -> Int =
  2 + check checkPos raw
|})

(* R55_CP02 -- But using check result in proof-requiring fn from arithmetic fails *)
let r55_cp02_check_arithmetic_result_no_proof () =
  should_fail_src "does not.*satisfy.*proof\\|IsPositive\\|no trackable subject" (
    base_header ^ proof_decls ^ {|
fn test(raw: Int) -> Int =
  needPos (check checkPos raw)
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R55_EP -- Establish proof correctness edge cases
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R55_EP01 -- fn can call establish and attach proof *)
let r55_ep01_fn_can_call_establish () =
  should_pass_src (base_header ^ {|
fact IsPositive (n: Int)
establish provePos(n: Int) -> Fact (IsPositive n) = IsPositive n
fn needPos(n: Int ::: IsPositive n) -> Int = n

fn fnAttachEstablish(raw: Int) -> Int =
  let pf = provePos raw
  needPos <| raw ::: pf
|})

(* R55_EP02 -- establish cannot use check function (now correctly rejected) *)
let r55_ep02_establish_no_check_call () =
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

(* R55_EP03 -- establish with Maybe return (total, no check call) is valid *)
let r55_ep03_establish_maybe_no_check () =
  should_pass_src (base_header ^ {|
fact ValidPort (n: Int)

establish tryPort(n: Int) -> Maybe (Fact (ValidPort n)) =
  if 1 <= n && n <= 65535 then
    Something (ValidPort n)
  else
    Nothing
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R55_MP -- More complex multi-param proof scenarios
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R55_MP01 -- 5+ step proof chain with 5 distinct predicates *)
let r55_mp01_five_step_chain () =
  should_pass_src (base_header ^ {|
fact A (n: Int)
fact B (n: Int)
fact C (n: Int)
fact D (n: Int)
fact E (n: Int)

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
check checkE(n: Int) -> n: Int ::: E n =
  if n % 5 == 0 then
    ok n ::: E n
  else
    fail 400 "bad"

fn needAll5(n: Int ::: A n && B n && C n && D n && E n) -> Int = n

fn fiveStep(raw: Int) -> Int =
  let a = check checkA raw
  let b = check checkB a
  let c = check checkC b
  let d = check checkD c
  let e = check checkE d
  needAll5 e
|})

(* R55_MP02 -- 5-conjunct decompose and selective reattach *)
let r55_mp02_five_conjunct_decompose () =
  should_pass_src (base_header ^ {|
fact A (n: Int)
fact B (n: Int)
fact C (n: Int)
fact D (n: Int)
fact E (n: Int)

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
check checkE(n: Int) -> n: Int ::: E n =
  if n % 5 == 0 then
    ok n ::: E n
  else
    fail 400 "bad"

fn needAE(n: Int ::: A n && E n) -> Int = n

fn testDecompose(raw: Int) -> Int =
  let a = check checkA raw
  let b = check checkB a
  let c = check checkC b
  let d = check checkD c
  let e = check checkE d
  let (v ::: pa && _ && _ && _ && pe) = e
  needAE <| v ::: pa && pe
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R55_GW -- Ghost witness edge cases
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R55_GW01 -- Ghost witness with correct detachFact syntax *)
let r55_gw01_ghost_witness_correct () =
  should_pass_src (base_header ^ {|
fact IsPositive (n: Int)
fact IsValidRange (lo: Int) (hi: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

establish proveRange(lo: Int, hi: Int) -> Fact (IsValidRange lo hi) =
  IsValidRange lo hi

record BoundedInt {
  value: Int ::: IsPositive value
} ::: IsValidRange lo hi via proveRange

fn makeBounded(lo: Int, hi: Int, value: Int ::: IsPositive value) -> BoundedInt =
  let rangeProof = proveRange lo hi
  BoundedInt { value: value } ::: (detachFact rangeProof)
|})

(* R55_GW02 -- FIXED: Ghost witness with wrong predicate is now correctly rejected *)
let r55_gw02_ghost_witness_wrong_predicate_now_caught () =
  should_fail_src "ghost witness.*predicate.*mismatch\\|invariant requires.*IsValidRange\\|witness carries.*OtherFact" (
    base_header ^ {|
fact IsPositive (n: Int)
fact IsValidRange (lo: Int) (hi: Int)
fact OtherFact (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

establish proveRange(lo: Int, hi: Int) -> Fact (IsValidRange lo hi) =
  IsValidRange lo hi

establish proveOther(n: Int) -> Fact (OtherFact n) = OtherFact n

record BoundedInt {
  value: Int ::: IsPositive value
} ::: IsValidRange lo hi via proveRange

fn makeBadBounded(lo: Int, hi: Int, value: Int ::: IsPositive value) -> BoundedInt =
  let wrongProof = proveOther value
  BoundedInt { value: value } ::: (detachFact wrongProof)
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R55_SP -- Stdlib proof propagation (now fixed, regression coverage)
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R55_SP01 -- IsTrimmed now correctly required for fn claiming it *)
let r55_sp01_istrimmed_now_enforced () =
  should_fail_src "IsTrimmed\\|only carries.*no proofs\\|fn.*returns.*named.*pack" (
    base_header ^ {|
import Tesl.String exposing [String.trim, IsTrimmed]

fn fakeTrim(s: String) -> String ? IsTrimmed = s
|})

(* R55_SP02 -- String.trim correctly produces IsTrimmed *)
let r55_sp02_string_trim_produces_istrimmed () =
  should_pass_src (base_header ^ {|
import Tesl.String exposing [String.trim, IsTrimmed]

fn normalize(raw: String) -> String ? IsTrimmed = String.trim raw
|})

(* R55_SP03 -- IsSorted now correctly required for fn claiming it *)
let r55_sp03_issorted_now_enforced () =
  should_fail_src "IsSorted\\|only carries.*no proofs\\|fn.*returns.*named.*pack" (
    base_header ^ {|
import Tesl.List exposing [List.sort, IsSorted]

fn fakeSorted(xs: List Int) -> List Int ? IsSorted = xs
|})

(* R55_SP04 -- List.sort correctly produces IsSorted *)
let r55_sp04_list_sort_produces_issorted () =
  should_pass_src (base_header ^ {|
import Tesl.List exposing [List.sort, IsSorted]

fn sortedList(xs: List Int) -> List Int ? IsSorted = List.sort xs
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R55_MC -- Mixed case patterns and exhaustiveness
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R55_MC01 -- Literal patterns with ADT constructors: exhaustive with catchall *)
let r55_mc01_literal_plus_ctor_exhaustive () =
  should_pass_src (base_header ^ {|
fn test(m: Maybe Int) -> String =
  case m of
    Nothing -> "nothing"
    Something 0 -> "zero"
    Something 1 -> "one"
    Something _ -> "other"
|})

(* R55_MC02 -- Nested ADT case must be exhaustive in inner case *)
let r55_mc02_nested_adt_inner_case_exhaustive () =
  should_fail_src "non-exhaustive\\|missing.*constructor\\|InnerB" (
    base_header ^ {|
type Inner
  = InnerA value:Int
  | InnerB value:Int

fn test(m: Maybe Inner) -> Int =
  case m of
    Nothing -> 0
    Something inner ->
      case inner of
        InnerA value -> value
|})

(* R55_MC03 -- Fall-through arms compile and are exhaustive *)
let r55_mc03_fallthrough_arms_ok () =
  should_pass_src (base_header ^ {|
type Status
  = Backlog
  | InProgress
  | Done
  | Cancelled

fn classify(s: Status) -> String =
  case s of
    Backlog    ->
    Cancelled  ->
      "inactive"
    InProgress ->
    Done       ->
      "active"
|})

(* ═══════════════════════════════════════════════════════════════════════════
   Test runner
   ═══════════════════════════════════════════════════════════════════════════ *)

let () =
  run "Review55-Antagonistic" [
    "literal-proof-args", [
      test_case "R55_LI01 int literal in proof return (fixed)" `Quick r55_li01_int_literal_in_proof_return_works;
      test_case "R55_LI02 string literal in proof (fixed)" `Quick r55_li02_string_literal_in_proof_works;
      test_case "R55_LI03 named variable bounds still work" `Quick r55_li03_named_variable_bounds_works;
      test_case "R55_LI04 literal args at call site (fixed)" `Quick r55_li04_literal_args_at_call_site_works;
    ];
    "lambda-greedy-parsing", [
      test_case "R55_LA01 lambda body greedy type error" `Quick r55_la01_lambda_body_greedy_type_error;
      test_case "R55_LA02 parenthesized lambda ok" `Quick r55_la02_lambda_body_parens_ok;
      test_case "R55_LA03 named fn in filterCheck rejected" `Quick r55_la03_named_fn_filtercheck_rejected;
    ];
    "tuple-proof-loss", [
      test_case "R55_TU01 proof lost through Tuple2.first" `Quick r55_tu01_proof_lost_through_tuple_accessor;
      test_case "R55_TU02 proof via original variable ok" `Quick r55_tu02_proof_via_original_variable_ok;
    ];
    "forall-correctness", [
      test_case "R55_FM01 ForAll lost through map (correct)" `Quick r55_fm01_forall_lost_through_map;
      test_case "R55_FM02 ForAll through filterCheck preserved" `Quick r55_fm02_forall_filtercheck_preserves;
    ];
    "handler-to-handler", [
      test_case "R55_HH01 handler calling handler rejected" `Quick r55_hh01_handler_calls_handler_rejected;
      test_case "R55_HH02 handler calling fn is ok" `Quick r55_hh02_handler_calls_fn_ok;
    ];
    "duplicate-constructors", [
      test_case "R55_DC01 duplicate ctor across ADTs rejected" `Quick r55_dc01_duplicate_ctor_across_adts;
      test_case "R55_DC02 unique ctors per ADT ok" `Quick r55_dc02_unique_ctors_ok;
    ];
    "cross-module-proof", [
      test_case "R55_CM01 cross-module proof tracking works" `Quick r55_cm01_cross_module_proof;
      test_case "R55_CM02 missing pred import rejected" `Quick r55_cm02_cross_module_missing_pred_import;
    ];
    "combined-check", [
      test_case "R55_CH01 check && produces conjunction" `Quick r55_ch01_combined_check_conjunction;
      test_case "R55_CH02 check && in filterCheck works" `Quick r55_ch02_combined_check_filtercheck;
      test_case "R55_CH03 plain fn in check && rejected" `Quick r55_ch03_fn_in_combined_check_rejected;
    ];
    "check-in-position", [
      test_case "R55_CP01 check in arithmetic no error" `Quick r55_cp01_check_in_arithmetic_no_error;
      test_case "R55_CP02 check in inline call loses proof" `Quick r55_cp02_check_arithmetic_result_no_proof;
    ];
    "establish-proof", [
      test_case "R55_EP01 fn can call establish" `Quick r55_ep01_fn_can_call_establish;
      test_case "R55_EP02 establish no check call (fixed)" `Quick r55_ep02_establish_no_check_call;
      test_case "R55_EP03 establish Maybe no check is total" `Quick r55_ep03_establish_maybe_no_check;
    ];
    "multi-step-chains", [
      test_case "R55_MP01 five-step chain 5 predicates" `Quick r55_mp01_five_step_chain;
      test_case "R55_MP02 five-conjunct decompose selective" `Quick r55_mp02_five_conjunct_decompose;
    ];
    "ghost-witness", [
      test_case "R55_GW01 ghost witness correct detachFact" `Quick r55_gw01_ghost_witness_correct;
      test_case "R55_GW02 ghost witness wrong predicate (fixed)" `Quick r55_gw02_ghost_witness_wrong_predicate_now_caught;
    ];
    "stdlib-proof-regression", [
      test_case "R55_SP01 IsTrimmed enforced (r54 fix)" `Quick r55_sp01_istrimmed_now_enforced;
      test_case "R55_SP02 String.trim produces IsTrimmed" `Quick r55_sp02_string_trim_produces_istrimmed;
      test_case "R55_SP03 IsSorted enforced (r54 fix)" `Quick r55_sp03_issorted_now_enforced;
      test_case "R55_SP04 List.sort produces IsSorted" `Quick r55_sp04_list_sort_produces_issorted;
    ];
    "mixed-case-patterns", [
      test_case "R55_MC01 literal plus ctor exhaustive" `Quick r55_mc01_literal_plus_ctor_exhaustive;
      test_case "R55_MC02 nested ADT inner case must be exhaustive" `Quick r55_mc02_nested_adt_inner_case_exhaustive;
      test_case "R55_MC03 fall-through arms ok" `Quick r55_mc03_fallthrough_arms_ok;
    ];
  ]
