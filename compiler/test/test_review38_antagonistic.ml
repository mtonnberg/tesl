(** Antagonistic regression tests for Critical Review 38.

    Confirmed strengths covered here:
    R38_01  Duplicate top-level function parameters are rejected
    R38_02  Lambda parameters cannot shadow an outer binding in ordinary code
    R38_03  Case-pattern binders cannot shadow parameters in ordinary code
    R38_04  Duplicate binders in ordinary case patterns are rejected
    R38_05  Case guards accept hygienic lambdas
    R38_06  Test blocks with distinct lets compile
    R38_07  Properties with distinct parameters compile
    R38_08  Test-block case statements with distinct binders compile

    Confirmed gaps fixed here:
    R38_09  Duplicate lambda parameters were accepted
    R38_10  Nested duplicate lambda parameters were accepted
    R38_11  Guard lambdas could shadow outer names
    R38_12  Guard lambdas could duplicate parameter names
    R38_13  Test-block lets could shadow earlier test locals
    R38_14  Nested test-block lets in case arms could shadow outer locals
    R38_15  Lambdas inside test expressions could shadow outer test locals
    R38_16  Test-block case patterns could shadow outer test locals
    R38_17  Test-block case patterns could duplicate binders
    R38_18  Properties could duplicate parameter names
    R38_19  Properties could duplicate parameter names with where-clauses
    R38_20  Property parameters could shadow outer test locals
    R38_21  Lambdas inside property bodies could shadow property parameters
    R38_22  Property case patterns could shadow property parameters
    R38_23  Test-block case guards could shadow outer test locals
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
  let tmp = Filename.temp_file "tesl-r38-test" ".tesl" in
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

let prelude_int = {|import Tesl.Prelude exposing [Int]|}
let prelude_int_bool = {|import Tesl.Prelude exposing [Int, Bool(..)]|}
let maybe_import = {|import Tesl.Maybe exposing [Maybe(..)]|}
let pairish_decl = {|type Pairish
  = MkPairish left: Int right: Int|}
let wrap_decl = {|type WrappedInt
  = Wrap value: Int|}

let r38_01_function_duplicate_params_rejected () =
  should_fail "duplicate parameter name" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

fn demo(x: Int, x: Int) -> Int =
  x
|}

let r38_02_lambda_shadow_outer_rejected () =
  should_fail "shadow" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

fn demo(x: Int) -> Int =
  (fn(x: Int) -> x) 1
|}

let r38_03_expr_case_binder_shadow_param_rejected () =
  should_fail "shadow" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]

fn demo(x: Int, m: Maybe Int) -> Int =
  case m of
    Something x -> x
    Nothing -> 0
|}

let r38_04_expr_case_duplicate_binder_rejected () =
  should_fail "duplicate variable binding" (Printf.sprintf {|#lang tesl
module Test exposing []
%s
%s

fn demo(p: Pairish) -> Int =
  case p of
    MkPairish x x -> x
|} prelude_int pairish_decl)

let r38_05_guard_with_distinct_lambda_passes () =
  (* Guarded arms require a fallback arm for exhaustiveness — add `Something _ -> 0`
     to cover the case when the guard fails. The key test property is that a
     lambda `fn(z: Int) -> True` in the guard is hygienic (no shadowing error). *)
  should_pass (Printf.sprintf {|#lang tesl
module Test exposing []
%s
%s

fn demo(x: Int, m: Maybe Int) -> Int =
  case m of
    Something y where ((fn(z: Int) -> True) x) -> y
    Something _ -> 0
    Nothing -> 0
|} prelude_int_bool maybe_import)

let r38_06_test_block_distinct_lets_pass () =
  should_pass {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

test "distinct lets" {
  let x = 1
  let y = 2
  expect x + y == 3
}
|}

let r38_07_property_distinct_params_pass () =
  should_pass {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, Bool(..)]

test "distinct property params" with 5 runs {
  property "p" (x: Int, y: Int where x == x && y == y) {
    x == x && y == y
  }
}
|}

let r38_08_test_case_distinct_binder_pass () =
  should_pass (Printf.sprintf {|#lang tesl
module Test exposing []
%s
%s

test "case binder" {
  let w = Wrap(2)
  case w of
    Wrap value -> expect value == 2
  }
|} prelude_int wrap_decl)

let r38_09_lambda_duplicate_params_rejected () =
  should_fail "duplicate parameter name" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

fn demo() -> Int =
  (fn(x: Int, x: Int) -> x) 1 2
|}

let r38_10_nested_lambda_duplicate_params_rejected () =
  should_fail "duplicate parameter name" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

fn demo() -> Int =
  (fn(n: Int) -> (fn(x: Int, x: Int) -> x) n n) 1
|}

let r38_11_guard_lambda_shadow_outer_rejected () =
  should_fail "shadow" (Printf.sprintf {|#lang tesl
module Test exposing []
%s
%s

fn demo(x: Int, m: Maybe Int) -> Int =
  case m of
    Something y where ((fn(x: Int) -> True) 1) -> y
    Nothing -> 0
|} prelude_int_bool maybe_import)

let r38_12_guard_lambda_duplicate_params_rejected () =
  should_fail "duplicate parameter name" (Printf.sprintf {|#lang tesl
module Test exposing []
%s
%s

fn demo(m: Maybe Int) -> Int =
  case m of
    Something y where ((fn(x: Int, x: Int) -> True) 1 2) -> y
    Nothing -> 0
|} prelude_int_bool maybe_import)

let r38_13_test_let_shadowing_rejected () =
  should_fail "shadow" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

test "shadow" {
  let x = 1
  let x = 2
  expect x == 2
}
|}

let r38_14_nested_test_case_let_shadowing_rejected () =
  should_fail "shadow" (Printf.sprintf {|#lang tesl
module Test exposing []
%s
%s

test "nested shadow" {
  let x = 1
  let w = Wrap(2)
  case w of
    Wrap value ->
      let x = value
      expect x == 2
  }
|} prelude_int wrap_decl)

let r38_15_test_lambda_shadow_outer_let_rejected () =
  should_fail "shadow" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

test "lambda shadow" {
  let x = 1
  expect ((fn(x: Int) -> x) 2) == 2
}
|}

let r38_16_test_case_pattern_shadow_outer_let_rejected () =
  should_fail "shadow" (Printf.sprintf {|#lang tesl
module Test exposing []
%s
%s

test "case shadow" {
  let x = 1
  let s = Something 2
  case s of
    Something x -> expect x == 2
    Nothing -> expect 1 == 2
}
|} prelude_int maybe_import)

let r38_17_test_case_duplicate_pattern_binder_rejected () =
  should_fail "duplicate variable binding" (Printf.sprintf {|#lang tesl
module Test exposing []
%s
%s

test "case dup binder" {
  let p = MkPairish(1)(2)
  case p of
    MkPairish x x -> expect x == 1
}
|} prelude_int pairish_decl)

let r38_18_property_duplicate_params_rejected () =
  should_fail "duplicate parameter name" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, Bool(..)]

test "dup property params" with 10 runs {
  property "p" (x: Int, x: Int) { x == x }
}
|}

let r38_19_property_duplicate_params_with_where_rejected () =
  should_fail "duplicate parameter name" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, Bool(..)]

test "dup property params with where" with 10 runs {
  property "p" (x: Int, x: Int where x == x) { True }
}
|}

let r38_20_property_param_shadows_test_let_rejected () =
  should_fail "shadow" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, Bool(..)]

test "property shadow" with 10 runs {
  let x = 1
  property "p" (x: Int) { x == x }
}
|}

let r38_21_property_lambda_shadow_param_rejected () =
  should_fail "shadow" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, Bool(..)]

test "property lambda shadow" with 5 runs {
  property "p" (x: Int) {
    (fn(x: Int) -> True) x
  }
}
|}

let r38_22_property_case_binder_shadow_param_rejected () =
  should_fail "shadow" (Printf.sprintf {|#lang tesl
module Test exposing []
%s
%s

test "property case shadow" with 5 runs {
  property "p" (x: Int) {
    case Something 2 of
      Something x -> x == 2
      Nothing -> False
  }
}
|} prelude_int_bool maybe_import)

let r38_23_test_case_guard_lambda_shadow_outer_let_rejected () =
  should_fail "shadow" (Printf.sprintf {|#lang tesl
module Test exposing []
%s
%s

test "guard shadow" {
  let x = 1
  let s = Something 2
  case s of
    Something y where ((fn(x: Int) -> True) 1) -> expect y == 2
    Nothing -> expect 1 == 2
}
|} prelude_int_bool maybe_import)

let () =
  run "Review38" [
    "R38 — confirmed strengths", [
      test_case "R38_01 function duplicate params rejected" `Quick r38_01_function_duplicate_params_rejected;
      test_case "R38_02 lambda shadow outer rejected" `Quick r38_02_lambda_shadow_outer_rejected;
      test_case "R38_03 expr case binder shadow param rejected" `Quick r38_03_expr_case_binder_shadow_param_rejected;
      test_case "R38_04 expr case duplicate binder rejected" `Quick r38_04_expr_case_duplicate_binder_rejected;
      test_case "R38_05 hygienic guard lambda passes" `Quick r38_05_guard_with_distinct_lambda_passes;
      test_case "R38_06 test block distinct lets pass" `Quick r38_06_test_block_distinct_lets_pass;
      test_case "R38_07 property distinct params pass" `Quick r38_07_property_distinct_params_pass;
      test_case "R38_08 test case distinct binder passes" `Quick r38_08_test_case_distinct_binder_pass;
    ];
    "R38 — fixed gaps", [
      test_case "R38_09 lambda duplicate params rejected" `Quick r38_09_lambda_duplicate_params_rejected;
      test_case "R38_10 nested lambda duplicate params rejected" `Quick r38_10_nested_lambda_duplicate_params_rejected;
      test_case "R38_11 guard lambda shadow outer rejected" `Quick r38_11_guard_lambda_shadow_outer_rejected;
      test_case "R38_12 guard lambda duplicate params rejected" `Quick r38_12_guard_lambda_duplicate_params_rejected;
      test_case "R38_13 test let shadowing rejected" `Quick r38_13_test_let_shadowing_rejected;
      test_case "R38_14 nested test case let shadowing rejected" `Quick r38_14_nested_test_case_let_shadowing_rejected;
      test_case "R38_15 test lambda shadow outer let rejected" `Quick r38_15_test_lambda_shadow_outer_let_rejected;
      test_case "R38_16 test case pattern shadow outer let rejected" `Quick r38_16_test_case_pattern_shadow_outer_let_rejected;
      test_case "R38_17 test case duplicate pattern binder rejected" `Quick r38_17_test_case_duplicate_pattern_binder_rejected;
      test_case "R38_18 property duplicate params rejected" `Quick r38_18_property_duplicate_params_rejected;
      test_case "R38_19 property duplicate params with where rejected" `Quick r38_19_property_duplicate_params_with_where_rejected;
      test_case "R38_20 property param shadows test let rejected" `Quick r38_20_property_param_shadows_test_let_rejected;
      test_case "R38_21 property lambda shadow param rejected" `Quick r38_21_property_lambda_shadow_param_rejected;
      test_case "R38_22 property case binder shadow param rejected" `Quick r38_22_property_case_binder_shadow_param_rejected;
      test_case "R38_23 test case guard lambda shadow outer let rejected" `Quick r38_23_test_case_guard_lambda_shadow_outer_let_rejected;
    ];
  ]
