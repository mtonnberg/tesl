(** Antagonistic regression tests for Critical Review 36.

    Each test probes a specific correctness gap, ergonomic limitation, or
    soundness boundary.

    Findings covered:
      R36_01  Comparison operator accepts heterogeneous types (String == Int)
      R36_02  Boolean operators don't enforce Bool operands (Int && Int)
      R36_03  Shadowing in nested let bindings is rejected
      R36_04  Shadowing in case arms vs outer scope is rejected
      R36_05  Exhaustive match: missing ADT constructor is caught
      R36_06  Newtype nominal distinctness: UserId != ProjectId
      R36_07  Newtype in List context: List UserId != List String
      R36_08  Proof fabrication via ::: in handler body is rejected
      R36_09  check function with wrong ok binding name is rejected
      R36_10  establish with fail is rejected (establish is total)
      R36_11  Integer literal out of fixnum range is rejected
      R36_12  Recursive ADT (Tree a) type-checks correctly
      R36_13  Higher-order function type inference works
      R36_14  case with integer literal patterns requires catch-all
      R36_15  BUG: Duplicate record field names are NOT rejected
      R36_16  Accessing non-existent field on record is rejected
      R36_17  Return type mismatch in fn body is caught
      R36_18  Partial application preserves type safety
      R36_19  List literal type homogeneity is enforced
      R36_20  Single-line ADT is caught by linter as W040
      R36_21  Nested case/if expressions type-check correctly
      R36_22  Lambda with wrong inferred type is caught by HM checker
      R36_23  Proof predicate not in scope is rejected
      R36_24  Calling fn that requires capability from context without it
      R36_25  Double shadowing (param and let) is rejected
      R36_26  case on String requires catch-all (infinite domain)
      R36_27  ADT constructor name colliding with type name is rejected
      R36_28  Float/Int mixing in arithmetic is rejected
      R36_29  Maybe unwrapping without case is caught
      R36_30  Proof flow through check + call is valid
      R36_31  Empty module compiles
      R36_32  Import nonexistent Tesl module is rejected
      R36_33  Duplicate top-level function names are rejected
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

let compile_string ?(mode = check_subcmd) src =
  let tmp = Filename.temp_file "tesl-r36-test" ".tesl" in
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

(* ── Tests ──────────────────────────────────────────────────────────────── *)

let r36_01_heterogeneous_comparison () =
  should_fail "type.*mismatch\\|cannot unify" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, Bool]

fn bad(s: String, n: Int) -> Bool =
  s == n
|}

let r36_02_boolean_op_on_non_bool () =
  should_fail "type.*mismatch\\|cannot unify" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, Bool]

fn bad(x: Int, y: Int) -> Bool =
  x && y
|}

let r36_03_shadowing_in_nested_let () =
  should_fail "shadow" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

fn bad(x: Int) -> Int =
  let x = 42
  x
|}

let r36_04_shadowing_in_case_arm () =
  should_fail "shadow" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe, Something, Nothing]

fn bad(x: Int) -> Int =
  let m = Something 42
  case m of
    Something x -> x
    Nothing -> 0
|}

let r36_05_non_exhaustive_match () =
  should_fail "exhaustive\\|missing" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String]

type Color
  = Red
  | Green
  | Blue

fn describe(c: Color) -> String =
  case c of
    Red -> "red"
    Green -> "green"
|}

let r36_06_newtype_nominal_distinctness () =
  should_fail "cannot unify\\|type.*mismatch" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [String]

type UserId = String
type ProjectId = String

fn takesUser(id: UserId) -> String =
  id.value

fn bad(pid: ProjectId) -> String =
  takesUser pid
|}

let r36_07_newtype_in_list () =
  should_fail "cannot unify\\|type.*mismatch" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, List]

type UserId = String

fn takesStringList(xs: List String) -> Int =
  List.length xs

fn bad(ids: List UserId) -> Int =
  takesStringList ids
|}

let r36_08_proof_fabrication_in_handler () =
  should_fail "not allowed\\|proof.*construct" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, Fact]

fact ValidPort (p: Int)

fn listen(port: Int ::: ValidPort port) -> Int =
  port

handler sneaky(n: Int) -> Int
  requires [] =
  listen <| n ::: ValidPort n
|}

let r36_09_check_wrong_ok_binding () =
  should_fail "binding\\|must return\\|constructor\\|declared binding" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

fact IsPositive (n: Int)

check validatePositive(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok 42 ::: IsPositive n
  else
    fail 400 "not positive"
|}

let r36_10_establish_with_fail () =
  should_fail "fail\\|establish.*total\\|not allowed" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, Fact]

fact IsPositive (n: Int)

establish provePositive(n: Int) -> Fact (IsPositive n) =
  if n > 0 then
    IsPositive n
  else
    fail 400 "not positive"
|}

let r36_11_integer_overflow () =
  (* A9/HM-1: Int is arbitrary-precision; a huge literal compiles (carried as
     an LBigInt canonical string into the Racket bignum), no longer rejected. *)
  should_pass {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

fn big() -> Int =
  9999999999999999999999999
|}

let r36_12_recursive_adt () =
  should_pass {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String]

type Tree a
  = Leaf
  | Node left:(Tree a) value:a right:(Tree a)

fn size(t: Tree Int) -> Int =
  case t of
    Leaf -> 0
    Node left _ right -> 1 + (size left) + (size right)
|}

let r36_13_higher_order_fn () =
  should_pass {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.map]

fn double(n: Int) -> Int =
  n + n

fn mapDouble(xs: List Int) -> List Int =
  List.map double xs
|}

let r36_14_int_case_needs_catchall () =
  should_fail "exhaustive\\|catch-all\\|wildcard\\|missing" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String]

fn describe(n: Int) -> String =
  case n of
    0 -> "zero"
    1 -> "one"
|}

let r36_15_duplicate_record_fields () =
  should_fail "duplicate" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [String]

record BadRecord {
  name: String
  name: String
}
|}

let r36_16_nonexistent_field_access () =
  should_fail "field\\|unknown\\|not.*found\\|no.*field" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String]

record User {
  name: String
  age: Int
}

fn getEmail(u: User) -> String =
  u.email
|}

let r36_17_return_type_mismatch () =
  should_fail "cannot unify\\|type.*mismatch" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String]

fn bad() -> String =
  42
|}

let r36_18_partial_application_type_safe () =
  should_pass {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

fn add(x: Int, y: Int) -> Int =
  x + y

fn test() -> Int =
  let add3 = add 3
  add3 7
|}

let r36_19_list_type_homogeneity () =
  should_fail "cannot unify\\|type.*mismatch" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, List]

fn bad() -> List Int =
  [1, "two", 3]
|}

let r36_20_single_line_adt_linter () =
  let src = {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [String]

type Color = Red | Green | Blue
|} in
  let out = compile_string ~mode:"--lint" src in
  let found =
    let re = Str.regexp_case_fold "W040\\|looks like an ADT" in
    try ignore (Str.search_forward re out 0); true with Not_found -> false
  in
  if not found then
    Printf.eprintf "Expected W040 lint warning in:\n%s\n" out;
  check bool "should warn: W040 single-line ADT" true found

let r36_21_nested_if_case_typechecks () =
  should_pass {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe, Something, Nothing]

fn complex(m: Maybe Int) -> String =
  case m of
    Something n ->
      if n > 0 then
        "positive"
      else
        "non-positive"
    Nothing -> "nothing"
|}

let r36_22_lambda_wrong_return_type () =
  should_fail "cannot unify\\|type.*mismatch" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, List, Bool]
import Tesl.List exposing [List.map]

fn bad(xs: List Int) -> List String =
  List.map (fn(n: Int) -> n > 0) xs
|}

let r36_23_proof_predicate_not_in_scope () =
  should_fail "not in scope\\|not.*declared\\|not.*import" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

fn listen(port: Int ::: UndeclaredProof port) -> Int =
  port
|}

(* R36_24: calling a fn with capabilities from a context that lacks them *)
let r36_24_capability_insufficiency () =
  should_fail "capability\\|requires\\|not.*declared\\|does not" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
import Tesl.DB exposing [dbRead, dbWrite]

capability readCap implies dbRead
capability writeCap implies dbWrite

fn doWrite() -> Int
  requires [writeCap] =
  42

fn badCaller() -> Int
  requires [readCap] =
  doWrite()
|}

let r36_25_double_shadowing () =
  should_fail "shadow" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

fn bad(n: Int) -> Int =
  let n = 1
  n
|}

let r36_26_string_case_requires_catchall () =
  should_fail "exhaustive\\|catch-all\\|wildcard\\|missing" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String]

fn parseCmd(s: String) -> Int =
  case s of
    "help" -> 1
    "quit" -> 2
|}

let r36_27_adt_ctor_name_collision () =
  should_fail "constructor.*same.*type\\|collision\\|ambig\\|cannot.*share" {|#lang tesl
module Test exposing []

type Status
  = Status
  | Other
|}

let r36_28_float_int_mixing () =
  should_fail "cannot unify\\|type.*mismatch" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Float exposing [Float]

fn bad(x: Float) -> Float =
  x + 1
|}

let r36_29_maybe_without_unwrap () =
  should_fail "cannot unify\\|type.*mismatch" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe, Something, Nothing]

fn bad(m: Maybe Int) -> Int =
  m + 1
|}

let r36_30_proof_valid_flow () =
  should_pass {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, Fact]

fact IsPositive (n: Int)

check validatePositive(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"

fn requiresPositive(n: Int ::: IsPositive n) -> Int =
  n

fn validUsage(n: Int) -> Int =
  let validated = check validatePositive(n)
  requiresPositive validated
|}

let r36_31_empty_module_compiles () =
  should_pass {|#lang tesl
module Empty exposing []
|}

let r36_32_import_nonexistent_module () =
  should_fail "not found\\|does not exist\\|unknown.*module\\|cannot.*find" {|#lang tesl
module Test exposing []
import Tesl.NonExistentModule exposing [something]

fn f() -> Int = 1
|}

let r36_33_duplicate_top_level_fn () =
  should_fail "duplicate\\|already.*defined\\|redefined" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

fn double(n: Int) -> Int =
  n + n

fn double(n: Int) -> Int =
  n * 2
|}


let r36_34_duplicate_entity_fields () =
  should_fail "duplicate" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [String, Int]

entity Bug table "bugs" primaryKey id {
  id: String
  name: String
  name: Int
}
|}
(* ── Test registration ──────────────────────────────────────────────────── *)

let () =
  run "Review36" [
    "R36 — type system", [
      test_case "R36_01 heterogeneous comparison" `Quick r36_01_heterogeneous_comparison;
      test_case "R36_02 boolean op on non-bool"   `Quick r36_02_boolean_op_on_non_bool;
      test_case "R36_06 newtype nominal"           `Quick r36_06_newtype_nominal_distinctness;
      test_case "R36_07 newtype in list"           `Quick r36_07_newtype_in_list;
      test_case "R36_11 integer overflow literal"  `Quick r36_11_integer_overflow;
      test_case "R36_12 recursive ADT"             `Quick r36_12_recursive_adt;
      test_case "R36_13 higher-order fn"           `Quick r36_13_higher_order_fn;
      test_case "R36_17 return type mismatch"      `Quick r36_17_return_type_mismatch;
      test_case "R36_18 partial application"       `Quick r36_18_partial_application_type_safe;
      test_case "R36_19 list type homogeneity"     `Quick r36_19_list_type_homogeneity;
      test_case "R36_22 lambda wrong return type"  `Quick r36_22_lambda_wrong_return_type;
      test_case "R36_28 float/int mixing"          `Quick r36_28_float_int_mixing;
      test_case "R36_29 Maybe without unwrap"      `Quick r36_29_maybe_without_unwrap;
    ];
    "R36 — proof system", [
      test_case "R36_08 proof fabrication in handler" `Quick r36_08_proof_fabrication_in_handler;
      test_case "R36_09 check wrong ok binding"       `Quick r36_09_check_wrong_ok_binding;
      test_case "R36_10 establish with fail"           `Quick r36_10_establish_with_fail;
      test_case "R36_23 proof predicate not in scope"  `Quick r36_23_proof_predicate_not_in_scope;
      test_case "R36_30 proof valid flow"              `Quick r36_30_proof_valid_flow;
    ];
    "R36 — name scoping", [
      test_case "R36_03 shadowing in let"           `Quick r36_03_shadowing_in_nested_let;
      test_case "R36_04 shadowing in case arm"      `Quick r36_04_shadowing_in_case_arm;
      test_case "R36_25 double shadowing"            `Quick r36_25_double_shadowing;
    ];
    "R36 — pattern matching", [
      test_case "R36_05 non-exhaustive match"     `Quick r36_05_non_exhaustive_match;
      test_case "R36_14 int case needs catchall"  `Quick r36_14_int_case_needs_catchall;
      test_case "R36_21 nested if/case"           `Quick r36_21_nested_if_case_typechecks;
      test_case "R36_26 string case needs catchall" `Quick r36_26_string_case_requires_catchall;
    ];
    "R36 — declarations", [
      test_case "R36_15 duplicate record fields" `Quick r36_15_duplicate_record_fields;
      test_case "R36_16 nonexistent field access"   `Quick r36_16_nonexistent_field_access;
      test_case "R36_27 ADT ctor name collision"    `Quick r36_27_adt_ctor_name_collision;
      test_case "R36_31 empty module compiles"      `Quick r36_31_empty_module_compiles;
      test_case "R36_32 import nonexistent module"  `Quick r36_32_import_nonexistent_module;
      test_case "R36_33 duplicate top-level fn"     `Quick r36_33_duplicate_top_level_fn;
      test_case "R36_34 duplicate entity fields" `Quick r36_34_duplicate_entity_fields;
    ];
    "R36 — lint", [
      test_case "R36_20 single-line ADT linter" `Quick r36_20_single_line_adt_linter;
    ];
    "R36 — capabilities", [
      test_case "R36_24 capability insufficiency" `Quick r36_24_capability_insufficiency;
    ];
  ]
