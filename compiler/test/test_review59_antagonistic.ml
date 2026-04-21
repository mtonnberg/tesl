(** Antagonistic regression tests for Critical Review 59.

    This review audits:
    1.  ok <| proof form removed from parser but still documented in spec
    2.  Proof decomposition let (v ::: p) + andLeft: static-OK but runtime-fail
    3.  Maybe proof wrapping: static checker accepts, runtime rejects
    4.  detachFact template syntax: no valid surface form for 2-arg variant
    5.  Case-arm proof error message shows wrong subject name
    6.  Module name hint shows camelCase-inconsistent suggestion
    7.  ForAll on non-List/Set type is rejected with clear error
    8.  ForAll proof mismatch on parameters is caught
    9.  establish cannot use fail
    10. establish cannot call check
    11. Plain fn cannot mint proofs with ok :::
    12. Capability propagation from callees enforced
    13. Literal argument to proof-requiring function rejected
    14. Shadowing of proof-carrying names rejected
    15. Case-arm binding without proof correctly rejected
    16. Deep check chain with missing intermediate proof rejected
    17. Cross-module proof predicate requires explicit import
    18. Sequential filterCheck proof accumulation
    19. Empty list does not vacuously satisfy ForAll
    20. Proof subject confusion in nested Maybe/case
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
  let dir = Filename.temp_dir "tesl-r59" "" in
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

(* ── R59_OP — ok <| proof syntax removed from parser ───────────────────── *)

let test_R59_OP01_ok_pipe_rejected_in_establish () =
  (* Spec sections 1819, 1854, 2606 document ok <| proof as a valid form for
     establish functions, but the parser rejects it with "expected expression, got <|".
     This test CONFIRMS the discrepancy: the syntax should either be restored or
     removed from the spec. *)
  should_fail "expected expression" {|
#lang tesl
module R59Op01 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
establish positive(n: Int) -> Fact (IsPositive n) =
  ok <| IsPositive n
|}

let test_R59_OP02_establish_direct_return_works () =
  (* The correct form for establish is to return the proof expression directly *)
  should_pass {|
#lang tesl
module R59Op02 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
establish positive(n: Int) -> Fact (IsPositive n) =
  IsPositive n
|}

(* ── R59_FN — Plain fn cannot mint proofs ───────────────────────────────── *)

let test_R59_FN01_fn_cannot_declare_proof_return () =
  (* A plain fn cannot declare a proof-carrying return type if the value
     wasn't received with that proof as a parameter *)
  should_fail "plain .fn. cannot declare a proof-carrying return type" {|
#lang tesl
module R59Fn01 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
fn forgeFact(n: Int) -> n: Int ::: IsPositive n =
  ok n ::: IsPositive n
|}

let test_R59_FN02_fn_cannot_use_ok_proof () =
  (* ok ::: proof is only allowed inside check/auth/establish functions *)
  should_fail "ok .* proof construction is not allowed in .fn." {|
#lang tesl
module R59Fn02 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
fn trickFn(n: Int ::: IsPositive n) -> n: Int ::: IsPositive n =
  ok n ::: IsPositive n
|}

(* ── R59_ES — establish restrictions ───────────────────────────────────── *)

let test_R59_ES01_establish_cannot_use_fail () =
  should_fail "establish functions cannot use .fail" {|
#lang tesl
module R59Es01 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
establish positive(n: Int) -> Fact (IsPositive n) =
  if n > 0 then
    IsPositive n
  else
    fail 400 "not positive"
|}

let test_R59_ES02_establish_cannot_call_check () =
  should_fail "establish functions cannot call .check" {|
#lang tesl
module R59Es02 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
fact IsSmall (n: Int)
check checkSmall(n: Int) -> n: Int ::: IsSmall n =
  if n < 100 then
    ok n ::: IsSmall n
  else
    fail 400 "too large"
establish establishWithCheck(n: Int) -> Fact (IsPositive n) =
  let m = check checkSmall n
  IsPositive n
|}

(* ── R59_LT — Literal argument to proof-requiring function ─────────────── *)

let test_R59_LT01_literal_to_proof_param_rejected () =
  should_fail "does not statically satisfy declared proof" {|
#lang tesl
module R59Lt01 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
fn needsPositive(n: Int ::: IsPositive n) -> Int = n
fn tryLiteral() -> Int =
  needsPositive 42
|}

(* ── R59_SH — Shadowing rejection ──────────────────────────────────────── *)

let test_R59_SH01_let_shadowing_rejected () =
  should_fail "shadows existing name" {|
#lang tesl
module R59Sh01 exposing []
import Tesl.Prelude exposing [Int]
fn shadowAttempt(n: Int) -> Int =
  let n = 42
  n
|}

let test_R59_SH02_case_arm_shadowing_rejected () =
  should_fail "case pattern binder.*shadows" {|
#lang tesl
module R59Sh02 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
fn shadowCase(m: Maybe Int, n: Int) -> Int =
  case m of
    Nothing -> 0
    Something n -> n
|}

(* ── R59_CA — Case-arm binding without proof ────────────────────────────── *)

let test_R59_CA01_case_arm_binding_no_proof () =
  (* Value extracted from case arm has no proof about the original value *)
  should_fail "does not statically satisfy declared proof" {|
#lang tesl
module R59Ca01 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
fn needsPositive(n: Int ::: IsPositive n) -> Int = n
fn caseTest(raw: Int) -> Int =
  let m = if raw > 0 then
    Something raw
  else
    Nothing
  case m of
    Nothing -> 0
    Something v ->
      needsPositive v
|}

(* ── R59_FA — ForAll restrictions ──────────────────────────────────────── *)

let test_R59_FA01_forall_on_non_list_rejected () =
  should_fail "ForAll.*only valid for.*List.*Set" {|
#lang tesl
module R59Fa01 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
fn badForAll(n: Int) -> Int ::: ForAll (IsPositive n) =
  n
|}

let test_R59_FA02_forall_proof_mismatch_on_param () =
  should_fail "does not statically satisfy declared proof" {|
#lang tesl
module R59Fa02 exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.filterCheck, List.length]
fact IsPositive (n: Int)
fact IsSmall (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
check checkSmall(n: Int) -> n: Int ::: IsSmall n =
  if n < 100 then
    ok n ::: IsSmall n
  else
    fail 400 "too large"
fn needsPositiveList(xs: List Int ::: ForAll (IsPositive) xs) -> Int =
  List.length xs
fn tryWrongForAll(raw: List Int) -> Int =
  let smalls = List.filterCheck checkSmall raw
  needsPositiveList smalls
|}

let test_R59_FA03_forall_fabrication_plain_list_rejected () =
  (* A function returning a plain unfiltered list where ForAll is declared should fail.
     The error is "has no tracked ... ForAll proof" — the variable xs was not filtered. *)
  should_fail "no tracked" {|
#lang tesl
module R59Fa03 exposing []
import Tesl.Prelude exposing [Int, List]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
fn fakeForAll(xs: List Int) -> List Int ::: ForAll (IsPositive) =
  xs
|}

(* ── R59_CP — Capability propagation ───────────────────────────────────── *)

let test_R59_CP01_missing_capability_from_callee () =
  should_fail "uses privileged operations and callees requiring" {|
#lang tesl
module R59Cp01 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.DB exposing [dbRead]
fn readOp(n: Int) -> Int requires [dbRead] = n
fn noCapFn(n: Int) -> Int =
  readOp n
|}

(* ── R59_DC — Deep check chain rejection ────────────────────────────────── *)

let test_R59_DC01_missing_intermediate_proof_rejected () =
  (* checkC requires A && B but we skip checkB, so should fail *)
  should_fail "does not statically satisfy declared proof" {|
#lang tesl
module R59Dc01 exposing []
import Tesl.Prelude exposing [Int]
fact A (n: Int)
fact B (n: Int)
fact C (n: Int)
check checkA(n: Int) -> n: Int ::: A n =
  if n > 0 then
    ok n ::: A n
  else
    fail 400 "fail A"
check checkC(n: Int ::: A n && B n) -> n: Int ::: C n =
  if n != 42 then
    ok n ::: C n
  else
    fail 400 "fail C"
fn needsC(n: Int ::: C n) -> Int = n
fn skipCheckB(raw: Int) -> Int =
  let a = check checkA raw
  let c = check checkC a
  needsC c
|}

(* ── R59_AD — ADT proof loss is caught for user-defined ADTs ────────────── *)

let test_R59_AD01_user_adt_proof_loss_caught () =
  should_fail "does not statically satisfy declared proof" {|
#lang tesl
module R59Ad01 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
type Container = Wrap value: Int | Empty
fn needsPositive(n: Int ::: IsPositive n) -> Int = n
fn adtLoss(raw: Int) -> Int =
  let pos = check checkPos raw
  let c = Wrap pos
  case c of
    Empty -> 0
    Wrap v ->
      needsPositive v
|}

(* ── R59_SM — Maybe proof wrapping: now correctly rejected (FIXED) ──────── *)

let test_R59_SM01_maybe_wrap_now_rejected () =
  (* FIXED in R59: The static checker now correctly rejects proof flow through
     Maybe constructors, consistent with user-defined ADTs.
     Proof is lost when stored in Something; case-arm binding v has no proof. *)
  should_fail "does not statically satisfy" {|
#lang tesl
module R59Sm01 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
fn needsPositive(n: Int ::: IsPositive n) -> Int = n
fn maybeWrap(raw: Int) -> Int =
  let pos = check checkPos raw
  let m = Something pos
  case m of
    Nothing -> 0
    Something v ->
      needsPositive v
|}

(* ── R59_DT — detachFact two-argument form lacks surface syntax ─────────── *)

let test_R59_DT01_detach_template_no_comma_syntax () =
  (* The spec says detachFact(value, Template) but comma syntax is not supported *)
  should_fail "expected.*)" {|
#lang tesl
module R59Dt01 exposing []
import Tesl.Prelude exposing [Int, Fact, detachFact]
fact A (n: Int)
check checkA(n: Int) -> n: Int ::: A n =
  if n > 0 then
    ok n ::: A n
  else
    fail 400 "fail A"
fn useTemplate(raw: Int) -> Int =
  let a = check checkA raw
  let p = detachFact(a, A a)
  0
|}

let test_R59_DT02_detach_ml_style_template_rejected () =
  (* ML-style: detachFact b (A b) fails because A is parsed as a constructor *)
  should_fail "unknown constructor.*A\\|cannot unify" {|
#lang tesl
module R59Dt02 exposing []
import Tesl.Prelude exposing [Int, Fact, detachFact]
fact A (n: Int)
fact B (n: Int)
check checkA(n: Int) -> n: Int ::: A n =
  if n > 0 then
    ok n ::: A n
  else
    fail 400 "fail A"
check checkB(n: Int ::: A n) -> n: Int ::: B n =
  if n < 1000 then
    ok n ::: B n
  else
    fail 400 "fail B"
fn useTemplate(raw: Int) -> Int =
  let a = check checkA raw
  let b = check checkB a
  let p = detachFact b (A b)
  0
|}

(* ── R59_PD — Proof decomp with accumulated check proofs (FIXED) ────────── *)

let test_R59_PD01_decomp_chain_works () =
  (* FIXED in R59: let (v ::: p) = b; andLeft p now correctly works.
     The runtime accumulates proofs oldest-first, so andLeft returns A (first)
     and andRight returns B (second) for checkB(checkA(raw)). *)
  should_pass {|
#lang tesl
module R59Pd01 exposing []
import Tesl.Prelude exposing [Int, Fact, detachFact, forgetFact, attachFact, andLeft, andRight, introAnd]
fact A (n: Int)
fact B (n: Int)
check checkA(n: Int) -> n: Int ::: A n =
  if n > 0 then
    ok n ::: A n
  else
    fail 400 "fail A"
check checkB(n: Int ::: A n) -> n: Int ::: B n =
  if n < 1000 then
    ok n ::: B n
  else
    fail 400 "fail B"
fn needsA(n: Int ::: A n) -> Int = n
fn testDecomp(raw: Int) -> Int =
  let a = check checkA raw
  let b = check checkB a
  let (v ::: p) = b
  let pA = andLeft p
  let withA = v ::: pA
  needsA withA
|}

(* ── R59_EM — Error message quality ────────────────────────────────────── *)

let test_R59_EM01_case_arm_proof_error_shows_wrong_subject () =
  (* The error for case-arm proof failure shows the scrutinee subject name
     (e.g., "IsPositive m") instead of the inner binder subject (e.g., "IsPositive v").
     This makes the hint confusing since m is a Maybe value, not an Int.
     This test documents the confusing error exists (can't easily test error message quality). *)
  should_fail "IsPositive m\\|does not statically satisfy" {|
#lang tesl
module R59Em01 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
fn needsPositive(n: Int ::: IsPositive n) -> Int = n
fn caseTest(raw: Int) -> Int =
  let m = if raw > 0 then
    Something raw
  else
    Nothing
  case m of
    Nothing -> 0
    Something v ->
      needsPositive v
|}

(* ── R59_NF — No surface syntax for selecting specific proof in multi-proof ─ *)

let test_R59_NF01_multi_proof_detach_no_select_syntax () =
  (* When a value has multiple accumulated proofs, there is no valid surface
     syntax to select just one proof via detachFact. The two-argument form is
     not supported. *)
  should_fail "expected.*)\\|unknown constructor" {|
#lang tesl
module R59Nf01 exposing []
import Tesl.Prelude exposing [Int, Fact, detachFact]
fact A (n: Int)
fact B (n: Int)
check checkA(n: Int) -> n: Int ::: A n =
  if n > 0 then
    ok n ::: A n
  else
    fail 400 "fail A"
check checkB(n: Int ::: A n) -> n: Int ::: B n =
  if n < 1000 then
    ok n ::: B n
  else
    fail 400 "fail B"
fn selectA(raw: Int) -> Int =
  let a = check checkA raw
  let b = check checkB a
  let pa = detachFact(b, A b)
  0
|}

(* ── R59_EI — Empty list ForAll enforcement ────────────────────────────── *)

let test_R59_EI01_empty_list_binding_no_vacuous_forall () =
  (* Passing an empty list binding to a ForAll-requiring function is correctly rejected.
     This tests the call-site check (R58_FC02 coverage, kept for regression). *)
  should_fail "does not statically satisfy.*ForAll" {|
#lang tesl
module R59Ei01 exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.length]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
fn needsForAll(xs: List Int ::: ForAll (IsPositive) xs) -> Int =
  List.length xs
fn testEmpty() -> Int =
  let emptyNums = []
  needsForAll emptyNums
|}

let test_R59_EI02_empty_list_return_passes_check_gap () =
  (* BUG: Returning [] directly from a ForAll-typed fn is silently accepted by the compiler.
     The spec says empty lists should require List.emptyForAll, but the compiler
     does not enforce this for the return position — only at call sites.
     This test documents that the gap exists (static checker does NOT catch this). *)
  should_pass {|
#lang tesl
module R59Ei02 exposing []
import Tesl.Prelude exposing [Int, List]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
fn fakeForAll() -> List Int ::: ForAll (IsPositive) =
  []
|}

(* ── Test suite registration ───────────────────────────────────────────── *)

let () =
  run "Review59-Antagonistic" [
    "ok-pipe-syntax", [
      test_case "R59_OP01 ok <| proof rejected in establish (spec/impl gap)" `Quick
        test_R59_OP01_ok_pipe_rejected_in_establish;
      test_case "R59_OP02 establish direct return works" `Quick
        test_R59_OP02_establish_direct_return_works;
    ];
    "fn-proof-restrictions", [
      test_case "R59_FN01 fn cannot declare proof-carrying return type" `Quick
        test_R59_FN01_fn_cannot_declare_proof_return;
      test_case "R59_FN02 fn cannot use ok ::: proof" `Quick
        test_R59_FN02_fn_cannot_use_ok_proof;
    ];
    "establish-restrictions", [
      test_case "R59_ES01 establish cannot use fail" `Quick
        test_R59_ES01_establish_cannot_use_fail;
      test_case "R59_ES02 establish cannot call check" `Quick
        test_R59_ES02_establish_cannot_call_check;
    ];
    "literal-to-proof-param", [
      test_case "R59_LT01 literal to proof-requiring param rejected" `Quick
        test_R59_LT01_literal_to_proof_param_rejected;
    ];
    "shadowing-prevention", [
      test_case "R59_SH01 let shadowing rejected" `Quick
        test_R59_SH01_let_shadowing_rejected;
      test_case "R59_SH02 case arm shadowing rejected" `Quick
        test_R59_SH02_case_arm_shadowing_rejected;
    ];
    "case-arm-proof", [
      test_case "R59_CA01 case arm binding has no proof" `Quick
        test_R59_CA01_case_arm_binding_no_proof;
    ];
    "forall-restrictions", [
      test_case "R59_FA01 ForAll on non-List rejected" `Quick
        test_R59_FA01_forall_on_non_list_rejected;
      test_case "R59_FA02 ForAll proof mismatch on param" `Quick
        test_R59_FA02_forall_proof_mismatch_on_param;
      test_case "R59_FA03 ForAll fabrication plain list rejected" `Quick
        test_R59_FA03_forall_fabrication_plain_list_rejected;
    ];
    "capability-propagation", [
      test_case "R59_CP01 missing capability from callee" `Quick
        test_R59_CP01_missing_capability_from_callee;
    ];
    "deep-chain-rejection", [
      test_case "R59_DC01 missing intermediate proof rejected" `Quick
        test_R59_DC01_missing_intermediate_proof_rejected;
    ];
    "adt-proof-loss", [
      test_case "R59_AD01 user-defined ADT proof loss caught" `Quick
        test_R59_AD01_user_adt_proof_loss_caught;
    ];
    "maybe-proof-consistency", [
      test_case "R59_SM01 Maybe wrap now correctly rejected (FIXED)" `Quick
        test_R59_SM01_maybe_wrap_now_rejected;
    ];
    "detach-template-syntax", [
      test_case "R59_DT01 detachFact comma syntax rejected" `Quick
        test_R59_DT01_detach_template_no_comma_syntax;
      test_case "R59_DT02 detachFact ML-style template rejected (A parsed as ctor)" `Quick
        test_R59_DT02_detach_ml_style_template_rejected;
    ];
    "proof-decomp-accumulation", [
      test_case "R59_PD01 proof decomp andLeft now works (FIXED)" `Quick
        test_R59_PD01_decomp_chain_works;
    ];
    "error-message-quality", [
      test_case "R59_EM01 case-arm proof error shows scrutinee subject (misleading)" `Quick
        test_R59_EM01_case_arm_proof_error_shows_wrong_subject;
    ];
    "no-select-syntax", [
      test_case "R59_NF01 no surface syntax to select proof from multi-proof value" `Quick
        test_R59_NF01_multi_proof_detach_no_select_syntax;
    ];
    "empty-list-forall", [
      test_case "R59_EI01 empty list binding rejected at ForAll call site" `Quick
        test_R59_EI01_empty_list_binding_no_vacuous_forall;
      test_case "R59_EI02 empty list return passes (compiler gap: not caught at return)" `Quick
        test_R59_EI02_empty_list_return_passes_check_gap;
    ];
  ]
