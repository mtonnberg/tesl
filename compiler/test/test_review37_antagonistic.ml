(** Antagonistic regression tests for Critical Review 37.

    Confirmed strengths covered here:
    R37_01  Ordering on Bool is rejected with a targeted diagnostic
    R37_02  Duplicate imports from a module are rejected
    R37_03  Exporting an unknown local name is rejected
    R37_04  Duplicate record fields are rejected
    R37_05  Duplicate constructors within one ADT are rejected
    R37_06  Exhaustive Bool case with both branches compiles
    R37_07  let-proof with distinct binders compiles
    R37_08  let-proof with ignored value and distinct proof binder compiles
    R37_09  String case without catch-all is rejected
    R37_10  Ordinary let shadowing is rejected

    Confirmed gaps exposed here:
    R37_11  Duplicate names in module exposing list are accepted
    R37_12  Bool case missing False is accepted
    R37_13  Bool case missing True is accepted
    R37_14  let-proof value binder may shadow an outer local
    R37_15  let-proof proof binder may shadow an outer local
    R37_16  let-proof value binder may shadow a parameter
    R37_17  let-proof proof binder may shadow a parameter
    R37_18  let-proof accepts duplicate proof binders
    R37_19  let-proof accepts duplicate proof binders when value is ignored
    R37_20  ADT constructors may collide across different ADTs
*)

open Alcotest

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

let compile_string ?(mode = check_subcmd) src =
  let tmp = Filename.temp_file "tesl-r37-test" ".tesl" in
  let oc = open_out tmp in
  output_string oc src;
  close_out oc;
  let cmd =
    if mode = "" then Printf.sprintf "%s %s 2>&1" tesl tmp
    else Printf.sprintf "%s %s %s 2>&1" tesl mode tmp
  in
  let ic = Unix.open_process_in cmd in
  let out = In_channel.input_all ic in
  let _ = Unix.close_process_in ic in
  (try Sys.remove tmp with _ -> ());
  out

let has_error out =
  let re = Str.regexp "error\\[" in
  try ignore (Str.search_forward re out 0); true with Not_found -> false

let should_pass src =
  let out = compile_string src in
  if has_error out then
    Printf.eprintf "Unexpected error output:\n%s\n" out;
  check bool "should compile without errors" false (has_error out)

let should_fail pattern src =
  let out = compile_string src in
  let found =
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0); true with Not_found -> false
  in
  if not found then
    Printf.eprintf "Expected pattern '%s' in:\n%s\n" pattern out;
  check bool (Printf.sprintf "should fail: %s" pattern) true found

let proof_prelude = {|import Tesl.Prelude exposing [Int]

fact Positive (n: Int)

check isPositive(n: Int) -> n: Int ::: Positive n =
  ok n ::: Positive n
|}

let r37_01_bool_ordering_rejected () =
  should_fail "ordering\\|not defined for type `Bool`" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Bool]

fn bad(a: Bool, b: Bool) -> Bool =
  a < b
|}

let r37_02_duplicate_imports_rejected () =
  should_fail "duplicate import" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, Int]
|}

let r37_03_unknown_export_rejected () =
  should_fail "unknown\\|export" {|#lang tesl
module Test exposing [missing]
import Tesl.Prelude exposing [Int]

fn x() -> Int =
  1
|}

let r37_04_duplicate_record_fields_rejected () =
  should_fail "duplicate field" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [String]

record Bad {
  name: String
  name: String
}
|}

let r37_05_duplicate_ctor_same_adt_rejected () =
  should_fail "duplicate constructor" {|#lang tesl
module Test exposing []

type Traffic
  = Red
  | Red
|}

let r37_06_complete_bool_case_passes () =
  should_pass {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Bool, String]

fn describe(b: Bool) -> String =
  case b of
    True -> "t"
    False -> "f"
|}

let r37_07_let_proof_distinct_binders_passes () =
  should_pass (Printf.sprintf {|#lang tesl
module Test exposing []
%s
fn demo(n: Int) -> Int =
  let (m ::: positiveProof) = check isPositive n
  m
|} proof_prelude)

let r37_08_let_proof_ignored_value_passes () =
  should_pass (Printf.sprintf {|#lang tesl
module Test exposing []
%s
fn demo(n: Int) -> Int =
  let (_ ::: positiveProof) = check isPositive n
  0
|} proof_prelude)

let r37_09_string_case_requires_catchall () =
  should_fail "catch-all\\|wildcard\\|missing" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [String]

fn describe(s: String) -> String =
  case s of
    "x" -> "x"
|}

let r37_10_normal_let_shadowing_rejected () =
  should_fail "shadow" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

fn demo(n: Int) -> Int =
  let n = 1
  n
|}

let r37_11_duplicate_exports_should_be_rejected () =
  should_fail "duplicate.*export\\|module exposes duplicate" {|#lang tesl
module Test exposing [x, x]
import Tesl.Prelude exposing [Int]

fn x() -> Int =
  1
|}

let r37_12_bool_case_missing_false_should_fail () =
  should_fail "exhaustive\\|missing\\|False" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Bool, String]

fn describe(b: Bool) -> String =
  case b of
    True -> "t"
|}

let r37_13_bool_case_missing_true_should_fail () =
  should_fail "exhaustive\\|missing\\|True" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Bool, String]

fn describe(b: Bool) -> String =
  case b of
    False -> "f"
|}

let r37_14_let_proof_value_shadowing_local_should_fail () =
  should_fail "shadow" (Printf.sprintf {|#lang tesl
module Test exposing []
%s
fn demo(n: Int) -> Int =
  let m = 1
  let (m ::: proofP) = check isPositive n
  m
|} proof_prelude)

let r37_15_let_proof_proof_shadowing_local_should_fail () =
  should_fail "shadow" (Printf.sprintf {|#lang tesl
module Test exposing []
%s
fn demo(n: Int) -> Int =
  let p = 1
  let (_ ::: p) = check isPositive n
  0
|} proof_prelude)

let r37_16_let_proof_value_shadowing_param_should_fail () =
  should_fail "shadow" (Printf.sprintf {|#lang tesl
module Test exposing []
%s
fn demo(n: Int) -> Int =
  let (n ::: proofP) = check isPositive n
  0
|} proof_prelude)

let r37_17_let_proof_proof_shadowing_param_should_fail () =
  should_fail "shadow" (Printf.sprintf {|#lang tesl
module Test exposing []
%s
fn demo(p: Int) -> Int =
  let (_ ::: p) = isPositive p
  0
|} proof_prelude)

let r37_18_duplicate_proof_binders_should_fail () =
  should_fail "duplicate\\|shadow" (Printf.sprintf {|#lang tesl
module Test exposing []
%s
fn demo(n: Int) -> Int =
  let (m ::: p && p) = check isPositive n
  m
|} proof_prelude)

let r37_19_duplicate_proof_binders_with_ignored_value_should_fail () =
  should_fail "duplicate\\|shadow" (Printf.sprintf {|#lang tesl
module Test exposing []
%s
fn demo(n: Int) -> Int =
  let (_ ::: p && p) = check isPositive n
  0
|} proof_prelude)

let r37_20_duplicate_ctor_across_adts_should_fail () =
  should_fail "duplicate constructor\\|constructor.*unique" {|#lang tesl
module Test exposing []

type A
  = Same

type B
  = Same
|}

let () =
  run "Review37" [
    "R37 — confirmed strengths", [
      test_case "R37_01 Bool ordering rejected" `Quick r37_01_bool_ordering_rejected;
      test_case "R37_02 duplicate imports rejected" `Quick r37_02_duplicate_imports_rejected;
      test_case "R37_03 unknown export rejected" `Quick r37_03_unknown_export_rejected;
      test_case "R37_04 duplicate record fields rejected" `Quick r37_04_duplicate_record_fields_rejected;
      test_case "R37_05 duplicate ctor in one ADT rejected" `Quick r37_05_duplicate_ctor_same_adt_rejected;
      test_case "R37_06 exhaustive Bool case passes" `Quick r37_06_complete_bool_case_passes;
      test_case "R37_07 let-proof with distinct binders passes" `Quick r37_07_let_proof_distinct_binders_passes;
      test_case "R37_08 let-proof ignoring value passes" `Quick r37_08_let_proof_ignored_value_passes;
      test_case "R37_09 String case needs catch-all" `Quick r37_09_string_case_requires_catchall;
      test_case "R37_10 ordinary let shadowing rejected" `Quick r37_10_normal_let_shadowing_rejected;
    ];
    "R37 — confirmed gaps", [
      test_case "R37_11 duplicate exports should be rejected" `Quick r37_11_duplicate_exports_should_be_rejected;
      test_case "R37_12 Bool case missing False should fail" `Quick r37_12_bool_case_missing_false_should_fail;
      test_case "R37_13 Bool case missing True should fail" `Quick r37_13_bool_case_missing_true_should_fail;
      test_case "R37_14 let-proof value shadowing local should fail" `Quick r37_14_let_proof_value_shadowing_local_should_fail;
      test_case "R37_15 let-proof proof shadowing local should fail" `Quick r37_15_let_proof_proof_shadowing_local_should_fail;
      test_case "R37_16 let-proof value shadowing param should fail" `Quick r37_16_let_proof_value_shadowing_param_should_fail;
      test_case "R37_17 let-proof proof shadowing param should fail" `Quick r37_17_let_proof_proof_shadowing_param_should_fail;
      test_case "R37_18 duplicate proof binders should fail" `Quick r37_18_duplicate_proof_binders_should_fail;
      test_case "R37_19 duplicate proof binders with ignored value should fail" `Quick r37_19_duplicate_proof_binders_with_ignored_value_should_fail;
      test_case "R37_20 duplicate ctor across ADTs should fail" `Quick r37_20_duplicate_ctor_across_adts_should_fail;
    ];
  ]
