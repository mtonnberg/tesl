(** Antagonistic regression tests for Critical Review 45.
    Focus: recursive exhaustiveness for nested constructor, literal, and tuple patterns.

    R45_01  Maybe literal hole is rejected
    R45_02  Maybe literal wildcard fallback compiles
    R45_03  Multiple Maybe literal holes are rejected
    R45_04  Multiple Maybe literals plus binder fallback compile
    R45_05  Nested Maybe hole is rejected
    R45_06  Nested Maybe full coverage compiles
    R45_07  Maybe Bool partial nested coverage is rejected
    R45_08  Maybe Bool full nested coverage compiles
    R45_09  Tuple2 literal cross-product hole is rejected
    R45_10  Tuple2 literal catch-all row compiles
    R45_11  Tuple2 nested Maybe cross-product hole is rejected
    R45_12  Tuple2 nested Maybe full coverage compiles
    R45_13  Bool pair missing one combination is rejected
    R45_14  Bool pair full coverage compiles
    R45_15  Tuple3 partial literal coverage is rejected
    R45_16  Tuple3 binder coverage compiles
    R45_17  Local fielded constructor literal hole is rejected
    R45_18  Local fielded constructor full coverage compiles
    R45_19  Local recursive nested constructor hole is rejected
    R45_20  Local recursive nested constructor full coverage compiles
    R45_21  Imported fielded constructor nested hole is rejected
    R45_22  Imported fielded constructor full coverage compiles
    R45_23  Imported recursive nested constructor hole is rejected
    R45_24  Imported recursive nested constructor full coverage compiles
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
  let dir = Filename.temp_file "tesl-r45-proj" "" in
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

let should_pass_src src =
  with_temp_file "tesl-r45" ".tesl" src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected compilation success, got:\n%s" out)

let should_fail_src pattern src =
  with_temp_file "tesl-r45" ".tesl" src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but compilation succeeded" pattern;
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pattern out)

let should_pass_project files =
  with_temp_project files (fun dir ->
    let code, out = run_compiler ["--check"; Filename.concat dir "Main.tesl"] in
    if code <> 0 then failf "expected compilation success, got:\n%s" out)

let should_fail_project pattern files =
  with_temp_project files (fun dir ->
    let code, out = run_compiler ["--check"; Filename.concat dir "Main.tesl"] in
    if code = 0 then failf "expected failure matching %S, but compilation succeeded" pattern;
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pattern out)

let nested_non_exhaustive = "nested constructor"

let imported_box_src = {|#lang tesl
module A exposing [Box(..)]
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
type Box =
  | Empty
  | Wrap inner: Maybe Int
|}

let imported_expr_src = {|#lang tesl
module A exposing [Expr(..)]
import Tesl.Prelude exposing [Int]
type Expr =
  | Lit value: Int
  | Neg inner: Expr
  | Add left: Expr right: Expr
|}

let r45_01_maybe_literal_hole_rejected () =
  should_fail_src nested_non_exhaustive {|#lang tesl
module Main exposing [f]
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
fn f(m: Maybe Int) -> Int =
  case m of
    Nothing -> 0
    Something (0) -> 1
|}

let r45_02_maybe_literal_wildcard_fallback_compiles () =
  should_pass_src {|#lang tesl
module Main exposing [f]
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
fn f(m: Maybe Int) -> Int =
  case m of
    Nothing -> 0
    Something _ -> 1
|}

let r45_03_multiple_maybe_literal_holes_rejected () =
  should_fail_src nested_non_exhaustive {|#lang tesl
module Main exposing [f]
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
fn f(m: Maybe Int) -> Int =
  case m of
    Nothing -> 0
    Something (0) -> 1
    Something (1) -> 2
|}

let r45_04_multiple_maybe_literals_plus_binder_fallback_compile () =
  should_pass_src {|#lang tesl
module Main exposing [f]
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
fn f(m: Maybe Int) -> Int =
  case m of
    Nothing -> 0
    Something (0) -> 1
    Something n -> n
|}

let r45_05_nested_maybe_hole_rejected () =
  should_fail_src nested_non_exhaustive {|#lang tesl
module Main exposing [f]
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
fn f(m: Maybe (Maybe Int)) -> Int =
  case m of
    Nothing -> 0
    Something (Nothing) -> 1
|}

let r45_06_nested_maybe_full_coverage_compiles () =
  should_pass_src {|#lang tesl
module Main exposing [f]
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
fn f(m: Maybe (Maybe Int)) -> Int =
  case m of
    Nothing -> 0
    Something (Nothing) -> 1
    Something (Something n) -> n
|}

let r45_07_maybe_bool_partial_nested_coverage_rejected () =
  should_fail_src nested_non_exhaustive {|#lang tesl
module Main exposing [f]
import Tesl.Prelude exposing [Bool(..), Int]
import Tesl.Maybe exposing [Maybe(..)]
fn f(m: Maybe Bool) -> Int =
  case m of
    Nothing -> 0
    Something (True) -> 1
|}

let r45_08_maybe_bool_full_nested_coverage_compiles () =
  should_pass_src {|#lang tesl
module Main exposing [f]
import Tesl.Prelude exposing [Bool(..), Int]
import Tesl.Maybe exposing [Maybe(..)]
fn f(m: Maybe Bool) -> Int =
  case m of
    Nothing -> 0
    Something (True) -> 1
    Something (False) -> 2
|}

let r45_09_tuple2_literal_cross_product_hole_rejected () =
  should_fail_src nested_non_exhaustive {|#lang tesl
module Main exposing [f]
import Tesl.Prelude exposing [Int]
import Tesl.Tuple exposing [Tuple2(..)]
fn f(t: Tuple2 Int Int) -> Int =
  case t of
    Tuple2 (0) y -> y
    Tuple2 x (0) -> x
|}

let r45_10_tuple2_literal_catch_all_row_compiles () =
  should_pass_src {|#lang tesl
module Main exposing [f]
import Tesl.Prelude exposing [Int]
import Tesl.Tuple exposing [Tuple2(..)]
fn f(t: Tuple2 Int Int) -> Int =
  case t of
    Tuple2 (0) y -> y
    Tuple2 x y -> x + y
|}

let r45_11_tuple2_nested_maybe_cross_product_hole_rejected () =
  should_fail_src nested_non_exhaustive {|#lang tesl
module Main exposing [f]
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Tuple exposing [Tuple2(..)]
fn f(t: Tuple2 (Maybe Int) (Maybe Int)) -> Int =
  case t of
    Tuple2 Nothing _ -> 0
    Tuple2 _ Nothing -> 1
|}

let r45_12_tuple2_nested_maybe_full_coverage_compiles () =
  should_pass_src {|#lang tesl
module Main exposing [f]
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Tuple exposing [Tuple2(..)]
fn f(t: Tuple2 (Maybe Int) (Maybe Int)) -> Int =
  case t of
    Tuple2 Nothing _ -> 0
    Tuple2 _ Nothing -> 1
    Tuple2 (Something x) (Something y) -> x + y
|}

let r45_13_bool_pair_missing_one_combination_rejected () =
  should_fail_src nested_non_exhaustive {|#lang tesl
module Main exposing [f]
import Tesl.Prelude exposing [Bool(..), Int]
import Tesl.Tuple exposing [Tuple2(..)]
fn f(t: Tuple2 Bool Bool) -> Int =
  case t of
    Tuple2 True True -> 1
    Tuple2 True False -> 2
    Tuple2 False True -> 3
|}

let r45_14_bool_pair_full_coverage_compiles () =
  should_pass_src {|#lang tesl
module Main exposing [f]
import Tesl.Prelude exposing [Bool(..), Int]
import Tesl.Tuple exposing [Tuple2(..)]
fn f(t: Tuple2 Bool Bool) -> Int =
  case t of
    Tuple2 True True -> 1
    Tuple2 True False -> 2
    Tuple2 False True -> 3
    Tuple2 False False -> 4
|}

let r45_15_tuple3_partial_literal_coverage_rejected () =
  should_fail_src nested_non_exhaustive {|#lang tesl
module Main exposing [f]
import Tesl.Prelude exposing [Int]
import Tesl.Tuple exposing [Tuple3(..)]
fn f(t: Tuple3 Int Int Int) -> Int =
  case t of
    Tuple3 (0) y z -> y + z
    Tuple3 x (0) z -> x + z
    Tuple3 x y (0) -> x + y
|}

let r45_16_tuple3_binder_coverage_compiles () =
  should_pass_src {|#lang tesl
module Main exposing [f]
import Tesl.Prelude exposing [Int]
import Tesl.Tuple exposing [Tuple3(..)]
fn f(t: Tuple3 Int Int Int) -> Int =
  case t of
    Tuple3 x y z -> x + y + z
|}

let r45_17_local_fielded_constructor_literal_hole_rejected () =
  should_fail_src nested_non_exhaustive {|#lang tesl
module Main exposing [Expr(..), f]
import Tesl.Prelude exposing [Int]
type Expr =
  | Lit value: Int
  | Neg inner: Expr
fn f(e: Expr) -> Int =
  case e of
    Lit (0) -> 0
    Neg inner -> 1
|}

let r45_18_local_fielded_constructor_full_coverage_compiles () =
  should_pass_src {|#lang tesl
module Main exposing [Expr(..), f]
import Tesl.Prelude exposing [Int]
type Expr =
  | Lit value: Int
  | Neg inner: Expr
fn f(e: Expr) -> Int =
  case e of
    Lit n -> n
    Neg inner -> 1
|}

let r45_19_local_recursive_nested_constructor_hole_rejected () =
  should_fail_src nested_non_exhaustive {|#lang tesl
module Main exposing [Expr(..), f]
import Tesl.Prelude exposing [Int]
type Expr =
  | Lit value: Int
  | Neg inner: Expr
  | Add left: Expr right: Expr
fn f(e: Expr) -> Int =
  case e of
    Lit n -> n
    Neg (Lit n) -> 0 - n
    Add left right -> f left + f right
|}

let r45_20_local_recursive_nested_constructor_full_coverage_compiles () =
  should_pass_src {|#lang tesl
module Main exposing [Expr(..), f]
import Tesl.Prelude exposing [Int]
type Expr =
  | Lit value: Int
  | Neg inner: Expr
  | Add left: Expr right: Expr
fn f(e: Expr) -> Int =
  case e of
    Lit n -> n
    Neg inner -> 0 - f inner
    Add left right -> f left + f right
|}

let r45_21_imported_fielded_constructor_nested_hole_rejected () =
  should_fail_project nested_non_exhaustive [
    ("A.tesl", imported_box_src);
    ("Main.tesl", {|#lang tesl
module Main exposing [f]
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
import A exposing [Box(..)]
fn f(b: Box) -> Int =
  case b of
    Empty -> 0
    Wrap (Nothing) -> 1
|});
  ]

let r45_22_imported_fielded_constructor_full_coverage_compiles () =
  should_pass_project [
    ("A.tesl", imported_box_src);
    ("Main.tesl", {|#lang tesl
module Main exposing [f]
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
import A exposing [Box(..)]
fn f(b: Box) -> Int =
  case b of
    Empty -> 0
    Wrap (Nothing) -> 1
    Wrap (Something n) -> n
|});
  ]

let r45_23_imported_recursive_nested_constructor_hole_rejected () =
  should_fail_project nested_non_exhaustive [
    ("A.tesl", imported_expr_src);
    ("Main.tesl", {|#lang tesl
module Main exposing [f]
import Tesl.Prelude exposing [Int]
import A exposing [Expr(..)]
fn f(e: Expr) -> Int =
  case e of
    Lit n -> n
    Neg (Lit n) -> 0 - n
    Add left right -> f left + f right
|});
  ]

let r45_24_imported_recursive_nested_constructor_full_coverage_compiles () =
  should_pass_project [
    ("A.tesl", imported_expr_src);
    ("Main.tesl", {|#lang tesl
module Main exposing [f]
import Tesl.Prelude exposing [Int]
import A exposing [Expr(..)]
fn f(e: Expr) -> Int =
  case e of
    Lit n -> n
    Neg inner -> 0 - f inner
    Add left right -> f left + f right
|});
  ]

let () =
  run "Review45-Antagonistic" [
    ("recursive exhaustiveness for nested patterns", [
      test_case "R45_01 Maybe literal hole rejected" `Quick r45_01_maybe_literal_hole_rejected;
      test_case "R45_02 Maybe literal wildcard fallback compiles" `Quick r45_02_maybe_literal_wildcard_fallback_compiles;
      test_case "R45_03 multiple Maybe literal holes rejected" `Quick r45_03_multiple_maybe_literal_holes_rejected;
      test_case "R45_04 multiple Maybe literals plus binder fallback compile" `Quick r45_04_multiple_maybe_literals_plus_binder_fallback_compile;
      test_case "R45_05 nested Maybe hole rejected" `Quick r45_05_nested_maybe_hole_rejected;
      test_case "R45_06 nested Maybe full coverage compiles" `Quick r45_06_nested_maybe_full_coverage_compiles;
      test_case "R45_07 Maybe Bool partial nested coverage rejected" `Quick r45_07_maybe_bool_partial_nested_coverage_rejected;
      test_case "R45_08 Maybe Bool full nested coverage compiles" `Quick r45_08_maybe_bool_full_nested_coverage_compiles;
      test_case "R45_09 Tuple2 literal cross-product hole rejected" `Quick r45_09_tuple2_literal_cross_product_hole_rejected;
      test_case "R45_10 Tuple2 literal catch-all row compiles" `Quick r45_10_tuple2_literal_catch_all_row_compiles;
      test_case "R45_11 Tuple2 nested Maybe cross-product hole rejected" `Quick r45_11_tuple2_nested_maybe_cross_product_hole_rejected;
      test_case "R45_12 Tuple2 nested Maybe full coverage compiles" `Quick r45_12_tuple2_nested_maybe_full_coverage_compiles;
      test_case "R45_13 Bool pair missing one combination rejected" `Quick r45_13_bool_pair_missing_one_combination_rejected;
      test_case "R45_14 Bool pair full coverage compiles" `Quick r45_14_bool_pair_full_coverage_compiles;
      test_case "R45_15 Tuple3 partial literal coverage rejected" `Quick r45_15_tuple3_partial_literal_coverage_rejected;
      test_case "R45_16 Tuple3 binder coverage compiles" `Quick r45_16_tuple3_binder_coverage_compiles;
      test_case "R45_17 local fielded constructor literal hole rejected" `Quick r45_17_local_fielded_constructor_literal_hole_rejected;
      test_case "R45_18 local fielded constructor full coverage compiles" `Quick r45_18_local_fielded_constructor_full_coverage_compiles;
      test_case "R45_19 local recursive nested constructor hole rejected" `Quick r45_19_local_recursive_nested_constructor_hole_rejected;
      test_case "R45_20 local recursive nested constructor full coverage compiles" `Quick r45_20_local_recursive_nested_constructor_full_coverage_compiles;
      test_case "R45_21 imported fielded constructor nested hole rejected" `Quick r45_21_imported_fielded_constructor_nested_hole_rejected;
      test_case "R45_22 imported fielded constructor full coverage compiles" `Quick r45_22_imported_fielded_constructor_full_coverage_compiles;
      test_case "R45_23 imported recursive nested constructor hole rejected" `Quick r45_23_imported_recursive_nested_constructor_hole_rejected;
      test_case "R45_24 imported recursive nested constructor full coverage compiles" `Quick r45_24_imported_recursive_nested_constructor_full_coverage_compiles;
    ])
  ]
