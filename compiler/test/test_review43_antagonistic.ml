(** Antagonistic regression tests for Critical Review 43.

    Focus: name hygiene across the user-visible binding surface.

    R43_01  Function parameter cannot shadow its own top-level function name
    R43_02  Function parameter cannot shadow a sibling top-level function name
    R43_03  Local let cannot shadow a sibling top-level function name
    R43_04  Case arm binder cannot shadow a sibling top-level function name
    R43_05  Lambda parameter cannot shadow a sibling top-level function name
    R43_06  Test let cannot shadow a sibling top-level function name
    R43_07  Property parameter cannot shadow a sibling top-level function name
    R43_08  Test case binder cannot shadow a sibling top-level function name
    R43_09  Function parameter cannot shadow the implicit gdp name
    R43_10  Local let cannot shadow the implicit gdp name
    R43_11  Lambda parameter cannot shadow the implicit gdp name
    R43_12  Test let cannot shadow the implicit gdp name
    R43_13  Function parameter cannot shadow an exposed imported function
    R43_14  Local let cannot shadow an exposed imported function
    R43_15  Case arm binder cannot shadow an exposed imported function
    R43_16  Lambda parameter cannot shadow an exposed imported function
    R43_17  Test let cannot shadow an exposed imported function
    R43_18  Property parameter cannot shadow an exposed imported function
    R43_19  Test case binder cannot shadow an exposed imported function
    R43_20  Top-level function cannot shadow an exposed imported function
    R43_21  Two exposing imports cannot introduce the same plain name
    R43_22  Qualified-only import does not poison the plain namespace
    R43_23  Fresh local lets still compile with exposed imports present
    R43_24  Fresh property parameters still compile with exposed imports present
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

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_temp_file prefix suffix content f =
  let path = Filename.temp_file prefix suffix in
  write_file path content;
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () -> f path)

let ensure_parent path =
  let parent = Filename.dirname path in
  if parent <> path && not (Sys.file_exists parent) then Unix.mkdir parent 0o755

let with_temp_project files f =
  let dir = Filename.temp_file "tesl-r43-proj" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  List.iter (fun (rel, content) ->
    let path = Filename.concat dir rel in
    ensure_parent path;
    write_file path content
  ) files;
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () -> f dir)

let should_fail_src pattern src =
  with_temp_file "tesl-r43" ".tesl" src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but compilation succeeded" pattern;
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:
%s" pattern out)

let should_pass_project files =
  with_temp_project files (fun dir ->
    let code, out = run_compiler ["--check"; Filename.concat dir "Main.tesl"] in
    if code <> 0 then failf "expected compilation success, got:
%s" out)

let should_fail_project pattern files =
  with_temp_project files (fun dir ->
    let code, out = run_compiler ["--check"; Filename.concat dir "Main.tesl"] in
    if code = 0 then failf "expected failure matching %S, but compilation succeeded" pattern;
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:
%s" pattern out)

let util_src = {|#lang tesl
module Util exposing [helper]
import Tesl.Prelude exposing [Int]
fn helper() -> Int = 1
|}

let a_src = {|#lang tesl
module A exposing [helper]
import Tesl.Prelude exposing [Int]
fn helper() -> Int = 1
|}

let b_src = {|#lang tesl
module B exposing [helper]
import Tesl.Prelude exposing [Int]
fn helper() -> Int = 2
|}

let r43_01_param_shadows_own_top_level_name () =
  should_fail_src "shadow" {|#lang tesl
module Main exposing [helper]
import Tesl.Prelude exposing [Int]

fn helper(helper: Int) -> Int =
  helper
|}

let r43_02_param_shadows_sibling_top_level_name () =
  should_fail_src "shadow" {|#lang tesl
module Main exposing [helper, value]
import Tesl.Prelude exposing [Int]

fn helper() -> Int = 1
fn value(helper: Int) -> Int =
  helper
|}

let r43_03_let_shadows_sibling_top_level_name () =
  should_fail_src "shadow" {|#lang tesl
module Main exposing [helper, value]
import Tesl.Prelude exposing [Int]

fn helper() -> Int = 1
fn value() -> Int =
  let helper = 2
  helper
|}

let r43_04_case_binder_shadows_sibling_top_level_name () =
  should_fail_src "shadow" {|#lang tesl
module Main exposing [helper, value]
import Tesl.Prelude exposing [Int]

fn helper() -> Int = 1
fn value() -> Int =
  case 1 of
    helper -> helper
|}

let r43_05_lambda_param_shadows_sibling_top_level_name () =
  should_fail_src "shadow" {|#lang tesl
module Main exposing [helper, value]
import Tesl.Prelude exposing [Int]

fn helper() -> Int = 1
fn value() -> Int =
  let apply = fn(helper: Int) -> helper
  apply 1
|}

let r43_06_test_let_shadows_sibling_top_level_name () =
  should_fail_src "shadow" {|#lang tesl
module Main exposing [helper]
import Tesl.Prelude exposing [Int]

fn helper() -> Int = 1

test "shadow in test let" {
  let helper = 2
  expect helper == 2
}
|}

let r43_07_property_param_shadows_sibling_top_level_name () =
  should_fail_src "shadow" {|#lang tesl
module Main exposing [helper]
import Tesl.Prelude exposing [Int, Bool]

fn helper() -> Int = 1

test "property shadow" with 1 runs {
  property "helper" (helper: Int) {
    helper == helper
  }
}
|}

let r43_08_test_case_binder_shadows_sibling_top_level_name () =
  should_fail_src "shadow" {|#lang tesl
module Main exposing [helper]
import Tesl.Prelude exposing [Int]

fn helper() -> Int = 1

test "shadow in test case" {
  case 1 of
    helper ->
      expect helper == 1
}
|}

let r43_09_param_shadows_gdp () =
  should_fail_src "shadow" {|#lang tesl
module Main exposing [value]
import Tesl.Prelude exposing [Int]

fn value(gdp: Int) -> Int =
  gdp
|}

let r43_10_let_shadows_gdp () =
  should_fail_src "shadow" {|#lang tesl
module Main exposing [value]
import Tesl.Prelude exposing [Int]

fn value() -> Int =
  let gdp = 1
  gdp
|}

let r43_11_lambda_param_shadows_gdp () =
  should_fail_src "shadow" {|#lang tesl
module Main exposing [value]
import Tesl.Prelude exposing [Int]

fn value() -> Int =
  let apply = fn(gdp: Int) -> gdp
  apply 1
|}

let r43_12_test_let_shadows_gdp () =
  should_fail_src "shadow" {|#lang tesl
module Main exposing [value]
import Tesl.Prelude exposing [Int]

fn value() -> Int = 1

test "shadow gdp in test" {
  let gdp = 1
  expect gdp == 1
}
|}

let r43_13_param_shadows_imported_function () =
  should_fail_project "shadow" [
    ("Util.tesl", util_src);
    ("Main.tesl", {|#lang tesl
module Main exposing [value]
import Tesl.Prelude exposing [Int]
import Util exposing [helper]

fn value(helper: Int) -> Int =
  helper
|});
  ]

let r43_14_let_shadows_imported_function () =
  should_fail_project "shadow" [
    ("Util.tesl", util_src);
    ("Main.tesl", {|#lang tesl
module Main exposing [value]
import Tesl.Prelude exposing [Int]
import Util exposing [helper]

fn value() -> Int =
  let helper = 2
  helper
|});
  ]

let r43_15_case_binder_shadows_imported_function () =
  should_fail_project "shadow" [
    ("Util.tesl", util_src);
    ("Main.tesl", {|#lang tesl
module Main exposing [value]
import Tesl.Prelude exposing [Int]
import Util exposing [helper]

fn value() -> Int =
  case 1 of
    helper -> helper
|});
  ]

let r43_16_lambda_param_shadows_imported_function () =
  should_fail_project "shadow" [
    ("Util.tesl", util_src);
    ("Main.tesl", {|#lang tesl
module Main exposing [value]
import Tesl.Prelude exposing [Int]
import Util exposing [helper]

fn value() -> Int =
  let apply = fn(helper: Int) -> helper
  apply 1
|});
  ]

let r43_17_test_let_shadows_imported_function () =
  should_fail_project "shadow" [
    ("Util.tesl", util_src);
    ("Main.tesl", {|#lang tesl
module Main exposing [value]
import Tesl.Prelude exposing [Int]
import Util exposing [helper]

fn value() -> Int = 1

test "shadow imported helper in test" {
  let helper = 2
  expect helper == 2
}
|});
  ]

let r43_18_property_param_shadows_imported_function () =
  should_fail_project "shadow" [
    ("Util.tesl", util_src);
    ("Main.tesl", {|#lang tesl
module Main exposing [value]
import Tesl.Prelude exposing [Int, Bool]
import Util exposing [helper]

fn value() -> Int = 1

test "property imported shadow" with 1 runs {
  property "helper" (helper: Int) {
    helper == helper
  }
}
|});
  ]

let r43_19_test_case_binder_shadows_imported_function () =
  should_fail_project "shadow" [
    ("Util.tesl", util_src);
    ("Main.tesl", {|#lang tesl
module Main exposing [value]
import Tesl.Prelude exposing [Int]
import Util exposing [helper]

fn value() -> Int = 1

test "shadow imported helper in test case" {
  case 1 of
    helper ->
      expect helper == 1
}
|});
  ]

let r43_20_top_level_function_shadows_imported_function () =
  should_fail_project "shadow.*imported" [
    ("Util.tesl", util_src);
    ("Main.tesl", {|#lang tesl
module Main exposing [helper, value]
import Tesl.Prelude exposing [Int]
import Util exposing [helper]

fn helper() -> Int = 2
fn value() -> Int = helper()
|});
  ]

let r43_21_duplicate_exposed_import_name_is_rejected () =
  should_fail_project "multiple modules" [
    ("A.tesl", a_src);
    ("B.tesl", b_src);
    ("Main.tesl", {|#lang tesl
module Main exposing [value]
import Tesl.Prelude exposing [Int]
import A exposing [helper]
import B exposing [helper]

fn value() -> Int = helper()
|});
  ]

let r43_22_import_all_is_qualified_only () =
  should_pass_project [
    ("Util.tesl", util_src);
    ("Main.tesl", {|#lang tesl
module Main exposing [helper, value]
import Tesl.Prelude exposing [Int]
import Util

fn helper() -> Int = 2
fn value() -> Int = helper()
|});
  ]

let r43_23_fresh_local_let_still_compiles_with_exposed_import () =
  should_pass_project [
    ("Util.tesl", util_src);
    ("Main.tesl", {|#lang tesl
module Main exposing [value]
import Tesl.Prelude exposing [Int]
import Util exposing [helper]

fn value() -> Int =
  let fresh = helper()
  fresh
|});
  ]

let r43_24_fresh_property_param_still_compiles_with_exposed_import () =
  should_pass_project [
    ("Util.tesl", util_src);
    ("Main.tesl", {|#lang tesl
module Main exposing [value]
import Tesl.Prelude exposing [Int, Bool]
import Util exposing [helper]

fn value() -> Int = helper()

test "property uses fresh names" with 1 runs {
  property "fresh" (n: Int) {
    n == n
  }
}
|});
  ]

let () =
  run "Review43-Antagonistic" [
    ("name hygiene", [
      test_case "R43_01 param shadows own top-level function" `Quick r43_01_param_shadows_own_top_level_name;
      test_case "R43_02 param shadows sibling top-level function" `Quick r43_02_param_shadows_sibling_top_level_name;
      test_case "R43_03 let shadows sibling top-level function" `Quick r43_03_let_shadows_sibling_top_level_name;
      test_case "R43_04 case binder shadows sibling top-level function" `Quick r43_04_case_binder_shadows_sibling_top_level_name;
      test_case "R43_05 lambda param shadows sibling top-level function" `Quick r43_05_lambda_param_shadows_sibling_top_level_name;
      test_case "R43_06 test let shadows sibling top-level function" `Quick r43_06_test_let_shadows_sibling_top_level_name;
      test_case "R43_07 property param shadows sibling top-level function" `Quick r43_07_property_param_shadows_sibling_top_level_name;
      test_case "R43_08 test case binder shadows sibling top-level function" `Quick r43_08_test_case_binder_shadows_sibling_top_level_name;
      test_case "R43_09 param shadows gdp" `Quick r43_09_param_shadows_gdp;
      test_case "R43_10 let shadows gdp" `Quick r43_10_let_shadows_gdp;
      test_case "R43_11 lambda param shadows gdp" `Quick r43_11_lambda_param_shadows_gdp;
      test_case "R43_12 test let shadows gdp" `Quick r43_12_test_let_shadows_gdp;
      test_case "R43_13 param shadows imported function" `Quick r43_13_param_shadows_imported_function;
      test_case "R43_14 let shadows imported function" `Quick r43_14_let_shadows_imported_function;
      test_case "R43_15 case binder shadows imported function" `Quick r43_15_case_binder_shadows_imported_function;
      test_case "R43_16 lambda param shadows imported function" `Quick r43_16_lambda_param_shadows_imported_function;
      test_case "R43_17 test let shadows imported function" `Quick r43_17_test_let_shadows_imported_function;
      test_case "R43_18 property param shadows imported function" `Quick r43_18_property_param_shadows_imported_function;
      test_case "R43_19 test case binder shadows imported function" `Quick r43_19_test_case_binder_shadows_imported_function;
      test_case "R43_20 top-level function shadows imported function" `Quick r43_20_top_level_function_shadows_imported_function;
      test_case "R43_21 duplicate exposed import name" `Quick r43_21_duplicate_exposed_import_name_is_rejected;
      test_case "R43_22 import all stays qualified-only" `Quick r43_22_import_all_is_qualified_only;
      test_case "R43_23 fresh let still compiles" `Quick r43_23_fresh_local_let_still_compiles_with_exposed_import;
      test_case "R43_24 fresh property param still compiles" `Quick r43_24_fresh_property_param_still_compiles_with_exposed_import;
    ])
  ]
