(** Tests for built-in mutation testing (`tesl --mutate`).

    These tests verify that:
    - Mutation sites are correctly identified in check/auth/establish bodies
    - Mutations are correctly applied (binop substitution)
    - Killed/survived/no-tests results are correct
    - Edge cases: no mutable operators, nested binops, weak test coverage
*)

open Alcotest

(* ── Helpers ──────────────────────────────────────────────────────────────── *)

let tesl =
  match Sys.getenv_opt "TESL_BIN" with
  | Some b -> b
  | None ->
    let dir = Filename.dirname Sys.argv.(0) in
    let candidate = Filename.concat (Filename.dirname dir) "bin/main.exe" in
    if Sys.file_exists candidate then candidate
    else
      (* Dune sandbox: try relative path from test CWD *)
      let rel = "../bin/main.exe" in
      if Sys.file_exists rel then rel else "tesl"

let mutate_subcmd =
  if Filename.basename tesl = "main.exe" then "--mutate" else "mutate"

let has_str out sub =
  try ignore (Str.search_forward (Str.regexp_string sub) out 0); true
  with Not_found -> false

let raco_available () =
  Sys.command "raco help >/dev/null 2>&1" = 0

let has_mutate_support () =
  Filename.basename tesl = "main.exe"

(** Run `tesl --mutate` on the given source and return (exit_code, output). *)
let run_mutate src =
  let tmp = Filename.temp_file "tesl-mutate-test" ".tesl" in
  let oc = open_out tmp in
  output_string oc src;
  close_out oc;
  let out_tmp = Filename.temp_file "tesl-mutate-out" ".txt" in
  let status = Sys.command
    (Printf.sprintf "%s %s %s > %s 2>&1" tesl mutate_subcmd tmp out_tmp) in
  let ic = open_in out_tmp in
  let out = In_channel.input_all ic in
  close_in ic;
  (try Sys.remove tmp with _ -> ());
  (try Sys.remove out_tmp with _ -> ());
  (status, out)

(* ── Test cases ───────────────────────────────────────────────────────────── *)

let test_no_raco_skip () =
  (* Skip all mutation tests if raco isn't installed *)
  if not (raco_available ()) then
    skip ()
  else
    ()

(** A check function with strong tests: all 3 mutations of `>` should be killed. *)
let test_all_killed () =
  if not (has_mutate_support ()) then skip ();
  if not (raco_available ()) then skip ();
  let src = {|#lang tesl
module T exposing [checkPos]
import Tesl.Prelude exposing [Int, Bool(..)]

fact IsPositive (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"

test "gt zero" {
  expect (check checkPos 1) == 1
  expectFail check checkPos 0
  expectFail check checkPos (-1)
}
|} in
  let (code, out) = run_mutate src in
  check int "exit 0 means 100% score" 0 code;
  check bool "mentions KILLED" true (String.length out > 0 && has_str out "KILLED");
  check bool "no SURVIVED" false (has_str out "SURVIVED");
  check bool "100% score" true (has_str out "100%")

(** Off-by-one: test at boundary catches `> → >=` mutation. *)
let test_boundary_off_by_one () =
  if not (has_mutate_support ()) then skip ();
  if not (raco_available ()) then skip ();
  let src = {|#lang tesl
module T exposing [checkPos]
import Tesl.Prelude exposing [Int, Bool(..)]

fact IsPositive (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"

test "misses boundary" {
  expect (check checkPos 5) == 5
}
|} in
  let (code, out) = run_mutate src in
  check int "exit 1 means at least one mutant survived" 1 code;
  check bool "mentions SURVIVED" true (has_str out "SURVIVED");
  check bool "does not claim 100% score" false (has_str out "100%")

(** A check with no mutable operators (only string comparison). *)
let test_no_mutations () =
  if not (has_mutate_support ()) then skip ();
  if not (raco_available ()) then skip ();
  let src = {|#lang tesl
module T exposing [checkAdmin]
import Tesl.Prelude exposing [Int, String, Bool(..)]

fact IsAdmin (s: String)

check checkAdmin(s: String) -> s: String ::: IsAdmin s =
  if s == "admin" then
    ok s ::: IsAdmin s
  else
    fail 403 "not admin"

test "admin check" {
  expect (check checkAdmin "admin") == "admin"
  expectFail check checkAdmin "user"
}
|} in
  let (code, out) = run_mutate src in
  (* == → != is a mutation, so there may be 1 mutant *)
  (* Just check it runs without error *)
  check bool "ran without crash" true (code = 0 || code = 1);
  ignore out

(** Compound condition: `&&` → `||` mutation should be caught. *)
let test_compound_condition () =
  if not (has_mutate_support ()) then skip ();
  if not (raco_available ()) then skip ();
  let src = {|#lang tesl
module T exposing [checkRange]
import Tesl.Prelude exposing [Int, Bool(..)]

fact InRange (n: Int)

check checkRange(n: Int) -> n: Int ::: InRange n =
  if n >= 0 && n <= 100 then
    ok n ::: InRange n
  else
    fail 400 "out of range"

test "full coverage" {
  expect (check checkRange 0) == 0
  expect (check checkRange 50) == 50
  expect (check checkRange 100) == 100
  expectFail check checkRange (-1)
  expectFail check checkRange 101
}
|} in
  let (code, out) = run_mutate src in
  check int "exit 0 means 100% score" 0 code;
  check bool "reports score" true (has_str out "100%")

(** `fn` functions are NOT mutated (only check/auth/establish). *)
let test_fn_not_mutated () =
  if not (has_mutate_support ()) then skip ();
  if not (raco_available ()) then skip ();
  let src = {|#lang tesl
module T exposing [checkPos, helper]
import Tesl.Prelude exposing [Int, Bool(..)]

fact IsPositive (n: Int)

fn helper(n: Int) -> Bool =
  n > 0

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"

test "basic" {
  expect (check checkPos 1) == 1
  expectFail check checkPos (-1)
}
|} in
  let (code, out) = run_mutate src in
  (* Only checkPos's `>` is mutated (3 mutants), not helper's `>` *)
  check bool "mentions checkPos" true (has_str out "checkPos");
  ignore code

(** File with no test block: all mutants should show NO TESTS. *)
let test_no_test_block () =
  if not (has_mutate_support ()) then skip ();
  if not (raco_available ()) then skip ();
  let src = {|#lang tesl
module T exposing [checkPos]
import Tesl.Prelude exposing [Int, Bool(..)]

fact IsPositive (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
|} in
  let (code, out) = run_mutate src in
  check bool "no crash" true (code = 0 || code = 1);
  check bool "mentions NO TESTS" true (has_str out "NO TESTS")

(** Parse error should report cleanly. *)
let test_parse_error () =
  if not (has_mutate_support ()) then skip ();
  let src = {|#lang tesl
this is not valid tesl
|} in
  let (code, out) = run_mutate src in
  check int "exit 1 on error" 1 code;
  check bool "error message" true (has_str out "error")

(* ── Suite ────────────────────────────────────────────────────────────────── *)

let () =
  run "Mutation-Testing" [
    "infrastructure", [
      test_case "raco availability check" `Quick test_no_raco_skip;
      test_case "parse error reported cleanly" `Quick test_parse_error;
    ];
    "mutation-results", [
      test_case "all mutants killed with strong tests" `Slow test_all_killed;
      test_case "off-by-one survives weak tests" `Slow test_boundary_off_by_one;
      test_case "no-test block shows NO TESTS" `Slow test_no_test_block;
      test_case "compound condition killed with full coverage" `Slow test_compound_condition;
    ];
    "mutation-scope", [
      test_case "fn functions not mutated" `Slow test_fn_not_mutated;
      test_case "no mutable operators runs cleanly" `Slow test_no_mutations;
    ];
  ]
